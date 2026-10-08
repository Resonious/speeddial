import 'package:flutter/material.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';

import '../../theme.dart';
import 'thought_line.dart';
import 'timeline.dart';
import 'tool_call_card.dart';

/// The agent at work between messages, as one card ([ToolRunItem]): what it
/// last thought and what it last did, a line each — the end of the thought
/// running on as it streams, and the tool call's description typed out, then
/// backspaced and retyped as the next call comes in — under a running count
/// once some steps are out of sight. Tapping the count opens every step;
/// tapping a line opens that step.
///
/// Thinking gets a line of its own because providers think in a burst just
/// before the call it leads to: sharing one line, the call would replace the
/// thought before it could be read. However fast steps come, the card soon
/// settles at its height, so a busy agent no longer shakes the timeline.
class ToolRunCard extends StatefulWidget {
  const ToolRunCard({
    super.key,
    required this.steps,
    this.cwd,
    this.attachmentLoader,
  });

  /// In order; never empty. Each is a [ToolCallTimelineItem] or an
  /// [AgentThoughtItem].
  final List<TimelineItem> steps;

  /// See [Timeline.cwd].
  final String? cwd;

  /// See [Timeline.attachmentLoader].
  final Future<AttachmentData> Function(String attachmentId)? attachmentLoader;

  /// Lists longer than this open and close at once rather than sliding.
  static const int maxAnimatedSteps = 8;

  @override
  State<ToolRunCard> createState() => _ToolRunCardState();
}

class _ToolRunCardState extends State<ToolRunCard> {
  bool _open = false;

  // Explicit page-storage identifiers are shared by the whole bucket, so
  // everything kept here carries the run's own key.
  Object get _openId => ('tool-run-open', widget.key);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final Object? saved = PageStorage.maybeOf(context)
        ?.readState(context, identifier: _openId);
    if (saved is bool) _open = saved;
  }

  void _toggle() {
    setState(() {
      _open = !_open;
      PageStorage.maybeOf(context)
          ?.writeState(context, _open, identifier: _openId);
    });
  }

  Widget _step(TimelineItem step, int index, {bool latest = false}) =>
      switch (step) {
        ToolCallTimelineItem call => ToolCallCard(
          // One slot for whichever call is latest: handing it the next call
          // backspaces and retypes the line.
          key: ValueKey<Object>(
            latest
                ? ('latest', widget.key)
                : ('call', call.id ?? call.toolCall.id),
          ),
          toolCall: call.toolCall,
          approval: call.approval,
          active: call.active,
          startedAt: call.startedAt,
          embedded: true,
          typed: latest,
          cwd: widget.cwd,
          attachmentLoader: widget.attachmentLoader,
        ),
        AgentThoughtItem thought => ThoughtLine(
          key: ValueKey<Object>(('thought', thought.id ?? index)),
          text: thought.text,
          active: thought.active,
        ),
        _ => const SizedBox.shrink(),
      };

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final List<TimelineItem> steps = widget.steps;
    int thought = -1;
    int call = -1;
    int calls = 0;
    int failed = 0;
    for (int i = 0; i < steps.length; i++) {
      final TimelineItem step = steps[i];
      if (step is AgentThoughtItem) thought = i;
      if (step is! ToolCallTimelineItem) continue;
      call = i;
      calls++;
      if (step.toolCall.status == ToolCallStatus.failed) failed++;
    }
    // Only steps out of sight need counting, and a list to open.
    final int onShow = (thought < 0 ? 0 : 1) + (call < 0 ? 0 : 1);
    final bool counted = steps.length > onShow;
    final bool open = _open && counted;
    final bool still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final Duration slide = still || steps.length > ToolRunCard.maxAnimatedSteps
        ? Duration.zero
        : const Duration(milliseconds: 220);
    final Duration fade = still
        ? Duration.zero
        : const Duration(milliseconds: 180);
    // AnimatedSize cannot take no time (it would relayout itself in the
    // middle of its own layout), so reduced motion leaves it out.
    Widget grow(Widget child) => still
        ? child
        : AnimatedSize(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: child,
          );

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 2, horizontal: 8),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          // The count slides in once, when a step first goes out of sight.
          grow(
            counted
                ? _RunHeader(
                    calls: calls,
                    thoughts: steps.length - calls,
                    failed: failed,
                    open: open,
                    still: still,
                    onTap: _toggle,
                  )
                : const SizedBox(width: double.infinity),
          ),
          AnimatedSwitcher(
            duration: slide,
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            transitionBuilder: (Widget child, Animation<double> animation) =>
                SizeTransition(
                  sizeFactor: animation,
                  alignment: Alignment.topCenter,
                  child: FadeTransition(opacity: animation, child: child),
                ),
            layoutBuilder: _stacked,
            child: open
                ? Column(
                    key: const ValueKey<String>('list'),
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      for (int i = 0; i < steps.length; i++) _step(steps[i], i),
                    ],
                  )
                // What the agent last thought, over what it last did.
                : Column(
                    key: const ValueKey<String>('latest'),
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      grow(
                        thought < 0
                            ? const SizedBox(width: double.infinity)
                            // A new thought fades in over the last one.
                            : AnimatedSwitcher(
                                duration: fade,
                                layoutBuilder: _stacked,
                                child: _step(steps[thought], thought),
                              ),
                      ),
                      if (call >= 0) _step(steps[call], call, latest: true),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  static Widget _stacked(Widget? current, List<Widget> previous) => Stack(
    alignment: Alignment.topCenter,
    children: <Widget>[...previous, ?current],
  );
}

