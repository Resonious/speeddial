import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';

import '../../theme.dart';

/// Picks files for attachment. The record carries the file name and raw
/// bytes; the composer turns them into base64 [OutgoingAttachment]s.
typedef AttachmentPicker = Future<List<({String name, Uint8List bytes})>>
    Function();

/// Multiline message composer: Enter sends, Shift+Enter inserts a newline,
/// send is disabled while empty, a stop button replaces send while the
/// session is running, plus mode/model controls, a file-attach button, a
/// pending-attachment chip row and a usage footer.
class Composer extends StatefulWidget {
  const Composer({
    super.key,
    required this.status,
    required this.mode,
    this.usage,
    this.model,
    this.attachmentPicker,
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

  /// Injectable file picker for tests; defaults to [FilePicker.platform]
  /// with `withData: true` when null. Files whose bytes come back null are
  /// skipped.
  final AttachmentPicker? attachmentPicker;

  /// Starts a turn with [text] and [attachments]. Completes when the daemon
  /// accepted it; on failure (a [DaemonError] surfaced as a SnackBar by the
  /// caller) the composer restores BOTH the text into the field and the
  /// attachments into the chip row so the draft is never lost. Returning a
  /// future is what lets the composer know the send outcome.
  final Future<void> Function(String text, List<OutgoingAttachment> attachments)
      onSend;
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

  /// Files picked but not yet sent; cleared on send, restored on failure.
  final List<OutgoingAttachment> _attachments = <OutgoingAttachment>[];

  bool get _running => widget.status == SessionStatus.running;

  /// Send is enabled with text, attachments, or both (PROTOCOL.md allows
  /// `sessions.send` with empty text when attachments are present).
  bool get _canSend => _hasText || _attachments.isNotEmpty;

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

  /// Default file picker: multi-select with bytes on every desktop, mobile
  /// and web platform (file_picker returns null on cancel).
  static Future<List<({String name, Uint8List bytes})>>
      _defaultAttachmentPicker() async {
    final FilePickerResult? result =
        await FilePicker.platform.pickFiles(allowMultiple: true, withData: true);
    if (result == null) return const <({String name, Uint8List bytes})>[];
    return <({String name, Uint8List bytes})>[
      for (final PlatformFile file in result.files)
        if (file.bytes != null) (name: file.name, bytes: file.bytes!),
    ];
  }

  Future<void> _pickFiles() async {
    final AttachmentPicker picker =
        widget.attachmentPicker ?? _defaultAttachmentPicker;
    final List<({String name, Uint8List bytes})> picked;
    try {
      picked = await picker();
    } on Object {
      // Picker cancelled or failed; leave the draft untouched.
      return;
    }
    if (!mounted || picked.isEmpty) return;
    setState(() {
      _attachments.addAll(<OutgoingAttachment>[
        for (final ({String name, Uint8List bytes}) file in picked)
          OutgoingAttachment(
            name: file.name,
            mimeType: mimeTypeForFileName(file.name),
            data: base64Encode(file.bytes),
          ),
      ]);
    });
  }

  void _removeAttachment(OutgoingAttachment attachment) {
    setState(() => _attachments.remove(attachment));
  }

  void _send() {
    final String text = _controller.text.trim();
    final List<OutgoingAttachment> attachments =
        List<OutgoingAttachment>.of(_attachments);
    if ((text.isEmpty && attachments.isEmpty) || _running || !mounted) {
      return;
    }
    _controller.clear();
    setState(() {
      _hasText = false;
      _attachments.clear();
    });
    unawaited(_dispatch(text, attachments));
  }

  /// Runs the send future; restores the draft (text into the field AND
  /// attachments into the chip row) when it fails so a rejected send (e.g.
  /// a conflict surfaced as a SnackBar by the pane) never loses the user's
  /// message.
  Future<void> _dispatch(
    String text,
    List<OutgoingAttachment> attachments,
  ) async {
    try {
      await widget.onSend(text, attachments);
    } catch (_) {
      if (!mounted) return;
      _controller.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      );
      setState(() => _attachments.addAll(attachments));
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
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                if (_attachments.isNotEmpty)
                  _AttachmentChips(
                    attachments: List<OutgoingAttachment>.of(_attachments),
                    onRemove: _removeAttachment,
                  ),
                Shortcuts(
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
                        prefixIcon: IconButton(
                          tooltip: 'Attach files',
                          icon: const Icon(Icons.attach_file),
                          // Keep the draft stable while a turn is running;
                          // sending is disabled then too.
                          onPressed: _running ? null : _pickFiles,
                        ),
                        suffixIcon: _running
                            ? IconButton(
                                tooltip: 'Stop',
                                icon: const Icon(Icons.stop_circle_outlined),
                                onPressed: widget.onStop,
                              )
                            : IconButton(
                                tooltip: 'Send',
                                icon: const Icon(Icons.send),
                                onPressed: _canSend ? _send : null,
                              ),
                      ),
                    ),
                  ),
                ),
              ],
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

/// Horizontally scrollable row of pending-attachment chips, shown above the
/// text field while files are staged for the next send.
class _AttachmentChips extends StatelessWidget {
  const _AttachmentChips({
    required this.attachments,
    required this.onRemove,
  });

  final List<OutgoingAttachment> attachments;
  final ValueChanged<OutgoingAttachment> onRemove;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: <Widget>[
          for (final OutgoingAttachment attachment in attachments)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: _AttachmentChip(
                attachment: attachment,
                onRemove: onRemove,
              ),
            ),
        ],
      ),
    );
  }
}

/// One pending attachment: an image thumbnail (or a file icon plus name) and
/// a remove affordance.
class _AttachmentChip extends StatelessWidget {
  const _AttachmentChip({
    required this.attachment,
    required this.onRemove,
  });

  final OutgoingAttachment attachment;
  final ValueChanged<OutgoingAttachment> onRemove;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool image = isImageMimeType(attachment.mimeType);
    final Widget leading = image
        ? ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: Image.memory(
              base64Decode(attachment.data),
              width: 40,
              height: 40,
              fit: BoxFit.cover,
              gaplessPlayback: true,
              errorBuilder: (BuildContext context, Object error,
                      StackTrace? stackTrace) =>
                  Icon(
                Icons.broken_image_outlined,
                size: 20,
                color: scheme.onSurfaceVariant,
              ),
            ),
          )
        : Icon(
            Icons.insert_drive_file_outlined,
            size: 18,
            color: scheme.onSurfaceVariant,
          );
    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      padding: const EdgeInsets.only(left: 4, right: 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          leading,
          if (image) const SizedBox(width: 4),
          if (!image) ...<Widget>[
            const SizedBox(width: 6),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 160),
              child: Text(
                attachment.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelMedium,
              ),
            ),
            const SizedBox(width: 4),
          ],
          IconButton(
            tooltip: 'Remove',
            visualDensity: VisualDensity.compact,
            iconSize: 16,
            icon: const Icon(Icons.close),
            onPressed: () => onRemove(attachment),
          ),
        ],
      ),
    );
  }
}
