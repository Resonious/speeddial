import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';

import '../../theme.dart';
import 'heat_shimmer.dart';
import 'history_expansion.dart';
import 'message_view.dart';
import 'timeline.dart';

/// Where the agent boiled the conversation down to fit its context window:
/// a divider across the timeline, everything above it reduced.
///
/// While it reduces, the label shimmers and bubbles rise and pop along the
/// line like a simmering pot. Once done it says what the context came down
/// to, and opens to the summary when the harness gave one. Reduced motion
/// holds it still.
class CompactionRow extends StatefulWidget {
  const CompactionRow({super.key, required this.item});

  final CompactionItem item;

  @override
  State<CompactionRow> createState() => _CompactionRowState();
}

class _CompactionRowState extends State<CompactionRow>
    with SingleTickerProviderStateMixin {
  late final AnimationController _simmer = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2400),
  );
  bool _open = false;
  bool _still = false;

  // Explicit page-storage identifiers are shared by the whole bucket, so
  // this one carries the row's own key.
  Object get _openId => ('compaction-open', widget.key);

  bool get _simmering => widget.item.active && !_still;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final Object? saved = PageStorage.maybeOf(context)
        ?.readState(context, identifier: _openId);
    if (saved is bool) _open = saved;
    _sync();
  }

  @override
  void didUpdateWidget(CompactionRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  void _sync() {
    if (_simmering) {
      if (!_simmer.isAnimating) _simmer.repeat();
    } else if (_simmer.isAnimating || _simmer.value != 0) {
      // Parks the glint off the left edge, and the bubbles with it.
      _simmer.value = 0;
    }
  }

  void _toggle() {
    setState(() {
      _open = !_open;
      PageStorage.maybeOf(context)
          ?.writeState(context, _open, identifier: _openId);
    });
  }

  @override
  void dispose() {
    _simmer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final SpeedDialColors colors = theme.speedDialColors;
    final Color muted = theme.colorScheme.onSurfaceVariant;
    final CompactionItem item = widget.item;
    final bool reducing = item.status == AgentActivityStatus.running;
    final bool failed = item.status == AgentActivityStatus.failed;
    final String? summary = reducing ? null : item.summary;
    final int? before = item.before;
    final int? after = item.after;
    final String label = failed
        ? 'Couldn’t reduce the conversation'
        : reducing
        ? 'Reducing the conversation…'
        : <String>[
            'Conversation reduced',
            if (before != null && after != null)
              '${compactTokens(before)} → ${compactTokens(after)} tokens',
          ].join(' · ');
    final TextStyle? style = theme.textTheme.bodySmall?.copyWith(
      color: failed ? colors.error : muted,
      fontWeight: FontWeight.w500,
    );
    final Widget text = _simmering
        ? HeatShimmer(
            animation: _simmer,
            glint: colors.flameTip,
            color: muted,
            child: Text(label, style: style),
          )
        : Text(label, style: style);
    Widget side(bool leading) => Expanded(
      child: CustomPaint(
        size: const Size(double.infinity, 28),
        painter: _SimmerPainter(
          simmer: _simmer,
          leading: leading,
          line: reducing
              ? Color.lerp(colors.border, colors.flameTip, 0.45)!
              : colors.border,
          bubble: colors.flameTip,
          bubbling: _simmering,
        ),
      ),
    );
    final Widget row = InkWell(
      key: const Key('compaction-row'),
      onTap: summary == null ? null : _toggle,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: Row(
          children: <Widget>[
            side(true),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Icon(
                    Icons.soup_kitchen_outlined,
                    size: 16,
                    color: failed
                        ? colors.error
                        : reducing
                        ? colors.flameTip
                        : muted,
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: _still
                        ? text
                        : AnimatedSwitcher(
                            duration: const Duration(milliseconds: 300),
                            child: KeyedSubtree(
                              key: ValueKey<String>(label),
                              child: text,
                            ),
                          ),
                  ),
                  if (summary != null)
                    AnimatedRotation(
                      turns: _open ? 0.5 : 0,
                      duration: const Duration(milliseconds: 150),
                      child: Icon(Icons.expand_more, size: 16, color: muted),
                    ),
                ],
              ),
            ),
            side(false),
          ],
        ),
      ),
    );
    final Widget details = _open && summary != null
        ? Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: AgentMessageView(text: summary),
          )
        : const SizedBox(width: double.infinity);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        row,
        // AnimatedSize cannot take no time, so a still summary just appears.
        if (_still || !animateHistoryDetails(<String>[summary ?? '']))
          details
        else
          AnimatedSize(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: details,
          ),
      ],
    );
  }
}

/// "12k" for 12018, "1.2M" for 1200000.
String compactTokens(int count) {
  if (count < 1000) return '$count';
  if (count < 1000000) return '${(count / 1000).round()}k';
  return '${(count / 1000000).toStringAsFixed(1)}M';
}

/// One side of the divider: a line fading in toward the label and, while
/// the conversation reduces, bubbles rising off it and popping.
class _SimmerPainter extends CustomPainter {
  _SimmerPainter({
    required this.simmer,
    required this.leading,
    required this.line,
    required this.bubble,
    required this.bubbling,
  }) : super(repaint: simmer);

  final Animation<double> simmer;

  /// Left of the label: fades in left to right; otherwise the other way.
  final bool leading;
  final Color line;
  final Color bubble;
  final bool bubbling;

  /// Where along the side each bubble rises, and how far through its rise
  /// it starts.
  static const List<(double, double)> _bubbles = <(double, double)>[
    (0.18, 0.0),
    (0.37, 0.55),
    (0.52, 0.25),
    (0.69, 0.8),
    (0.86, 0.4),
  ];

  final Paint _paint = Paint();

  @override
  void paint(Canvas canvas, Size size) {
    final double y = size.height / 2;
    final Color faded = line.withValues(alpha: 0);
    _paint
      ..style = PaintingStyle.fill
      ..shader = ui.Gradient.linear(
        Offset.zero,
        Offset(size.width, 0),
        leading ? <Color>[faded, line] : <Color>[line, faded],
      );
    canvas.drawRect(Rect.fromLTWH(0, y - 0.5, size.width, 1), _paint);
    _paint.shader = null;
    if (!bubbling) return;
    _paint
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (final (double along, double start) in _bubbles) {
      // Each rises three times a loop, out of step with the others.
      final double rise = (simmer.value * 3 + start) % 1;
      final double x = size.width * (leading ? along : 1 - along);
      _paint.color = bubble.withValues(alpha: 0.75 * math.sin(math.pi * rise));
      canvas.drawCircle(Offset(x, y - 1 - 9 * rise), 0.8 + 1.8 * rise, _paint);
    }
  }

  @override
  bool shouldRepaint(_SimmerPainter oldDelegate) =>
      oldDelegate.simmer != simmer ||
      oldDelegate.leading != leading ||
      oldDelegate.line != line ||
      oldDelegate.bubble != bubble ||
      oldDelegate.bubbling != bubbling;
}
