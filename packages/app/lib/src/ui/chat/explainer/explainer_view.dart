import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';

import '../../../theme.dart';
import 'explainer_scene.dart';

const Duration _kTransition = Duration(milliseconds: 420);

/// Largest upscale of an inline diagram; past this, it stays its natural size.
const double _kMaxInlineScale = 1.4;

/// An agent-authored interactive explainer: an SVG scene the user pages
/// through with animated transitions, plus toggles and `<title>` tooltips.
class ExplainerView extends StatefulWidget {
  const ExplainerView({
    super.key,
    required this.spec,
    this.initialStep = 0,
    this.initialToggles,
    this.fullscreen = false,
  });

  final ExplainerSpec spec;
  final int initialStep;
  final List<bool>? initialToggles;

  /// Fills the available space (the full-screen dialog) instead of fitting
  /// the chat column's width.
  final bool fullscreen;

  @override
  State<ExplainerView> createState() => _ExplainerViewState();
}

class _ExplainerViewState extends State<ExplainerView>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: _kTransition,
  )..addStatusListener(_onStatus);
  late final CurvedAnimation _curve = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeInOutCubic,
  );
  final FocusNode _focus = FocusNode(debugLabel: 'explainer');

  ExplainerDocument? _document;
  String? _error;
  ExplainerScene? _scene;
  late ExplainerState _state;
  ExplainerState? _from;

  String? _tooltip;
  Offset? _tooltipAt;

  @override
  void initState() {
    super.initState();
    _parse();
  }

  @override
  void didUpdateWidget(ExplainerView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.spec, widget.spec)) {
      _parse();
      _refreshScene(force: true);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _refreshScene();
  }

  void _parse() {
    try {
      final ExplainerDocument document = ExplainerDocument.parse(widget.spec);
      _document = document;
      _error = null;
      final List<bool> toggles = <bool>[
        for (int i = 0; i < document.toggles.length; i++)
          widget.initialToggles != null && i < widget.initialToggles!.length
              ? widget.initialToggles![i]
              : document.toggles[i].on,
      ];
      _state = ExplainerState(
        document,
        widget.initialStep.clamp(0, document.steps.length - 1),
        toggles,
      );
      _from = null;
    } on ExplainerException catch (error) {
      _document = null;
      _error = error.errors.isEmpty ? 'invalid explainer' : error.errors.first;
    } on FormatException catch (error) {
      _document = null;
      _error = error.message;
    }
  }

  void _refreshScene({bool force = false}) {
    final ExplainerDocument? document = _document;
    if (document == null) {
      _scene?.dispose();
      _scene = null;
      return;
    }
    final ExplainerPalette palette = ExplainerPalette.of(context);
    final ExplainerScene? current = _scene;
    if (!force &&
        current != null &&
        identical(current.document, document) &&
        current.palette.sameAs(palette)) {
      return;
    }
    current?.dispose();
    _scene = ExplainerScene(document, palette);
  }

  @override
  void dispose() {
    _controller.dispose();
    _curve.dispose();
    _focus.dispose();
    _scene?.dispose();
    super.dispose();
  }

  void _onStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed && _from != null) {
      setState(() => _from = null);
    }
  }

  void _show(ExplainerState next) {
    if (next == _state) return;
    final bool animate =
        !(MediaQuery.maybeDisableAnimationsOf(context) ?? false);
    setState(() {
      _from = animate ? _state : null;
      _state = next;
      _tooltip = null;
    });
    if (animate) _controller.forward(from: 0);
  }

  void _goTo(int step) {
    final ExplainerDocument document = _document!;
    final int clamped = step.clamp(0, document.steps.length - 1);
    _show(ExplainerState(document, clamped, _state.toggles));
  }

  void _setToggle(int index, bool on) {
    final List<bool> toggles = List<bool>.of(_state.toggles);
    toggles[index] = on;
    _show(ExplainerState(_document!, _state.step, toggles));
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final LogicalKeyboardKey key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.space) {
      _goTo(_state.step + 1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft) {
      _goTo(_state.step - 1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.home) {
      _goTo(0);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.end) {
      _goTo(_document!.steps.length - 1);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _updateTooltip(Offset local, double scale, {bool toggle = false}) {
    final ExplainerScene scene = _scene!;
    final SvgViewBox box = scene.viewBox;
    final Offset point = Offset(
      local.dx / scale + box.x,
      local.dy / scale + box.y,
    );
    final String? title = scene.hitTest(_state, point);
    if (toggle && title != null && title == _tooltip) {
      setState(() => _tooltip = null);
      return;
    }
    if (title == _tooltip && (title == null || _tooltipAt == local)) return;
    setState(() {
      _tooltip = title;
      _tooltipAt = local;
    });
  }

  Future<void> _openFullscreen() async {
    final ExplainerState? result = await showDialog<ExplainerState>(
      context: context,
      builder: (BuildContext dialogContext) => Dialog.fullscreen(
        child: _FullscreenExplainer(
          spec: widget.spec,
          step: _state.step,
          toggles: _state.toggles,
        ),
      ),
    );
    if (!mounted || result == null || _document == null) return;
    _show(ExplainerState(_document!, result.step, result.toggles));
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final SpeedDialColors colors = theme.speedDialColors;
    final ExplainerScene? scene = _scene;
    final ExplainerDocument? document = _document;
    final Widget body;
    if (scene == null || document == null) {
      body = _ExplainerError(
        title: widget.spec.title,
        message: _error ?? 'invalid explainer',
      );
    } else {
      body = _content(context, scene, document);
    }
    if (widget.fullscreen) return body;
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        border: Border.all(color: colors.border),
        borderRadius: BorderRadius.circular(10),
      ),
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      child: body,
    );
  }

  Widget _content(
    BuildContext context,
    ExplainerScene scene,
    ExplainerDocument document,
  ) {
    final ThemeData theme = Theme.of(context);
    final String? title = widget.spec.title;
    final ExplainerStep step = document.steps[_state.step];
    final Widget diagram = _diagram(scene);
    final Widget captionSizer = IndexedStack(
      index: null,
      children: <Widget>[
        for (final ExplainerStep step in document.steps)
          Text(step.caption, style: theme.textTheme.bodyMedium),
      ],
    );
    final List<Widget> children = <Widget>[
      if (!widget.fullscreen)
        Row(
          children: <Widget>[
            Icon(
              Icons.slideshow_outlined,
              size: 16,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                title ?? 'Explainer',
                style: theme.textTheme.titleSmall,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            IconButton(
              tooltip: 'Expand',
              visualDensity: VisualDensity.compact,
              iconSize: 18,
              onPressed: _openFullscreen,
              icon: const Icon(Icons.open_in_full),
            ),
          ],
        ),
      const SizedBox(height: 4),
      if (widget.fullscreen) Expanded(child: diagram) else diagram,
      if (document.steps.any(
        (ExplainerStep step) => step.caption.isNotEmpty,
      )) ...<Widget>[
        const SizedBox(height: 8),
        AnimatedSwitcher(
          duration: MediaQuery.disableAnimationsOf(context)
              ? Duration.zero
              : const Duration(milliseconds: 200),
          layoutBuilder: (Widget? current, List<Widget> previous) => Stack(
            alignment: Alignment.topLeft,
            children: <Widget>[
              // Lay out every caption, but paint and expose only the active
              // one below. This reserves the tallest step from the first frame
              // and adapts naturally to wrapping and accessibility text scaling.
              captionSizer,
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: Stack(
                  alignment: Alignment.topLeft,
                  children: <Widget>[...previous, ?current],
                ),
              ),
            ],
          ),
          child: Text(
            step.caption,
            key: ValueKey<int>(_state.step),
            style: theme.textTheme.bodyMedium,
          ),
        ),
      ],
      if (document.steps.length > 1 || document.toggles.isNotEmpty)
        const SizedBox(height: 4),
      if (document.steps.length > 1) _stepper(theme, document),
      if (document.toggles.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 4, bottom: 4),
          child: Wrap(
            spacing: 6,
            runSpacing: 6,
            children: <Widget>[
              for (int i = 0; i < document.toggles.length; i++)
                FilterChip(
                  key: ValueKey<String>('explainer-toggle-$i'),
                  label: Text(document.toggles[i].label),
                  selected: _state.toggles[i],
                  visualDensity: VisualDensity.compact,
                  onSelected: (bool on) => _setToggle(i, on),
                ),
            ],
          ),
        ),
    ];
    return Focus(
      focusNode: _focus,
      onKeyEvent: _onKey,
      child: Column(
        mainAxisSize: widget.fullscreen ? MainAxisSize.max : MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );
  }

  Widget _stepper(ThemeData theme, ExplainerDocument document) {
    final int count = document.steps.length;
    final int step = _state.step;
    final Widget position = count <= 12
        ? Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              for (int i = 0; i < count; i++)
                _StepDot(
                  key: ValueKey<String>('explainer-dot-$i'),
                  active: i == step,
                  passed: i < step,
                  onTap: () => _goTo(i),
                  label: 'Step ${i + 1}',
                ),
            ],
          )
        : Expanded(
            child: Slider(
              value: step.toDouble(),
              max: (count - 1).toDouble(),
              divisions: count - 1,
              label: '${step + 1}',
              onChanged: (double value) => _goTo(value.round()),
            ),
          );
    return Row(
      children: <Widget>[
        IconButton(
          key: const ValueKey<String>('explainer-prev'),
          tooltip: 'Previous step',
          visualDensity: VisualDensity.compact,
          onPressed: step > 0 ? () => _goTo(step - 1) : null,
          icon: const Icon(Icons.chevron_left),
        ),
        position,
        IconButton(
          key: const ValueKey<String>('explainer-next'),
          tooltip: 'Next step',
          visualDensity: VisualDensity.compact,
          onPressed: step < count - 1 ? () => _goTo(step + 1) : null,
          icon: const Icon(Icons.chevron_right),
        ),
        const SizedBox(width: 4),
        Text(
          '${step + 1} / $count',
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  Widget _diagram(ExplainerScene scene) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final Size natural = scene.size;
        double scale = constraints.maxWidth.isFinite
            ? constraints.maxWidth / natural.width
            : 1;
        if (widget.fullscreen && constraints.maxHeight.isFinite) {
          scale = math.min(scale, constraints.maxHeight / natural.height);
        } else {
          scale = math.min(scale, _kMaxInlineScale);
        }
        final Size size = natural * scale;
        final String? tooltip = _tooltip;
        final Offset? tooltipAt = _tooltipAt;
        final Widget canvas = MouseRegion(
          onHover: (PointerHoverEvent event) =>
              _updateTooltip(event.localPosition, scale),
          onExit: (_) {
            if (_tooltip != null) setState(() => _tooltip = null);
          },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: (TapUpDetails details) {
              _focus.requestFocus();
              _updateTooltip(details.localPosition, scale, toggle: true);
            },
            child: Semantics(
              label: widget.spec.title ?? 'Explainer diagram',
              child: CustomPaint(
                key: const ValueKey<String>('explainer-canvas'),
                size: size,
                painter: _ExplainerPainter(
                  scene: scene,
                  from: _from,
                  to: _state,
                  animation: _curve,
                  scale: scale,
                ),
              ),
            ),
          ),
        );
        return Center(
          child: SizedBox.fromSize(
            size: size,
            child: Stack(
              clipBehavior: Clip.none,
              children: <Widget>[
                canvas,
                if (tooltip != null && tooltipAt != null)
                  _TooltipBubble(
                    text: tooltip,
                    anchor: tooltipAt,
                    bounds: size,
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _ExplainerPainter extends CustomPainter {
  _ExplainerPainter({
    required this.scene,
    required this.from,
    required this.to,
    required this.animation,
    required this.scale,
  }) : super(repaint: animation);

  final ExplainerScene scene;
  final ExplainerState? from;
  final ExplainerState to;
  final Animation<double> animation;
  final double scale;

  @override
  void paint(Canvas canvas, Size size) {
    final SvgViewBox box = scene.viewBox;
    canvas.save();
    canvas.scale(scale);
    canvas.translate(-box.x, -box.y);
    final ExplainerState? start = from;
    final double t = animation.value;
    if (start == null || t >= 1) {
      scene.paintState(canvas, to);
    } else {
      scene.paintTween(canvas, start, to, t);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_ExplainerPainter old) =>
      old.scene != scene ||
      old.from != from ||
      old.to != to ||
      old.scale != scale;
}

class _StepDot extends StatelessWidget {
  const _StepDot({
    super.key,
    required this.active,
    required this.passed,
    required this.onTap,
    required this.label,
  });

  final bool active;
  final bool passed;
  final VoidCallback onTap;
  final String label;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color color = active
        ? scheme.primary
        : passed
        ? scheme.primary.withValues(alpha: 0.45)
        : scheme.outline;
    return Semantics(
      button: true,
      selected: active,
      label: label,
      child: InkResponse(
        onTap: onTap,
        radius: 12,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 8),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: active ? 18 : 8,
            height: 8,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(4),
            ),
          ),
        ),
      ),
    );
  }
}

class _TooltipBubble extends StatelessWidget {
  const _TooltipBubble({
    required this.text,
    required this.anchor,
    required this.bounds,
  });

  final String text;
  final Offset anchor;
  final Size bounds;

  static const double _width = 240;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final double left = (anchor.dx + 12).clamp(
      0.0,
      math.max(0.0, bounds.width - _width),
    );
    final bool below = anchor.dy < bounds.height / 2;
    return Positioned(
      left: left,
      top: below ? anchor.dy + 16 : null,
      bottom: below ? null : bounds.height - anchor.dy + 12,
      child: IgnorePointer(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: _width),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: theme.colorScheme.inverseSurface,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Text(
                text,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onInverseSurface,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ExplainerError extends StatelessWidget {
  const _ExplainerError({required this.title, required this.message});

  final String? title;
  final String message;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Icon(
          Icons.broken_image_outlined,
          size: 18,
          color: theme.colorScheme.onSurfaceVariant,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            '${title ?? 'Explainer'} can’t be shown: $message',
            style: theme.textTheme.bodySmall,
          ),
        ),
      ],
    );
  }
}

/// Full-screen explainer; pops with its final state so the inline view can
/// follow along.
class _FullscreenExplainer extends StatefulWidget {
  const _FullscreenExplainer({
    required this.spec,
    required this.step,
    required this.toggles,
  });

  final ExplainerSpec spec;
  final int step;
  final List<bool> toggles;

  @override
  State<_FullscreenExplainer> createState() => _FullscreenExplainerState();
}

class _FullscreenExplainerState extends State<_FullscreenExplainer> {
  final GlobalKey<_ExplainerViewState> _view = GlobalKey<_ExplainerViewState>();

  void _close() {
    final _ExplainerViewState? view = _view.currentState;
    Navigator.of(context)
        .pop(view == null || view._document == null ? null : view._state);
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return PopScope<ExplainerState>(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, ExplainerState? result) {
        if (!didPop) _close();
      },
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      widget.spec.title ?? 'Explainer',
                      style: theme.textTheme.titleMedium,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    icon: const Icon(Icons.close),
                    onPressed: _close,
                  ),
                ],
              ),
              Expanded(
                child: ExplainerView(
                  key: _view,
                  spec: widget.spec,
                  initialStep: widget.step,
                  initialToggles: widget.toggles,
                  fullscreen: true,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
