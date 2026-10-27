import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// What a toast reports; picks its color, icon and default lifetime.
enum ToastTone {
  /// Neutral notice. Muted icon on the card surface.
  info,

  /// Something worked (copied, merged, restored). Ember check.
  success,

  /// Something failed. Red icon, red-tinted card, longer lifetime.
  error,
}

/// Shows [message] as a toast near the top of the window, above the
/// conversation and clear of the composer. It drops in with a small pop and
/// lifts out after [duration] or via its close button. Hovering holds the
/// timer.
///
/// Repeating a message that is already showing restarts that toast instead
/// of stacking a copy; at most [_kMaxToasts] show at once, newest on top.
void showToast(
  BuildContext context,
  String message, {
  ToastTone tone = ToastTone.info,
  Duration? duration,
}) {
  final OverlayState? overlay = Overlay.maybeOf(context, rootOverlay: true);
  if (overlay == null) return;
  showToastOn(overlay, message, tone: tone, duration: duration);
}

/// [showToast] for callers holding an [OverlayState] rather than a context
/// (the app root, or a context that may unmount across an await).
void showToastOn(
  OverlayState overlay,
  String message, {
  ToastTone tone = ToastTone.info,
  Duration? duration,
}) {
  _ToastController.of(overlay)
      .show(message, tone, duration ?? _defaultDuration(tone));
}

Duration _defaultDuration(ToastTone tone) => switch (tone) {
  ToastTone.info => const Duration(seconds: 4),
  ToastTone.success => const Duration(seconds: 3),
  ToastTone.error => const Duration(seconds: 8),
};

const int _kMaxToasts = 3;

/// Room left for the app or settings top bar, so toasts sit just below it.
const double _kTopInset = 60;

class _ToastEntry {
  _ToastEntry(this.id, this.message, this.tone, this.duration);

  final int id;
  final String message;
  final ToastTone tone;
  final Duration duration;

  /// Bumped when the same message is shown again, restarting its timer.
  int generation = 0;

  /// Set once the toast starts leaving; it stays listed until the exit ends.
  bool leaving = false;
}

/// One per overlay: owns the list of toasts and the single overlay entry
/// that lays them out. The entry exists only while a toast is listed.
class _ToastController extends ChangeNotifier {
  _ToastController(this._overlay);

  static final Expando<_ToastController> _controllers =
      Expando<_ToastController>('toasts');

  static _ToastController of(OverlayState overlay) =>
      _controllers[overlay] ??= _ToastController(overlay);

  final OverlayState _overlay;
  final List<_ToastEntry> _entries = <_ToastEntry>[];
  OverlayEntry? _overlayEntry;
  int _nextId = 0;

  List<_ToastEntry> get entries => _entries;

  void show(String message, ToastTone tone, Duration duration) {
    for (final _ToastEntry entry in _entries) {
      if (!entry.leaving && entry.message == message && entry.tone == tone) {
        entry.generation++;
        notifyListeners();
        return;
      }
    }
    _entries.insert(0, _ToastEntry(_nextId++, message, tone, duration));
    int live = 0;
    for (final _ToastEntry entry in _entries) {
      if (entry.leaving) continue;
      if (++live > _kMaxToasts) entry.leaving = true;
    }
    if (_overlayEntry == null) {
      _overlayEntry = OverlayEntry(
        builder: (BuildContext context) => _ToastStack(controller: this),
      );
      _overlay.insert(_overlayEntry!);
    }
    notifyListeners();
  }

  void dismiss(_ToastEntry entry) {
    if (entry.leaving) return;
    entry.leaving = true;
    notifyListeners();
  }

  /// Called by a toast once its exit animation has finished.
  void remove(_ToastEntry entry) {
    _entries.remove(entry);
    if (_entries.isEmpty) {
      _overlayEntry?.remove();
      _overlayEntry = null;
    }
    notifyListeners();
  }
}

class _ToastStack extends StatelessWidget {
  const _ToastStack({required this.controller});

  final _ToastController controller;

