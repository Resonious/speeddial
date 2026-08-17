import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';

import '../../theme.dart';

/// Multiline message composer: Enter sends, Shift+Enter inserts a newline,
/// send is disabled while empty, a stop button replaces send while the
/// session is running, plus mode/model controls and a usage footer.
class Composer extends StatefulWidget {
  const Composer({
    super.key,
    required this.status,
    required this.mode,
    this.usage,
    this.model,
    required this.onSend,
    required this.onStop,
    required this.onModeChanged,
  });

  /// Current session status; drives the send/stop switch.
  final SessionStatus status;

  /// Session mode driving the build/plan selector.
  final SessionMode mode;

  /// Latest turn usage, shown in the footer when non-null.
  final UsageInfo? usage;

  /// Model id label (static text) when the session has one.
  final String? model;

  /// Starts a turn with [text]. Completes when the daemon accepted it; on
  /// failure (a [DaemonError] surfaced as a SnackBar by the caller) the
  /// composer restores the text into the field so the draft is never lost.
  /// Returning a future is what lets the composer know the send outcome.
  final Future<void> Function(String text) onSend;
  final VoidCallback onStop;
  final ValueChanged<SessionMode> onModeChanged;

  @override
  State<Composer> createState() => _ComposerState();
}

class _SendMessageIntent extends Intent {
  const _SendMessageIntent();
}

class _InsertNewlineIntent extends Intent {
  const _InsertNewlineIntent();
}

class _ComposerState extends State<Composer> {
  final TextEditingController _controller = TextEditingController();
  bool _hasText = false;

  bool get _running => widget.status == SessionStatus.running;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onTextChanged);
  }

  @override
  void dispose() {
    _controller
      ..removeListener(_onTextChanged)
      ..dispose();
    super.dispose();
  }

  void _onTextChanged() {
    final bool hasText = _controller.text.trim().isNotEmpty;
    if (hasText != _hasText) {
      setState(() => _hasText = hasText);
    }
  }

  void _send() {
    final String text = _controller.text.trim();
    if (text.isEmpty || _running || !mounted) return;
    _controller.clear();
    setState(() => _hasText = false);
    unawaited(_dispatch(text));
  }

  /// Runs the send future; restores the draft into the field when it fails
  /// so a rejected send (e.g. a conflict surfaced as a SnackBar by the
  /// pane) never loses the user's message.
  Future<void> _dispatch(String text) async {
    try {
      await widget.onSend(text);
    } catch (_) {
      if (!mounted) return;
      _controller.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      );
      setState(() => _hasText = true);
    }
  }

  /// Inserts a newline at the cursor (Shift+Enter) without relying on the
  /// platform IME, so behavior is identical on every platform and in tests.
  void _insertNewline() {
    final TextEditingValue value = _controller.value;
    final int offset = value.selection.isValid
        ? value.selection.baseOffset
        : value.text.length;
    final int clamped = offset.clamp(0, value.text.length);
    _controller.value = TextEditingValue(
      text: value.text.replaceRange(clamped, clamped, '\n'),
      selection: TextSelection.collapsed(offset: clamped + 1),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return Material(
      color: scheme.surfaceContainerLow,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const Divider(height: 1),
          _ControlsRow(
            mode: widget.mode,
            model: widget.model,
            onModeChanged: widget.onModeChanged,
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 6),
            child: Shortcuts(
              shortcuts: <ShortcutActivator, Intent>{
                const SingleActivator(LogicalKeyboardKey.enter):
                    const _SendMessageIntent(),
                const SingleActivator(LogicalKeyboardKey.numpadEnter):
                    const _SendMessageIntent(),
                const SingleActivator(LogicalKeyboardKey.enter, shift: true):
                    const _InsertNewlineIntent(),
              },
              child: Actions(
                actions: <Type, Action<Intent>>{
                  _SendMessageIntent: CallbackAction<_SendMessageIntent>(
                    onInvoke: (_) {
                      _send();
                      return null;
                    },
                  ),
                  _InsertNewlineIntent: CallbackAction<_InsertNewlineIntent>(
                    onInvoke: (_) {
                      _insertNewline();
                      return null;
                    },
                  ),
                },
                child: TextField(
                  controller: _controller,
                  minLines: 1,
                  maxLines: 8,
                  keyboardType: TextInputType.multiline,
                  textInputAction: TextInputAction.newline,
                  decoration: InputDecoration(
                    hintText: 'Message the agent…',
                    suffixIcon: _running
                        ? IconButton(
                            tooltip: 'Stop',
                            icon: const Icon(Icons.stop_circle_outlined),
                            onPressed: widget.onStop,
                          )
                        : IconButton(
                            tooltip: 'Send',
                            icon: const Icon(Icons.send),
                            onPressed: _hasText ? _send : null,
                          ),
                  ),
                ),
              ),
            ),
          ),
          if (widget.usage != null) _UsageFooter(usage: widget.usage!),
        ],
      ),
    );
  }
}

class _ControlsRow extends StatelessWidget {
  const _ControlsRow({
    required this.mode,
    required this.model,
    required this.onModeChanged,
  });

  final SessionMode mode;
  final String? model;
  final ValueChanged<SessionMode> onModeChanged;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color muted = theme.colorScheme.onSurfaceVariant;

    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 2),
      child: Row(
        children: <Widget>[
          SegmentedButton<SessionMode>(
            showSelectedIcon: false,
            style: ButtonStyle(
              visualDensity: VisualDensity.compact,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              textStyle: WidgetStatePropertyAll<TextStyle?>(
                theme.textTheme.labelMedium,
              ),
            ),
            segments: const <ButtonSegment<SessionMode>>[
              ButtonSegment<SessionMode>(
                value: SessionMode.build,
                label: Text('Build'),
              ),
              ButtonSegment<SessionMode>(
                value: SessionMode.plan,
                label: Text('Plan'),
              ),
            ],
            selected: <SessionMode>{mode},
            onSelectionChanged: (Set<SessionMode> selection) {
              onModeChanged(selection.first);
            },
          ),
          const SizedBox(width: 10),
          if (model != null)
            Flexible(
              child: Text(
                model!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style:
                    context.speedDialColors.mono.copyWith(fontSize: 11, color: muted),
              ),
            ),
        ],
      ),
    );
  }
}

class _UsageFooter extends StatelessWidget {
  const _UsageFooter({required this.usage});

  final UsageInfo usage;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color muted = theme.colorScheme.onSurfaceVariant;
    final String cost = usage.cost == null ? '' : ' · \$${usage.cost}';
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
      child: Text(
        '${usage.totalTokens} tokens$cost',
        style: theme.textTheme.labelSmall?.copyWith(color: muted),
      ),
    );
  }
}
