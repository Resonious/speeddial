import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';

import '../../theme.dart';
import 'heat_shimmer.dart';
import 'message_view.dart';
import 'tool_call_edit_diff.dart';
import 'tool_call_heat.dart';
import 'thought_line.dart';
import 'tool_call_summary.dart';
import 'typed_text.dart';

/// Semantic accent per tool [ToolCall.kind], used for its row's icon.
Color toolKindColor(BuildContext context, String kind) {
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

/// The icon for a tool [ToolCall.kind].
IconData toolKindIcon(String kind) => switch (kind) {
  'execute' => Icons.terminal,
  'read' => Icons.description_outlined,
  'edit' => Icons.edit_outlined,
  'delete' => Icons.delete_outline,
  'move' => Icons.drive_file_move_outline,
  'search' => Icons.search,
  'fetch' => Icons.public,
  'think' => Icons.psychology_outlined,
  _ => Icons.extension_outlined,
};

/// Where the permission request gating a tool call stands.
enum ToolApprovalState {
  /// Waiting for an answer (the permission banner asks for it).
  pending,

  /// Allowed, whether by the user or automatically.
  allowed,

  /// Rejected.
  denied,

  /// Settled without a choice, e.g. expired.
  lapsed,
}

/// The outcome of the permission request for one tool call, shown on the
/// tool's own row instead of separate request/answer rows.
class ToolApproval {
  const ToolApproval(this.state, {this.choice});

  /// Settles [request] with the chosen [optionId] (null while pending).
  factory ToolApproval.of(PermissionRequest request, String? optionId) {
    if (optionId == null) return const ToolApproval(ToolApprovalState.pending);
    for (final PermissionOption option in request.options) {
      if (option.optionId != optionId) continue;
      return ToolApproval(switch (option.kind) {
        PermissionKind.allowOnce ||
        PermissionKind.allowAlways => ToolApprovalState.allowed,
        PermissionKind.rejectOnce ||
        PermissionKind.rejectAlways => ToolApprovalState.denied,
      }, choice: option.name);
    }
    return ToolApproval(ToolApprovalState.lapsed, choice: optionId);
  }

  final ToolApprovalState state;

  /// The chosen option as the agent phrased it ("Yes, and don't ask again
  /// for …").
  final String? choice;
}

/// A collapsible record of one agent tool call, read like a log line: a
/// kind icon, what the call did, and the command or target beneath it, with
/// per-kind content (text / diff / terminal) on expansion. Collapsed until
/// tapped, so calls coming and going never shift the timeline.
///
/// While [active] the call is on the heat: its icon glows, a glint sweeps
/// its title, and the time it has taken ticks at the end of the row. Once it
/// finishes it cools back down.
class ToolCallCard extends StatefulWidget {
  const ToolCallCard({
    super.key,
    required this.toolCall,
    this.approval,
    this.active = false,
    this.startedAt,
    this.typed = false,
    this.embedded = false,
    this.cwd,
    this.attachmentLoader,
  });

  final ToolCall toolCall;

  /// One line, typed: what the call did, typed out as it comes in and
  /// backspaced and retyped when the card is handed the next call. The
  /// command moves into the details.
  final bool typed;

  /// Sits inside another card (a run of calls), which draws the surface.
  final bool embedded;

  /// Outcome of the permission request gating this call, if there was one.
  final ToolApproval? approval;

  /// Whether the call is in progress: unfinished, in a running turn.
  final bool active;

  /// When the call started, for its running time.
  final DateTime? startedAt;

  /// Session working directory; paths under it read as relative.
  final String? cwd;

  /// Resolves image content through `attachments.read`. When absent, image
  /// content degrades to its attachment metadata.
  final Future<AttachmentData> Function(String attachmentId)? attachmentLoader;

  @override
  State<ToolCallCard> createState() => _ToolCallCardState();
}

class _ToolCallCardState extends State<ToolCallCard>
    with TickerProviderStateMixin {
  final GlobalKey _detailsKey = GlobalKey();
  bool _expanded = false;
  bool _collapseImmediately = false;
  late ToolCallSummary _summary = summarizeToolCall(
    widget.toolCall,
    cwd: widget.cwd,
  );

  /// Glows the icon, sweeps the title's glint and fades the running time
  /// while the call is in progress, cooling once it is done.
  late final Heat _heat = Heat(this, onCooled: _cooled);
  bool _still = false;

  void _cooled() {
    if (mounted) setState(() {});
  }

  bool _detailsAreLarge() {
    final RenderBox? box =
        _detailsKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return true;
    final double viewportHeight =
        Scrollable.maybeOf(context)?.position.viewportDimension ??
        MediaQuery.sizeOf(context).height;
    return box.size.height > viewportHeight * 0.5;
  }

  Object get _expansionStorageId =>
      ('tool-expanded', widget.key ?? widget.toolCall.id);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final Object? saved = PageStorage.maybeOf(context)
        ?.readState(context, identifier: _expansionStorageId);
    if (saved is bool) _expanded = saved;
    _still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    _heat.sync(active: widget.active, still: _still);
  }

  @override
  void dispose() {
    _heat.dispose();
    super.dispose();
  }

  void _toggleExpanded() {
    final bool expanding = !_expanded;
    final bool collapseImmediately = !expanding && _detailsAreLarge();
    setState(() {
      _expanded = expanding;
      PageStorage.maybeOf(context)
          ?.writeState(context, expanding, identifier: _expansionStorageId);
      _collapseImmediately = collapseImmediately;
    });
  }

  @override
  void didUpdateWidget(ToolCallCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.toolCall, widget.toolCall) ||
        oldWidget.cwd != widget.cwd) {
      _summary = summarizeToolCall(widget.toolCall, cwd: widget.cwd);
    }
    if (widget.active != oldWidget.active) {
      _heat.sync(active: widget.active, still: _still);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ToolCall toolCall = widget.toolCall;
    final ThemeData theme = Theme.of(context);
    final SpeedDialColors colors = context.speedDialColors;
    final bool failed = toolCall.status == ToolCallStatus.failed;
    final Color iconColor = switch (toolCall.status) {
      ToolCallStatus.pending => colors.idle,
      ToolCallStatus.running => colors.running,
      ToolCallStatus.completed => toolKindColor(context, toolCall.kind),
      ToolCallStatus.failed => colors.error,
    };
    final ToolCallSummary summary = _summary;
    final ToolApprovalState? approval = widget.approval?.state;
    final Animation<double> heat = _heat.level;
    final Animation<double> glint = _heat.sweep;
    final bool hot = _heat.hot;
    final TextStyle? titleStyle = summary.titleIsCommand
        ? colors.mono.copyWith(
            fontSize: 12.5,
            color: failed ? colors.error : theme.colorScheme.onSurface,
          )
        : theme.textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.w500,
            color: failed ? colors.error : null,
          );
    final Widget text = widget.typed
        // A fixed line, so swapping with a thought (or a command for a
        // description) never moves anything.
        ? SizedBox(
            height: ThoughtLine.lineHeight,
            child: Align(
              alignment: Alignment.centerLeft,
              child: TypedText(
                summary.title,
                style: titleStyle,
                typeIn: widget.active,
                caretColor: theme.brightness == Brightness.dark
                    ? colors.flameTip
                    : colors.flameRoot,
              ),
            ),
          )
        : Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                summary.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: titleStyle,
              ),
              if (summary.detail != null)
                Text(
                  summary.detail!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: colors.mono.copyWith(
                    fontSize: 11,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
            ],
          );

    return Container(
      margin: widget.embedded
          ? EdgeInsets.zero
          : const EdgeInsets.symmetric(vertical: 2, horizontal: 8),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: widget.embedded ? null : theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          InkWell(
            onTap: _toggleExpanded,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 6, 6, 6),
              child: Row(
                children: <Widget>[
                  if (hot)
                    HotToolIcon(
                      key: ValueKey<String>('tool-heat-${toolCall.id}'),
                      icon: toolKindIcon(toolCall.kind),
                      color: iconColor,
                      heat: heat,
                      flicker: glint,
                    )
                  else
                    Icon(
                      toolKindIcon(toolCall.kind),
                      size: 16,
                      color: iconColor,
                    ),
                  const SizedBox(width: 10),
                  Expanded(
                    // Each sweep repaints the glint alone, not the card or
                    // the text under it.
                    child: hot && !_still
                        ? RepaintBoundary(
                            child: HeatShimmer(
                              animation: glint,
                              glint: colors.flameTip,
                              strength: heat,
                              child: RepaintBoundary(child: text),
                            ),
                          )
                        : text,
                  ),
                  if (hot)
                    FadeTransition(
                      opacity: heat,
                      child: Padding(
                        padding: const EdgeInsets.only(left: 6),
                        child: ElapsedTime(
                          // A typed card hands over to the next call.
                          key: ValueKey<String>(toolCall.id),
                          since: widget.startedAt,
                          running: widget.active,
                          style: colors.mono.copyWith(
                            fontSize: 11,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ),
                  if (approval == ToolApprovalState.pending)
                    _StatusPill(
                      label: 'Needs approval',
                      color: colors.waitingPermission,
                    )
                  else if (approval == ToolApprovalState.denied)
                    _StatusPill(label: 'Denied', color: colors.error)
                  else if (failed)
                    _StatusPill(label: 'Failed', color: colors.error),
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
          if (!_expanded && _collapseImmediately)
            const SizedBox.shrink()
          else
            AnimatedCrossFade(
              duration: const Duration(milliseconds: 150),
              crossFadeState: _expanded
                  ? CrossFadeState.showSecond
                  : CrossFadeState.showFirst,
              firstChild: const SizedBox(width: double.infinity, height: 0),
              secondChild: _ToolCallContentList(
                key: _detailsKey,
                toolCall: toolCall,
                command: widget.typed ? summary.detail : null,
                approval: widget.approval,
                inProgress: widget.active,
                attachmentLoader: _expanded ? widget.attachmentLoader : null,
              ),
            ),
        ],
      ),
    );
  }
}

/// A small tinted label at the end of a tool row for the states that need a
/// glance: waiting for approval, denied, failed.
class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(left: 6, right: 2),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall
            ?.copyWith(color: color, fontSize: 10),
      ),
    );
  }
}