  @override
  Widget build(BuildContext context) {
    final EdgeInsets padding = MediaQuery.paddingOf(context);
    // Only the toasts themselves take pointer events: the Stack has no
    // background, so taps around them reach the app underneath.
    return Stack(
      children: <Widget>[
        Positioned(
          top: padding.top + _kTopInset,
          left: padding.left + 12,
          right: padding.right + 12,
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: ListenableBuilder(
                listenable: controller,
                builder: (BuildContext context, Widget? _) => Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    for (final _ToastEntry entry in controller.entries)
                      _Toast(
                        key: ValueKey<int>(entry.id),
                        entry: entry,
                        controller: controller,
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// A single toast card; its [Material] carries `Key('toast')` for tests.
class _Toast extends StatefulWidget {
  const _Toast({super.key, required this.entry, required this.controller});

  final _ToastEntry entry;
  final _ToastController controller;

  @override
  State<_Toast> createState() => _ToastState();
}

class _ToastState extends State<_Toast> with SingleTickerProviderStateMixin {
  /// 0 → 1 drops the toast in; reversing takes it out.
  late final AnimationController _presence = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 320),
    reverseDuration: const Duration(milliseconds: 180),
  );

  late final CurvedAnimation _enter = CurvedAnimation(
    parent: _presence,
    curve: Curves.easeOutBack,
    reverseCurve: Curves.easeIn,
  );
  late final CurvedAnimation _size = CurvedAnimation(
    parent: _presence,
    curve: const Interval(0, 0.6, curve: Curves.easeOutCubic),
    reverseCurve: Curves.easeInCubic,
  );
  late final Animation<Offset> _slide = Tween<Offset>(
    begin: const Offset(0, -0.35),
    end: Offset.zero,
  ).animate(_enter);
  late final Animation<double> _scale = Tween<double>(
    begin: 0.94,
    end: 1,
  ).animate(_enter);

  /// Lifetime runs on a plain timer, not a ticker, so nothing animates while
  /// the toast just sits there. [_shown] measures the time already spent
  /// showing, so a hover resumes with what was left.
  Timer? _timer;
  final Stopwatch _shown = Stopwatch();
  bool _started = false;
  bool _reducedMotion = false;
  bool _exiting = false;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _generation = widget.entry.generation;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reducedMotion = MediaQuery.disableAnimationsOf(context);
    if (_started) return;
    _started = true;
    if (_reducedMotion) {
      _presence.value = 1;
    } else {
      _presence.forward();
    }
    _resumeClock();
  }

  @override
  void didUpdateWidget(_Toast oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.entry.leaving && !_exiting) _exit();
    if (widget.entry.generation != _generation && !_exiting) {
      _generation = widget.entry.generation;
      final bool running = _timer != null;
      _shown.reset();
      if (running) _resumeClock();
    }
  }

  void _resumeClock() {
    _timer?.cancel();
    final Duration remaining = widget.entry.duration - _shown.elapsed;
    _shown.start();
    _timer = Timer(remaining.isNegative ? Duration.zero : remaining, _dismiss);
  }

  void _pauseClock() {
    _timer?.cancel();
    _timer = null;
    _shown.stop();
  }

  void _setHovered(bool hovered) {
    if (_exiting) return;
    hovered ? _pauseClock() : _resumeClock();
  }

  void _dismiss() => widget.controller.dismiss(widget.entry);

  Future<void> _exit() async {
    _exiting = true;
    _pauseClock();
    if (_reducedMotion) {
      // Called from didUpdateWidget: let this frame finish building before
      // the list (and possibly the overlay entry) changes.
      _presence.value = 0;
      await SchedulerBinding.instance.endOfFrame;
    } else {
      await _presence.reverse().orCancel.catchError((Object _) {});
    }
    if (!mounted) return;
    widget.controller.remove(widget.entry);
  }

  @override
  void dispose() {
    _timer?.cancel();
    _enter.dispose();
    _size.dispose();
    _presence.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final bool dark = theme.brightness == Brightness.dark;
    final bool error = widget.entry.tone == ToastTone.error;
    final (Color accent, IconData icon) = switch (widget.entry.tone) {
      ToastTone.info => (scheme.onSurfaceVariant, Icons.info_outline),
      ToastTone.success => (scheme.primary, Icons.check),
      ToastTone.error => (scheme.error, Icons.error_outline),
    };
    // Only failures tint the card, so red always means something went wrong.
    final Color background = error
        ? Color.alphaBlend(
            accent.withValues(alpha: dark ? 0.16 : 0.10),
            scheme.surfaceContainerHigh,
          )
        : scheme.surfaceContainerHigh;
    final Color border = error
        ? accent.withValues(alpha: dark ? 0.55 : 0.45)
        : scheme.outlineVariant;

    final Widget card = Material(
      key: const Key('toast'),
      color: background,
      elevation: 3,
      shadowColor: scheme.shadow.withValues(alpha: dark ? 0.6 : 0.18),
      shape: RoundedRectangleBorder(
        borderRadius: const BorderRadius.all(Radius.circular(10)),
        side: BorderSide(color: border),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
        child: Row(
          children: <Widget>[
            Icon(icon, size: 18, color: accent),
            const SizedBox(width: 10),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: SelectableText(
                  widget.entry.message,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurface,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 4),
            IconButton(
              key: const Key('toast-close'),
              tooltip: 'Dismiss',
              iconSize: 16,
              visualDensity: VisualDensity.compact,
              color: scheme.onSurfaceVariant,
              onPressed: _dismiss,
              icon: const Icon(Icons.close),
            ),
          ],
        ),
      ),
    );

    return SizeTransition(
      sizeFactor: _size,
      alignment: Alignment.bottomCenter,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: FadeTransition(
          opacity: _size,
          child: SlideTransition(
            position: _slide,
            child: ScaleTransition(
              scale: _scale,
              child: MouseRegion(
                onEnter: (_) => _setHovered(true),
                onExit: (_) => _setHovered(false),
                child: Semantics(liveRegion: true, child: card),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
