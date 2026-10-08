import 'package:flutter/material.dart';

import 'history_expansion.dart';
import 'tail_text.dart';
import 'tool_call_heat.dart';

/// A stretch of the agent's thinking on one line among its tool calls: the
/// end of the thought, so a live one reads as it streams in, words coming in
/// at the right. Tap for the whole thought.
class ThoughtLine extends StatefulWidget {
  const ThoughtLine({super.key, required this.text, this.active = false});

  final String text;

  /// Whether the agent is still thinking it.
  final bool active;

  /// Height of the line, shared with the tool call it may hand over to so
  /// the two swap without a jump.
  static const double lineHeight = 20;

  @override
  State<ThoughtLine> createState() => _ThoughtLineState();
}

class _ThoughtLineState extends State<ThoughtLine> {
  bool _expanded = false;

  // Explicit page-storage identifiers are shared by the whole bucket, so
  // this one carries the line's own key.
  Object get _expandedId => ('thought-expanded', widget.key);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final Object? saved = PageStorage.maybeOf(context)
        ?.readState(context, identifier: _expandedId);
    if (saved is bool) _expanded = saved;
  }

  void _toggle() {
    setState(() {
      _expanded = !_expanded;
      PageStorage.maybeOf(context)
          ?.writeState(context, _expanded, identifier: _expandedId);
    });
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color muted = theme.colorScheme.onSurfaceVariant;
    final TextStyle style = (theme.textTheme.bodySmall ?? const TextStyle())
        .copyWith(fontStyle: FontStyle.italic, color: muted);
    final bool still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    // The whole thought is built only while open: thinking runs long.
    final Widget body = _expanded
        ? Padding(
            key: const Key('thought-body'),
            padding: const EdgeInsets.fromLTRB(36, 0, 12, 10),
            child: Text(widget.text, style: style),
          )
        : const SizedBox(width: double.infinity);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        InkWell(
          onTap: _toggle,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 6, 6, 6),
            child: Row(
              children: <Widget>[
                HeatedIcon(
                  icon: Icons.psychology_outlined,
                  color: muted,
                  active: widget.active,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: SizedBox(
                    height: ThoughtLine.lineHeight,
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: TailText(
                        widget.text,
                        live: widget.active,
                        style: style,
                        background: theme.colorScheme.surfaceContainerLow,
                      ),
                    ),
                  ),
                ),
                AnimatedRotation(
                  turns: _expanded ? 0.5 : 0,
                  duration: const Duration(milliseconds: 150),
                  child: Icon(Icons.expand_more, size: 18, color: muted),
                ),
              ],
            ),
          ),
        ),
        // A long thought opens at once (AnimatedSize cannot take no time:
        // it would relayout itself in the middle of its own layout).
        if (still || !animateHistoryText(widget.text))
          body
        else
          AnimatedSize(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: body,
          ),
      ],
    );
  }
}
