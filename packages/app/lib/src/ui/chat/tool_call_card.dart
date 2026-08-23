import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';

import '../../theme.dart';
import 'active_pulse.dart';
import 'message_view.dart';

/// Semantic accent per tool [ToolCall.kind], used for the card's left border.
Color _kindColor(BuildContext context, String kind) {
  final SpeedDialColors c = context.speedDialColors;
  switch (kind) {
    case 'read':
    case 'fetch':
      return c.running;
    case 'edit':
      return c.success;
    case 'delete':
      return c.error;
    case 'move':
      return c.attention;
    case 'search':
      return c.purple;
    case 'execute':
      return c.running;
    case 'think':
    case 'other':
      return c.idle;
    default:
      return c.idle;
  }
}

IconData _statusIcon(ToolCallStatus status) => switch (status) {
  ToolCallStatus.pending => Icons.pause_circle_outline,
  ToolCallStatus.running => Icons.play_circle_outline,
  ToolCallStatus.completed => Icons.check_circle_outline,
  ToolCallStatus.failed => Icons.cancel_outlined,
};

Color _statusColor(BuildContext context, ToolCallStatus status) {
  final SpeedDialColors c = context.speedDialColors;
  return switch (status) {
    ToolCallStatus.pending => c.idle,
    ToolCallStatus.running => c.running,
    ToolCallStatus.completed => c.success,
    ToolCallStatus.failed => c.error,
  };
}

/// A collapsible record of one agent tool call: status icon, kind-colored
/// left border, title, locations, and per-kind content (text / diff /
/// terminal). Expanded by default while the call is running, collapsed once
/// it completes; the user can toggle freely.
class ToolCallCard extends StatefulWidget {
  const ToolCallCard({
    super.key,
    required this.toolCall,
    this.attachmentLoader,
  });

  final ToolCall toolCall;

  /// Resolves image content through `attachments.read`. When absent, image
  /// content degrades to its attachment metadata.
  final Future<AttachmentData> Function(String attachmentId)? attachmentLoader;

  @override
  State<ToolCallCard> createState() => _ToolCallCardState();
}

class _ToolCallCardState extends State<ToolCallCard> {
  static final RegExp _commandLineBreak = RegExp(r'[\r\n]+');

  late bool _expanded = _shouldDefaultExpand(widget.toolCall.status);
  late String _title = _displayTitle(widget.toolCall);

  static bool _shouldDefaultExpand(ToolCallStatus status) =>
      status == ToolCallStatus.running || status == ToolCallStatus.pending;

  static String _displayTitle(ToolCall toolCall) {
    if (toolCall.kind != 'execute') return toolCall.title;
    final Object? rawInput = toolCall.rawInput;
    if (rawInput is! Map<Object?, Object?>) return toolCall.title;

    String command = _commandText(rawInput['command']);
    if (command.trim().isEmpty) command = _commandText(rawInput['cmd']);
    final String trimmed = command.trim();
    if (trimmed.isEmpty) return toolCall.title;
    return trimmed.replaceAll(_commandLineBreak, ' ');
  }

  static String _commandText(Object? rawCommand) => switch (rawCommand) {
    final String value => value,
    final List<Object?> values => values.whereType<String>().join(' '),
    _ => '',
  };

