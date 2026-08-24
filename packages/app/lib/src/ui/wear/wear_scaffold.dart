import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';

/// A constraint-driven page frame for watch-sized square and round windows.
///
/// Round devices need more room at the upper corners than rectangular phone
/// layouts. The inset is derived from the allocated width rather than a
/// hardware-type check, so previews and resizable windows behave identically.
class WearScaffold extends StatefulWidget {
  const WearScaffold({
    super.key,
    required this.title,
    required this.child,
    this.showBack = false,
    this.action,
  });

  final String title;
  final Widget child;
  final bool showBack;
  final Widget? action;

  @override
  State<WearScaffold> createState() => _WearScaffoldState();
}

class _WearScaffoldState extends State<WearScaffold> {
  static const MethodChannel _rotaryChannel = MethodChannel(
    'sh.speeddial/rotary',
  );
  static final Set<_WearScaffoldState> _rotaryTargets = <_WearScaffoldState>{};

  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _rotaryTargets.add(this);
    if (_rotaryTargets.length == 1) {
      _rotaryChannel.setMethodCallHandler(_handleRotaryMethodCall);
    }
  }

  @override
  void dispose() {
    _rotaryTargets.remove(this);
    if (_rotaryTargets.isEmpty) {
      _rotaryChannel.setMethodCallHandler(null);
    }
    _scrollController.dispose();
    super.dispose();
  }

  static Future<void> _handleRotaryMethodCall(MethodCall call) async {
    if (call.method != 'scroll') throw MissingPluginException();
    final Object? argument = call.arguments;
    if (argument is! num) return;
    _dispatchRotaryScroll(argument.toDouble());
  }

  static void _dispatchRotaryScroll(double delta) {
    if (!delta.isFinite || delta == 0) return;
    for (final _WearScaffoldState target in _rotaryTargets.toList().reversed) {
      if (target._scrollBy(delta)) return;
    }
  }

  bool _scrollBy(double delta) {
    if (!mounted) return false;
    final ModalRoute<dynamic>? route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) return false;
    if (_scrollController.hasClients &&
        _scrollController.positions.length == 1) {
      _scrollController.position.pointerScroll(delta);
    }
    // The current page owns rotary input even while its scroll view is being
    // replaced by a progress or empty state.
    return true;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final bool compact = constraints.maxWidth <= 260;
          // The header occupies the narrow top arc of a round display. At a
          // 12% inset its icon centers are inside the circle but the glyphs
          // themselves are clipped; 20% plus a slightly lower row keeps the
          // complete touch affordances visible down to 192 logical pixels.
          final double headerInset = compact ? constraints.maxWidth * 0.20 : 12;
          final double contentInset = compact
              ? constraints.maxWidth * 0.075
              : 12;
          return SafeArea(
            minimum: EdgeInsets.only(
              top: compact ? 8 : 0,
              bottom: compact ? 5 : 0,
            ),
            child: Column(
              children: <Widget>[
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: headerInset),
                  child: SizedBox(
                    key: const Key('wear-header'),
                    height: compact ? 46 : 48,
                    child: Row(
                      children: <Widget>[
                        SizedBox(
                          width: compact ? 32 : 40,
                          child: widget.showBack
                              ? IconButton(
                                  key: const Key('wear-back'),
                                  tooltip: 'Back',
                                  padding: EdgeInsets.zero,
                                  icon: const Icon(
                                    Icons.chevron_left,
                                    size: 20,
                                  ),
                                  onPressed: () => Navigator.of(context).pop(),
                                )
                              : null,
                        ),
                        Expanded(
                          child: Text(
                            widget.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.titleSmall
                                ?.copyWith(fontWeight: FontWeight.w600),
                          ),
                        ),
                        SizedBox(
                          width: compact ? 32 : 40,
                          child: widget.action,
                        ),
                      ],
                    ),
                  ),
                ),
                Expanded(
                  child: PrimaryScrollController(
                    controller: _scrollController,
                    child: Padding(
                      padding: EdgeInsets.symmetric(horizontal: contentInset),
                      child: widget.child,
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// Standard lazy-list padding that keeps the first and last rows away from
/// the narrowest top and bottom portions of a round screen.
const EdgeInsets wearListPadding = EdgeInsets.fromLTRB(4, 10, 4, 28);

class WearEmptyState extends StatelessWidget {
  const WearEmptyState({
    super.key,
    required this.message,
    this.details,
    this.icon = Icons.hourglass_empty,
    this.action,
  });

  final String message;
  final String? details;
  final IconData icon;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, color: colors.onSurfaceVariant),
            const SizedBox(height: 6),
            Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: colors.onSurfaceVariant),
            ),
            if (details != null) ...<Widget>[
              const SizedBox(height: 4),
              Text(
                details!,
                key: const Key('wear-error-details'),
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.labelSmall
                    ?.copyWith(color: colors.error),
              ),
            ],
            if (action != null) ...<Widget>[const SizedBox(height: 8), action!],
          ],
        ),
      ),
    );
  }
}

String wearErrorText(Object error) {
  if (error is DaemonError) return error.message;
  if (error is PlatformException) {
    final String? message = error.message?.trim();
    return message == null || message.isEmpty ? error.code : message;
  }
  return error.toString();
}
