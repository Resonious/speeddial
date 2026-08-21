import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pasteboard/pasteboard.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';

import '../../theme.dart';
import 'model_picker.dart';

/// Picks files for attachment. The record carries the file name and raw
/// bytes; the composer turns them into base64 [OutgoingAttachment]s.
typedef AttachmentPicker =
    Future<List<({String name, Uint8List bytes})>> Function();

typedef ClipboardImageReader = Future<Uint8List?> Function();

({String extension, String mimeType}) _imageFormat(
  Uint8List bytes, {
  String? fallbackMimeType,
}) {
  bool startsWith(List<int> signature) {
    if (bytes.length < signature.length) return false;
    for (int i = 0; i < signature.length; i++) {
      if (bytes[i] != signature[i]) return false;
    }
    return true;
  }

  if (startsWith(const <int>[0x89, 0x50, 0x4e, 0x47])) {
    return (extension: 'png', mimeType: 'image/png');
  }
  if (startsWith(const <int>[0xff, 0xd8, 0xff])) {
    return (extension: 'jpg', mimeType: 'image/jpeg');
  }
  if (startsWith(const <int>[0x47, 0x49, 0x46, 0x38])) {
    return (extension: 'gif', mimeType: 'image/gif');
  }
  if (startsWith(const <int>[0x42, 0x4d])) {
    return (extension: 'bmp', mimeType: 'image/bmp');
  }
  if (bytes.length >= 12 &&
      startsWith(const <int>[0x52, 0x49, 0x46, 0x46]) &&
      bytes[8] == 0x57 &&
      bytes[9] == 0x45 &&
      bytes[10] == 0x42 &&
      bytes[11] == 0x50) {
    return (extension: 'webp', mimeType: 'image/webp');
  }
  if (startsWith(const <int>[0x49, 0x49, 0x2a, 0x00]) ||
      startsWith(const <int>[0x4d, 0x4d, 0x00, 0x2a])) {
    return (extension: 'tiff', mimeType: 'image/tiff');
  }
  return switch (fallbackMimeType?.toLowerCase()) {
    'image/jpeg' || 'image/jpg' => (extension: 'jpg', mimeType: 'image/jpeg'),
    'image/gif' => (extension: 'gif', mimeType: 'image/gif'),
    'image/bmp' => (extension: 'bmp', mimeType: 'image/bmp'),
    'image/webp' => (extension: 'webp', mimeType: 'image/webp'),
    'image/tiff' => (extension: 'tiff', mimeType: 'image/tiff'),
    _ => (extension: 'png', mimeType: 'image/png'),
  };
}

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
    this.models = const <String>[],
    this.onModelChanged,
    this.thinkingLevel,
    this.thinkingLevels = const <String>[],
    this.onThinkingChanged,
    this.attachmentPicker,
    this.clipboardImageReader,
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

  /// Current model id: the picker's highlight when contained in [models],
  /// otherwise shown as static text (or as the picker button's label).
  final String? model;

  /// Selectable model ids advertised by the agent (ACP config option);
  /// empty when the provider has no model option.
  final List<String> models;

  /// Fires with the newly selected model id. When non-null (and [models] is
  /// non-empty) a searchable selector renders in place of the static model
  /// text.
  final ValueChanged<String>? onModelChanged;

  /// Current thinking level; shown only when [thinkingLevels] is non-empty.
  final String? thinkingLevel;

  /// Advertised thinking levels; when non-empty (and [onThinkingChanged] is
  /// given) a selector renders between the mode control and the model label.
  final List<String> thinkingLevels;

  /// Fires with the newly selected thinking level.
  final ValueChanged<String>? onThinkingChanged;

  /// Injectable file picker for tests; defaults to [FilePicker.platform]
  /// with `withData: true` when null. Files whose bytes come back null are
  /// skipped.
  final AttachmentPicker? attachmentPicker;

  /// Injectable clipboard image reader for tests; defaults to
  /// [Pasteboard.image].
  final ClipboardImageReader? clipboardImageReader;

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

class _PasteImageAction extends Action<PasteTextIntent> {
  _PasteImageAction(this.onPaste);

  final Future<bool> Function() onPaste;

  @override
  Object? invoke(PasteTextIntent intent) {
    final Action<PasteTextIntent>? fallback = callingAction;
    unawaited(_invoke(intent, fallback));
    return null;
  }