  @override
  void didUpdateWidget(ToolCallCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    _title = _displayTitle(widget.toolCall);
    if (oldWidget.toolCall.status != widget.toolCall.status) {
      // Track the agent's lifecycle: jump open while running, collapse when
      // the call settles.
      _expanded = _shouldDefaultExpand(widget.toolCall.status);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ToolCall toolCall = widget.toolCall;
    final ThemeData theme = Theme.of(context);
    final BorderSide kindBorder = BorderSide(
      color: _kindColor(context, toolCall.kind),
      width: 3,
    );
    final Color statusColor = _statusColor(context, toolCall.status);
    final TextStyle? titleStyle = theme.textTheme.bodyMedium?.copyWith(
      fontWeight: FontWeight.w600,
    );

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: context.speedDialColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Container(
              decoration: BoxDecoration(border: Border(left: kindBorder)),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: Row(
                children: <Widget>[
                  ActivePulse(
                    active: toolCall.status == ToolCallStatus.running,
                    pulseKey: ValueKey<String>('tool-pulse-${toolCall.id}'),
                    child: Icon(
                      _statusIcon(toolCall.status),
                      size: 18,
                      color: statusColor,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: ActivePulse(
                      active: toolCall.status == ToolCallStatus.running,
                      pulseKey: ValueKey<String>('tool-pulse-${toolCall.id}'),
                      child: Text(
                        _title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: titleStyle,
                      ),
                    ),
                  ),
                  if (toolCall.locations.isNotEmpty)
                    Flexible(
                      child: Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: Text(
                          toolCall.locations.join(', '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: context.speedDialColors.mono.copyWith(
                            fontSize: 11,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ),
                  AnimatedRotation(
                    turns: _expanded ? 0.5 : 0,
                    duration: const Duration(milliseconds: 150),
                    child: Icon(
                      Icons.expand_more,
                      size: 18,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
          AnimatedCrossFade(
            duration: const Duration(milliseconds: 150),
            crossFadeState: _expanded
                ? CrossFadeState.showSecond
                : CrossFadeState.showFirst,
            firstChild: const SizedBox(width: double.infinity, height: 0),
            secondChild: _ToolCallContentList(
              toolCall: toolCall,
              kindColor: kindBorder,
              attachmentLoader: _expanded ? widget.attachmentLoader : null,
            ),
          ),
        ],
      ),
    );
  }
}

class _ToolCallContentList extends StatelessWidget {
  const _ToolCallContentList({
    required this.toolCall,
    required this.kindColor,
    required this.attachmentLoader,
  });

  final ToolCall toolCall;
  final BorderSide kindColor;
  final Future<AttachmentData> Function(String attachmentId)? attachmentLoader;

  @override
  Widget build(BuildContext context) {
    final bool hasInput = _hasRawValue(toolCall.rawInput);
    final bool hasTypedOutput = toolCall.content.isNotEmpty;
    final bool hasRawOutput = _hasRawValue(toolCall.rawOutput);
    final List<Widget> children = <Widget>[
      if (hasInput) _RawToolDataView(label: 'Input', value: toolCall.rawInput!),
      if (hasTypedOutput) const _ToolDataLabel(label: 'Output'),
      for (final ToolCallContent content in toolCall.content)
        _ToolCallContentView(
          content: content,
          attachmentLoader: attachmentLoader,
        ),
      if (!hasTypedOutput && hasRawOutput)
        _RawToolDataView(label: 'Output', value: toolCall.rawOutput!),
      if (!hasTypedOutput && !hasRawOutput)
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
          child: Text(
            'No output',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      if (toolCall.locations.isNotEmpty)
        _LocationChips(locations: toolCall.locations),
    ];
    return Container(
      decoration: BoxDecoration(
        border: Border(left: kindColor),
        color: Theme.of(context).colorScheme.surfaceContainerLow,
      ),
      padding: const EdgeInsets.fromLTRB(10, 4, 10, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );
  }
}

class _ToolCallContentView extends StatelessWidget {
  const _ToolCallContentView({
    required this.content,
    required this.attachmentLoader,
  });

  final ToolCallContent content;
  final Future<AttachmentData> Function(String attachmentId)? attachmentLoader;

  @override
  Widget build(BuildContext context) {
    final SpeedDialColors colors = context.speedDialColors;
    switch (content) {
      case ToolCallText text:
        return _ScrollableMono(
          background: colors.codeBackground,
          child: Text(text.text, style: colors.mono),
        );
      case ToolCallImage image:
        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: AttachmentView(
            attachment: image.attachment,
            loader: attachmentLoader,
          ),
        );
      case ToolCallDiff diff:
        return _DiffView(diff: diff);
      case ToolCallPatch patch:
        return _PatchView(patch: patch);
      case ToolCallTerminal terminal:
        return _ScrollableMono(
          background: const Color(0xFF000000),
          child: Text(
            terminal.output,
            style: colors.mono.copyWith(color: const Color(0xFFE6EDF3)),
          ),
        );
    }
  }
}

class _ToolDataLabel extends StatelessWidget {
  const _ToolDataLabel({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 2, bottom: 4),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _RawToolDataView extends StatelessWidget {
  const _RawToolDataView({required this.label, required this.value});

  final String label;
  final Object value;

  @override
  Widget build(BuildContext context) {
    final SpeedDialColors colors = context.speedDialColors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _ToolDataLabel(label: label),
        _ScrollableMono(
          background: colors.codeBackground,
          child: Text(_formatRawValue(value), style: colors.mono),
        ),
      ],
    );
  }
}

bool _hasRawValue(Object? value) => switch (value) {
  null => false,
  String value => value.isNotEmpty,
  Map<Object?, Object?> value => value.isNotEmpty,
  Iterable<Object?> value => value.isNotEmpty,
  _ => true,
};

String _formatRawValue(Object value) {
  if (value is String) return value;
  try {
    return const JsonEncoder.withIndent('  ').convert(value);
  } on Object {
    return value.toString();
  }
}

/// Horizontally scrollable monospace box for long tool output.
class _ScrollableMono extends StatelessWidget {
  const _ScrollableMono({required this.child, required this.background});

  final Widget child;
  final Color background;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(6),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: child,
      ),
    );
  }
}

/// Unified-diff rendering: old lines prefixed `-` in red, new lines prefixed
/// `+` in green, hunks left untouched.
class _DiffView extends StatelessWidget {
  const _DiffView({required this.diff});

  final ToolCallDiff diff;

  @override
  Widget build(BuildContext context) {
    final SpeedDialColors colors = context.speedDialColors;
    final ThemeData theme = Theme.of(context);
    final List<InlineSpan> spans = <InlineSpan>[];
    void add(String sign, String line, Color color) {
      spans.add(
        TextSpan(
          text: '$sign$line\n',
          style: colors.mono.copyWith(color: color),
        ),
      );
    }

    if (diff.path.isNotEmpty) {
      spans.add(
        TextSpan(
          text: '${diff.path}\n',
          style: colors.mono.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            fontWeight: FontWeight.w600,
          ),
        ),
      );
    }
    for (final String line in (diff.oldText ?? '').split('\n')) {
      if (line.isEmpty) continue;
      add('-', line, colors.diffRemove);
    }
    for (final String line in diff.newText.split('\n')) {
      if (line.isEmpty) continue;
      add('+', line, colors.success);
    }
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: colors.codeBackground,
        borderRadius: BorderRadius.circular(6),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Text.rich(TextSpan(children: spans), style: colors.mono),
      ),
    );
  }
}

/// Preserves and highlights a provider-native unified diff.
class _PatchView extends StatelessWidget {
  const _PatchView({required this.patch});

  final ToolCallPatch patch;

  @override
  Widget build(BuildContext context) {
    final SpeedDialColors colors = context.speedDialColors;
    final Color neutral = Theme.of(context).colorScheme.onSurfaceVariant;
    final List<InlineSpan> spans = <InlineSpan>[
      if (patch.path.isNotEmpty)
        TextSpan(
          text: '${patch.path}\n',
          style: colors.mono.copyWith(
            color: neutral,
            fontWeight: FontWeight.w600,
          ),
        ),
      for (final String line in patch.diff.split('\n'))
        TextSpan(
          text: '$line\n',
          style: colors.mono.copyWith(
            color: switch (line) {
              final String value
                  when value.startsWith('+++') ||
                      value.startsWith('---') ||
                      value.startsWith('diff ') ||
                      value.startsWith('index ') =>
                neutral,
              final String value when value.startsWith('@@') => colors.purple,
              final String value when value.startsWith('+') => colors.success,
              final String value when value.startsWith('-') =>
                colors.diffRemove,
              _ => null,
            },
          ),
        ),
    ];
    return _ScrollableMono(
      background: colors.codeBackground,
      child: Text.rich(TextSpan(children: spans), style: colors.mono),
    );
  }
}

class _LocationChips extends StatelessWidget {
  const _LocationChips({required this.locations});

  final List<String> locations;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      children: <Widget>[
        for (final String path in locations)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: context.speedDialColors.border),
            ),
            child: Text(
              path,
              style: context.speedDialColors.mono.copyWith(fontSize: 11),
            ),
          ),
      ],
    );
  }
}
