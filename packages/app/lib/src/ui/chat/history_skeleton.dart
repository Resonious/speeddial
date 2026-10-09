import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../theme.dart';
import 'heat_shimmer.dart';
import 'message_view.dart';

/// Stands in for a session's conversation while its history loads: faint
/// bubbles laid out like the real timeline, from the bottom up, under a warm
/// glint sweeping across like the one over a message still baking.
///
/// It fades in only once the wait outlasts a blink, so a quick load never
/// flashes it. When [failed], it lies cold and still, dimmed, behind the
/// error. Reduced motion holds it still.
class HistorySkeleton extends StatefulWidget {
  const HistorySkeleton({super.key, this.failed = false, this.caption});

  final bool failed;

  /// A line along its foot, under the same glint ("Loading history…").
  final String? caption;

  /// How long a load may take before the skeleton shows at all.
  static const Duration patience = Duration(milliseconds: 120);

  @override
  State<HistorySkeleton> createState() => _HistorySkeletonState();
}

class _HistorySkeletonState extends State<HistorySkeleton>
    with TickerProviderStateMixin {
  late final AnimationController _glint = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  );
  late final AnimationController _shown = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
  );
  Timer? _wait;
  bool _still = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (_still) {
      _wait?.cancel();
      _shown.value = 1;
    } else if (_shown.isDismissed && _wait == null) {
      _wait = Timer(HistorySkeleton.patience, () {
        if (mounted) _shown.forward();
      });
    }
    _syncGlint();
  }

  @override
  void didUpdateWidget(HistorySkeleton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.failed != oldWidget.failed) _syncGlint();
  }

  void _syncGlint() {
    if (_still || widget.failed) {
      // Parks the glint off the left edge (and stops the loop).
      _glint.value = 0;
    } else if (!_glint.isAnimating) {
      _glint.repeat();
    }
  }

  @override
  void dispose() {
    _wait?.cancel();
    _glint.dispose();
    _shown.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final SpeedDialColors colors = theme.speedDialColors;
    final bool dark = theme.brightness == Brightness.dark;
    final String? caption = widget.caption;
    return FadeTransition(
      key: const Key('history-skeleton'),
      opacity: _shown,
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          Opacity(
            opacity: widget.failed ? 0.45 : 1,
            child: RepaintBoundary(
              child: CustomPaint(
                painter: _SkeletonPainter(
                  glint: _glint,
                  agent: theme.colorScheme.surfaceContainerHigh,
                  agentBorder: colors.border,
                  user: theme.colorScheme.primaryContainer.withValues(
                    alpha: dark ? 0.55 : 0.75,
                  ),
                  run: theme.colorScheme.surfaceContainerLow,
                  bar: theme.colorScheme.onSurface.withValues(
                    alpha: dark ? 0.09 : 0.07,
                  ),
                  userBar: theme.colorScheme.onPrimaryContainer.withValues(
                    alpha: 0.12,
                  ),
                  heat: colors.flameTip.withValues(alpha: dark ? 0.22 : 0.3),
                ),
              ),
            ),
          ),
          if (caption != null)
            Positioned(
              left: 16,
              right: 16,
              bottom: 10,
              child: Align(
                alignment: Alignment.centerLeft,
                child: HeatShimmer(
                  animation: _glint,
                  color: theme.colorScheme.onSurfaceVariant,
                  glint: colors.flameTip,
                  child: Text(
                    caption,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.w500,
                      letterSpacing: 0.2,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

enum _Kind { agent, user, run }

/// One placeholder row: whose it is and how full each of its lines runs.
class _Row {
  const _Row(this.kind, this.lines);

  final _Kind kind;
  final List<double> lines;
}

class _SkeletonPainter extends CustomPainter {
  _SkeletonPainter({
    required this.glint,
    required this.agent,
    required this.agentBorder,
    required this.user,
    required this.run,
    required this.bar,
    required this.userBar,
    required this.heat,
  }) : super(repaint: glint);

  final Animation<double> glint;
  final Color agent;
  final Color agentBorder;
  final Color user;
  final Color run;
  final Color bar;
  final Color userBar;
  final Color heat;

  /// A conversation's worth of rows, newest first; repeated to fill.
  static const List<_Row> _rows = <_Row>[
    _Row(_Kind.agent, <double>[0.92, 0.84, 0.58]),
    _Row(_Kind.run, <double>[0.55]),
    _Row(_Kind.user, <double>[0.5]),
    _Row(_Kind.agent, <double>[0.88, 0.36]),
    _Row(_Kind.run, <double>[0.42]),
    _Row(_Kind.user, <double>[0.72, 0.4]),
    _Row(_Kind.agent, <double>[0.9, 0.86, 0.9, 0.3]),
    _Row(_Kind.user, <double>[0.35]),
  ];

  static const double _line = 20;
  static const double _barHeight = 9;

  /// Room left for the turn's row at the foot of the timeline.
  static const double _foot = 36;

  final Paint _fill = Paint();
  final Paint _stroke = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1;
  final Paint _glintPaint = Paint();

  @override
  void paint(Canvas canvas, Size size) {
    final double band = math.max(size.width * 0.25, 80);
    final double center = -band + (size.width + band * 2) * glint.value;
    _glintPaint.shader = glint.value <= 0
        ? null
        : ui.Gradient.linear(
            Offset(center - band, 0),
            Offset(center + band, band * 0.4),
            <Color>[heat.withValues(alpha: 0), heat, heat.withValues(alpha: 0)],
            const <double>[0, 0.5, 1],
          );
    final double width = size.width;
    double bottom = size.height - _foot;
    for (int i = 0; bottom > 0; i++) {
      final _Row row = _rows[i % _rows.length];
      final double height = _heightOf(row);
      final double top = bottom - height;
      // Rows fade away toward the top, where older history would be.
      final double reach = (bottom / (size.height * 0.8)).clamp(0.0, 1.0);
      final double fade = reach * reach;
      if (fade > 0.02) _paintRow(canvas, row, top, width, fade);
      bottom = top;
    }
  }

  double _heightOf(_Row row) => switch (row.kind) {
    _Kind.run => 2 + 32 + 2,
    _ => 4 + 8 + row.lines.length * _line + 8 + 4,
  };

  void _paintRow(
    Canvas canvas,
    _Row row,
    double top,
    double width,
    double fade,
  ) {
    switch (row.kind) {
      case _Kind.run:
        final RRect card = RRect.fromRectAndRadius(
          Rect.fromLTWH(8, top + 2, width - 16, 32),
          const Radius.circular(8),
        );
        _fill.color = run.withValues(alpha: run.a * fade);
        canvas.drawRRect(card, _fill);
        _paintBar(canvas, Rect.fromLTWH(18, top + 13, 10, 10), bar, fade);
        _paintBar(
          canvas,
          Rect.fromLTWH(
            38,
            top + 13.5,
            (width - 70) * row.lines.first,
            _barHeight,
          ),
          bar,
          fade,
        );
      case _Kind.agent:
      case _Kind.user:
        final bool mine = row.kind == _Kind.user;
        final double room = math.min(width - 16, mine ? 560 : 720);
        final double longest = row.lines.reduce(math.max);
        final double inner = (room - 24) * (mine ? 0.85 : 1);
        final double bubbleWidth = inner * longest + 24;
        final double left = mine ? width - 8 - bubbleWidth : 8;
        final Rect bounds = Rect.fromLTWH(
          left,
          top + 4,
          bubbleWidth,
          8 + row.lines.length * _line + 8,
        );
        final RRect bubble = mine
            ? UserMessageBubble.radius.toRRect(bounds)
            : RRect.fromRectAndCorners(
                bounds,
                topLeft: const Radius.circular(4),
                topRight: const Radius.circular(14),
                bottomLeft: const Radius.circular(14),
                bottomRight: const Radius.circular(14),
              );
        final Color fill = mine ? user : agent;
        _fill.color = fill.withValues(alpha: fill.a * fade);
        canvas.drawRRect(bubble, _fill);
        if (!mine) {
          _stroke.color = agentBorder.withValues(alpha: agentBorder.a * fade);
          canvas.drawRRect(bubble, _stroke);
        }
        for (int i = 0; i < row.lines.length; i++) {
          final double lineWidth = inner * row.lines[i];
          _paintBar(
            canvas,
            Rect.fromLTWH(
              mine ? bounds.right - 12 - lineWidth : bounds.left + 12,
              bounds.top + 8 + i * _line + (_line - _barHeight) / 2,
              lineWidth,
              _barHeight,
            ),
            mine ? userBar : bar,
            fade,
          );
        }
    }
  }

  void _paintBar(Canvas canvas, Rect rect, Color color, double fade) {
    final RRect shape = RRect.fromRectAndRadius(
      rect,
      Radius.circular(rect.height / 2),
    );
    _fill.color = color.withValues(alpha: color.a * fade);
    canvas.drawRRect(shape, _fill);
    if (_glintPaint.shader == null) return;
    // Faint rows catch a fainter glint.
    _glintPaint.color = Color.fromRGBO(255, 255, 255, fade);
    canvas.drawRRect(shape, _glintPaint);
  }

  @override
  bool shouldRepaint(_SkeletonPainter oldDelegate) =>
      oldDelegate.glint != glint ||
      oldDelegate.agent != agent ||
      oldDelegate.agentBorder != agentBorder ||
      oldDelegate.user != user ||
      oldDelegate.run != run ||
      oldDelegate.bar != bar ||
      oldDelegate.userBar != userBar ||
      oldDelegate.heat != heat;
}