/// "7 tool calls · 3 thoughts", each number rolling over as steps come in.
class _RunHeader extends StatelessWidget {
  const _RunHeader({
    required this.calls,
    required this.thoughts,
    required this.failed,
    required this.open,
    required this.still,
    required this.onTap,
  });

  final int calls;
  final int thoughts;
  final int failed;
  final bool open;
  final bool still;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final SpeedDialColors colors = theme.speedDialColors;
    final Color muted = theme.colorScheme.onSurfaceVariant;
    final TextStyle? style = theme.textTheme.bodySmall?.copyWith(
      color: muted,
      fontWeight: FontWeight.w500,
    );
    List<Widget> count(int n, String one, String many) => <Widget>[
      _RollingNumber(value: n, style: style, still: still),
      Text(' ${n == 1 ? one : many}', style: style),
    ];
    return InkWell(
      key: const Key('tool-run-header'),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 6, 6, 0),
        child: Row(
          children: <Widget>[
            Icon(Icons.layers_outlined, size: 16, color: muted),
            const SizedBox(width: 10),
            Expanded(
              // Long counts on a narrow screen shrink rather than overflow.
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    if (calls > 0) ...count(calls, 'tool call', 'tool calls'),
                    if (calls > 0 && thoughts > 0) Text(' · ', style: style),
                    if (thoughts > 0) ...count(thoughts, 'thought', 'thoughts'),
                    if (failed > 0)
                      Text(
                        ' · $failed failed',
                        style: style?.copyWith(color: colors.error),
                      ),
                  ],
                ),
              ),
            ),
            AnimatedRotation(
              turns: open ? 0.5 : 0,
              duration: const Duration(milliseconds: 150),
              child: Icon(Icons.expand_more, size: 18, color: muted),
            ),
          ],
        ),
      ),
    );
  }
}

/// A count that rolls up to its new value.
class _RollingNumber extends StatelessWidget {
  const _RollingNumber({
    required this.value,
    required this.style,
    required this.still,
  });

  final int value;
  final TextStyle? style;
  final bool still;

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: AnimatedSwitcher(
        duration: still ? Duration.zero : const Duration(milliseconds: 240),
        transitionBuilder: (Widget child, Animation<double> animation) =>
            SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0, 0.7),
                end: Offset.zero,
              ).animate(animation),
              child: FadeTransition(opacity: animation, child: child),
            ),
        child: Text('$value', key: ValueKey<int>(value), style: style),
      ),
    );
  }
}