class _ToolCallContentList extends StatelessWidget {
  const _ToolCallContentList({
    super.key,
    required this.toolCall,
    required this.command,
    required this.approval,
    required this.inProgress,
    required this.attachmentLoader,
  });

  final ToolCall toolCall;

  /// The cleaned command, when the row above shows only the description.
  final String? command;
  final ToolApproval? approval;
  final bool inProgress;
  final Future<AttachmentData> Function(String attachmentId)? attachmentLoader;

  @override
  Widget build(BuildContext context) {
    final bool hasInput = _hasRawValue(toolCall.rawInput);
    final bool hasTypedOutput = toolCall.content.isNotEmpty;
    final bool hasRawOutput = _hasRawValue(toolCall.rawOutput);
    final ToolEditDiff? editDiff = extractEditDiffFromToolCall(toolCall);
    final ToolApproval? approval = this.approval;
    final String? command = this.command;
    final List<Widget> children = <Widget>[
      if (command != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
          child: Text(
            command,
            style: context.speedDialColors.mono.copyWith(
              fontSize: 11.5,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      if (approval != null) _ApprovalLine(approval: approval),
      if (editDiff != null)
        _EditDiffView(diff: editDiff, fallbackPaths: toolCall.locations),
      if (hasInput && editDiff == null)
        _RawToolDataView(label: 'Input', value: toolCall.rawInput!),
      if (hasTypedOutput) const _ToolDataLabel(label: 'Output'),
      for (final ToolCallContent content in toolCall.content)
        _ToolCallContentView(
          content: content,
          attachmentLoader: attachmentLoader,
        ),
      if (!hasTypedOutput && hasRawOutput && editDiff?.absorbsRawOutput != true)
        _RawToolDataView(label: 'Output', value: toolCall.rawOutput!),
      if (!hasTypedOutput && !hasRawOutput && editDiff == null)
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
          child: Text(
            inProgress ? 'Waiting for output…' : 'No output',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      if (toolCall.locations.isNotEmpty)
        _LocationChips(locations: toolCall.locations),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 2, 10, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );
  }
}

/// How the permission request for this call was answered, in the agent's
/// own words for the chosen option.
class _ApprovalLine extends StatelessWidget {
  const _ApprovalLine({required this.approval});

  final ToolApproval approval;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final SpeedDialColors colors = context.speedDialColors;
    final (
      IconData icon,
      Color color,
      String verdict,
    ) = switch (approval.state) {
      ToolApprovalState.pending => (
        Icons.shield_outlined,
        colors.waitingPermission,
        'Waiting for approval',
      ),
      ToolApprovalState.allowed => (
        Icons.verified_user_outlined,
        theme.colorScheme.onSurfaceVariant,
        'Approved',
      ),
      ToolApprovalState.denied => (
        Icons.gpp_bad_outlined,
        colors.error,
        'Denied',
      ),
      ToolApprovalState.lapsed => (
        Icons.shield_outlined,
        theme.colorScheme.onSurfaceVariant,
        'Not approved',
      ),
    };
    final String? choice = approval.choice;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              choice == null ? verdict : '$verdict · $choice',
              style: theme.textTheme.bodySmall?.copyWith(color: color),
            ),
          ),
        ],
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
          child: Text(_boundedToolText(text.text), style: colors.mono),
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
        return _DiffView(
          diff: ToolCallDiff(
            path: diff.path,
            oldText: diff.oldText == null
                ? null
                : _boundedToolText(diff.oldText!),
            newText: _boundedToolText(diff.newText),
          ),
        );
      case ToolCallPatch patch:
        return _PatchView(
          patch: ToolCallPatch(
            path: patch.path,
            diff: _boundedToolText(patch.diff),
          ),
        );
      case ToolCallTerminal terminal:
        return _ScrollableMono(
          background: colors.terminalBackground,
          child: Text(
            _boundedToolText(terminal.output),
            style: colors.mono.copyWith(color: colors.terminalForeground),
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
  final StringBuffer out = StringBuffer();
  _writeRawPreview(out, value, 0);
  return out.toString();
}

const int _maxToolPreviewCharacters = 12000;
const int _maxRawDepth = 6;
const int _maxRawEntries = 100;

void _writeRawPreview(StringBuffer out, Object? value, int depth) {
  if (out.length >= _maxToolPreviewCharacters) return;
  if (depth >= _maxRawDepth) {
    out.write('…');
    return;
  }
  switch (value) {
    case null || bool() || num():
      out.write(value);
    case String():
      out.write(jsonEncode(_boundedToolText(value)));
    case Map():
      out.write('{');
      int index = 0;
      for (final MapEntry<Object?, Object?> entry in value.entries) {
        if (index > 0) out.write(', ');
        if (index >= _maxRawEntries ||
            out.length >= _maxToolPreviewCharacters) {
          out.write('…');
          break;
        }
        out.write(jsonEncode(entry.key.toString()));
        out.write(': ');
        _writeRawPreview(out, entry.value, depth + 1);
        index++;
      }
      out.write('}');
    case Iterable():
      out.write('[');
      int index = 0;
      for (final Object? entry in value) {
        if (index > 0) out.write(', ');
        if (index >= _maxRawEntries ||
            out.length >= _maxToolPreviewCharacters) {
          out.write('…');
          break;
        }
        _writeRawPreview(out, entry, depth + 1);
        index++;
      }
      out.write(']');
    default:
      out.write(_boundedToolText(value.toString()));
  }
}

String _boundedToolText(String value) {
  if (value.length <= _maxToolPreviewCharacters) return value;
  final int omitted = value.length - _maxToolPreviewCharacters;
  return '${value.substring(0, _maxToolPreviewCharacters)}\n\n'
      '… $omitted characters omitted';
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

/// Renders a normalized edit diff: a dim line-number gutter, red deletions,
/// green additions, and purple header/omission markers.
class _EditDiffView extends StatelessWidget {
  const _EditDiffView({required this.diff, required this.fallbackPaths});

  final ToolEditDiff diff;
  final List<String> fallbackPaths;

  static String _gutter(int? value) =>
      value == null ? '    ' : value.toString().padLeft(4);

  @override
  Widget build(BuildContext context) {
    final SpeedDialColors colors = context.speedDialColors;
    final ThemeData theme = Theme.of(context);
    final Color neutral = theme.colorScheme.onSurfaceVariant;
    final String? path =
        diff.path ?? (fallbackPaths.length == 1 ? fallbackPaths.single : null);

    final List<InlineSpan> spans = <InlineSpan>[];
    if (path != null) {
      spans.add(
        TextSpan(
          text: '$path\n',
          style: colors.mono.copyWith(
            color: neutral,
            fontWeight: FontWeight.w600,
          ),
        ),
      );
    }
    spans.add(
      TextSpan(
        text: '+${diff.additions} -${diff.deletions}\n',
        style: colors.mono.copyWith(color: neutral, fontSize: 11),
      ),
    );
    for (final ToolEditLine line in diff.lines) {
      final int? num = line.sign == '-' ? line.oldNum : line.newNum;
      spans.add(
        TextSpan(
          text: _gutter(num),
          style: colors.mono.copyWith(color: neutral, fontSize: 11),
        ),
      );
      final bool omission = line.sign == ' ' && line.text.startsWith('…');
      final Color? color = line.isHeader
          ? colors.purple
          : omission
          ? null
          : switch (line.sign) {
              '+' => colors.success,
              '-' => colors.diffRemove,
              _ => null,
            };
      spans.add(
        TextSpan(
          text: line.isHeader
              ? '${line.text}\n'
              : '${line.sign} ${line.text}\n',
          style: color == null ? null : colors.mono.copyWith(color: color),
        ),
      );
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