  Future<void> _invoke(
    PasteTextIntent intent,
    Action<PasteTextIntent>? fallback,
  ) async {
    if (!await onPaste()) {
      fallback?.invoke(intent);
    }
  }

  @override
  bool get isActionEnabled => callingAction?.isActionEnabled ?? false;

  @override
  bool consumesKey(PasteTextIntent intent) =>
      callingAction?.consumesKey(intent) ?? false;
}

class _ComposerState extends State<Composer> {
  final TextEditingController _controller = TextEditingController();
  late final _PasteImageAction _pasteImageAction;
  bool _hasText = false;
  int _pastedImageCount = 0;

  /// Files picked but not yet sent; cleared on send, restored on failure.
  final List<OutgoingAttachment> _attachments = <OutgoingAttachment>[];

  bool get _running => widget.status == SessionStatus.running;

  /// Send is enabled with text, attachments, or both (PROTOCOL.md allows
  /// `sessions.send` with empty text when attachments are present).
  bool get _canSend => _hasText || _attachments.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _pasteImageAction = _PasteImageAction(_pasteImage);
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
    final FilePickerResult? result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      withData: true,
    );
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

  Future<bool> _pasteImage() async {
    if (_running) return false;
    final ClipboardImageReader reader =
        widget.clipboardImageReader ?? (() => Pasteboard.image);
    final Uint8List? bytes;
    try {
      bytes = await reader();
    } on Object {
      return false;
    }
    if (!mounted || bytes == null || bytes.isEmpty) return false;
    final Uint8List imageBytes = bytes;
    final ({String extension, String mimeType}) format = _imageFormat(
      imageBytes,
    );
    setState(() {
      _pastedImageCount += 1;
      _attachments.add(
        OutgoingAttachment(
          name: _pastedImageCount == 1
              ? 'pasted-image.${format.extension}'
              : 'pasted-image-$_pastedImageCount.${format.extension}',
          mimeType: format.mimeType,
          data: base64Encode(imageBytes),
        ),
      );
    });
    return true;
  }

  void _onContentInserted(KeyboardInsertedContent content) {
    final Uint8List? bytes = content.data;
    if (_running ||
        !isImageMimeType(content.mimeType) ||
        bytes == null ||
        bytes.isEmpty) {
      return;
    }
    final ({String extension, String mimeType}) format = _imageFormat(
      bytes,
      fallbackMimeType: content.mimeType,
    );
    setState(() {
      _pastedImageCount += 1;
      _attachments.add(
        OutgoingAttachment(
          name: _pastedImageCount == 1
              ? 'pasted-image.${format.extension}'
              : 'pasted-image-$_pastedImageCount.${format.extension}',
          mimeType: format.mimeType,
          data: base64Encode(bytes),
        ),
      );
    });
  }

  Widget _buildContextMenu(
    BuildContext context,
    EditableTextState editableTextState,
  ) {
    final List<ContextMenuButtonItem> items = <ContextMenuButtonItem>[
      for (final ContextMenuButtonItem item
          in editableTextState.contextMenuButtonItems)
        if (item.type == ContextMenuButtonType.paste)
          item.copyWith(
            onPressed: () {
              editableTextState.hideToolbar();
              unawaited(_pasteFromToolbar(editableTextState));
            },
          )
        else
          item,
    ];
    return AdaptiveTextSelectionToolbar.buttonItems(
      anchors: editableTextState.contextMenuAnchors,
      buttonItems: items,
    );
  }

  Future<void> _pasteFromToolbar(EditableTextState editableTextState) async {
    if (!await _pasteImage()) {
      await editableTextState.pasteText(SelectionChangedCause.toolbar);
    }
  }

  void _removeAttachment(OutgoingAttachment attachment) {
    setState(() => _attachments.remove(attachment));
  }

  void _send() {
    final String text = _controller.text.trim();
    final List<OutgoingAttachment> attachments = List<OutgoingAttachment>.of(
      _attachments,
    );
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
            models: widget.models,
            onModelChanged: widget.onModelChanged,
            thinkingLevel: widget.thinkingLevel,
            thinkingLevels: widget.thinkingLevels,
            onThinkingChanged: widget.onThinkingChanged,
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
                    const SingleActivator(
                      LogicalKeyboardKey.enter,
                      shift: true,
                    ): const _InsertNewlineIntent(),
                  },
                  child: Actions(
                    actions: <Type, Action<Intent>>{
                      PasteTextIntent: _pasteImageAction,
                      _SendMessageIntent: CallbackAction<_SendMessageIntent>(
                        onInvoke: (_) {
                          _send();
                          return null;
                        },
                      ),
                      _InsertNewlineIntent:
                          CallbackAction<_InsertNewlineIntent>(
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
                      contentInsertionConfiguration:
                          ContentInsertionConfiguration(
                            onContentInserted: _onContentInserted,
                          ),
                      contextMenuBuilder: _buildContextMenu,
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
    required this.models,
    required this.onModelChanged,
    required this.thinkingLevel,
    required this.thinkingLevels,
    required this.onThinkingChanged,
    required this.onModeChanged,
  });

  final SessionMode mode;
  final String? model;
  final List<String> models;
  final ValueChanged<String>? onModelChanged;
  final String? thinkingLevel;
  final List<String> thinkingLevels;
  final ValueChanged<String>? onThinkingChanged;
  final ValueChanged<SessionMode> onModeChanged;

  /// "auto" → "Auto"; any advertised level is labeled capitalized here.
  String _label(String level) =>
      level.isEmpty ? level : level[0].toUpperCase() + level.substring(1);

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color muted = theme.colorScheme.onSurfaceVariant;
    final ValueChanged<String>? onThinking = onThinkingChanged;
    final ValueChanged<String>? onModel = onModelChanged;

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
          if (thinkingLevels.isNotEmpty && onThinking != null) ...<Widget>[
            Tooltip(
              message: 'Thinking level',
              child: DropdownButton<String>(
                value: thinkingLevels.contains(thinkingLevel)
                    ? thinkingLevel
                    : null,
                hint: const Text('Thinking'),
                underline: const SizedBox.shrink(),
                isDense: true,
                iconSize: 16,
                style: context.speedDialColors.mono.copyWith(
                  fontSize: 11,
                  color: muted,
                ),
                items: <DropdownMenuItem<String>>[
                  for (final String level in thinkingLevels)
                    DropdownMenuItem<String>(
                      value: level,
                      child: Text(_label(level)),
                    ),
                ],
                onChanged: (String? value) {
                  if (value != null) onThinking(value);
                },
              ),
            ),
            const SizedBox(width: 10),
          ],
          if (models.isNotEmpty && onModel != null)
            Flexible(
              // Raw model ids as labels: they are the agent's config values,
              // not display names. IntrinsicWidth keeps the button compact
              // (its natural width) yet lets it shrink to the row's remaining
              // space, where the Flexible label ellipsizes instead of
              // overflowing the row. The picker itself is searchable —
              // openrouter-scale model lists don't fit a flat dropdown menu.
              child: Tooltip(
                message: 'Model',
                child: IntrinsicWidth(
                  child: ModelPickerButton(
                    models: models,
                    model: model,
                    onChanged: onModel,
                  ),
                ),
              ),
            )
          else if (model != null)
            Flexible(
              child: Text(
                model!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.speedDialColors.mono.copyWith(
                  fontSize: 11,
                  color: muted,
                ),
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
    final List<String> parts = <String>[
      '${usage.totalTokens} tokens '
          '(${usage.inputTokens} in / ${usage.outputTokens} out)',
    ];
    final int? contextUsed = usage.contextUsedTokens;
    final int? contextLimit = usage.contextLimitTokens;
    if (contextUsed != null && contextLimit != null && contextLimit > 0) {
      final String percent = (contextUsed * 100 / contextLimit).toStringAsFixed(
        1,
      );
      parts.add('$contextUsed / $contextLimit context ($percent%)');
    }
    final int cache =
        (usage.cacheReadTokens ?? 0) + (usage.cacheCreationTokens ?? 0);
    if (cache > 0) parts.add('$cache cached');
    if (usage.cost != null) parts.add('\$${usage.cost}');
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
      child: Text(
        parts.join(' · '),
        style: theme.textTheme.labelSmall?.copyWith(color: muted),
      ),
    );
  }
}

/// Horizontally scrollable row of pending-attachment chips, shown above the
/// text field while files are staged for the next send.
class _AttachmentChips extends StatelessWidget {
  const _AttachmentChips({required this.attachments, required this.onRemove});

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
  const _AttachmentChip({required this.attachment, required this.onRemove});

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
              errorBuilder:
                  (
                    BuildContext context,
                    Object error,
                    StackTrace? stackTrace,
                  ) => Icon(
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
