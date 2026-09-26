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
    this.focusNode,
    required this.status,
    required this.mode,
    this.commands = const <NativeCommand>[],
    this.onSlashStarted,
    this.usage,
    this.model,
    this.models = const <String>[],
    this.onModelChanged,
    this.thinkingLevel,
    this.thinkingLevels = const <String>[],
    this.onThinkingChanged,
    this.draft = '',
    this.onDraftChanged,
    this.attachmentPicker,
    this.clipboardImageReader,
    this.sharedAttachments = const <OutgoingAttachment>[],
    this.onRemoveSharedAttachment,
    this.onSharedAttachmentsSent,
    required this.onSend,
    required this.onStop,
    required this.onModeChanged,
  });

  /// Optional focus node owned by the shell so session creation can move
  /// keyboard focus into the newly mounted composer.
  final FocusNode? focusNode;

  /// Current session status; drives the send/stop switch.
  final SessionStatus status;

  /// Session mode driving the build/plan selector.
  final SessionMode mode;

  /// Native commands advertised by the active harness session.
  final List<NativeCommand> commands;
  final VoidCallback? onSlashStarted;

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

  /// Exact text saved for this session, restored when the composer mounts.
  final String draft;

  /// Persists exact composer text. During a send the previous draft remains
  /// saved until [onSend] succeeds, so closing the app while the request is
  /// in flight cannot discard it.
  final Future<void> Function(String text)? onDraftChanged;

  /// Injectable file picker for tests; defaults to [FilePicker.platform]
  /// with `withData: true` when null. Files whose bytes come back null are
  /// skipped.
  final AttachmentPicker? attachmentPicker;

  /// Injectable clipboard image reader for tests; defaults to
  /// [Pasteboard.image].
  final ClipboardImageReader? clipboardImageReader;

  /// Attachment staged from Android sharing for this session. Kept by the
  /// share store so it survives composer remounts and send failures.
  final List<OutgoingAttachment> sharedAttachments;
  final ValueChanged<OutgoingAttachment>? onRemoveSharedAttachment;
  final ValueChanged<List<OutgoingAttachment>>? onSharedAttachmentsSent;

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

class _MoveCommandIntent extends Intent {
  const _MoveCommandIntent(this.delta);
  final int delta;
}

class _DismissCommandIntent extends Intent {
  const _DismissCommandIntent();
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
  static final RegExp _commandWhitespace = RegExp(r'\s');

  late final TextEditingController _controller;
  final FocusNode _ownedFocusNode = FocusNode();
  late final _PasteImageAction _pasteImageAction;
  bool _hasText = false;
  bool _suppressDraftSave = false;
  bool _menuDismissed = false;
  late String _lastText;
  List<NativeCommand> _commandMatches = const <NativeCommand>[];
  int _activeCommand = 0;
  int _pastedImageCount = 0;

  /// Files picked but not yet sent; cleared on send, restored on failure.
  final List<OutgoingAttachment> _attachments = <OutgoingAttachment>[];

  bool get _running => widget.status == SessionStatus.running;

  /// Send is enabled with text, attachments, or both (PROTOCOL.md allows
  /// `sessions.send` with empty text when attachments are present).
  bool get _canSend =>
      _hasText ||
      _attachments.isNotEmpty ||
      widget.sharedAttachments.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.draft);
    _lastText = widget.draft;
    _hasText = widget.draft.trim().isNotEmpty;
    _pasteImageAction = _PasteImageAction(_pasteImage);
    _controller.addListener(_onTextChanged);
    _refilterCommands();
  }

  @override
  void didUpdateWidget(Composer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.commands, widget.commands)) {
      _refilterCommands();
    }
  }

  @override
  void dispose() {
    _controller
      ..removeListener(_onTextChanged)
      ..dispose();
    _ownedFocusNode.dispose();
    super.dispose();
  }

  void _onTextChanged() {
    final String previousText = _lastText;
    _lastText = _controller.text;
    final bool hasText = _controller.text.trim().isNotEmpty;
    final List<NativeCommand> oldMatches = _commandMatches;
    final bool wasShowing = _showCommandMenu;
    _menuDismissed = false;
    _refilterCommands();
    if (_controller.text == '/' && previousText != '/') {
      widget.onSlashStarted?.call();
    }
    if (hasText != _hasText ||
        wasShowing != _showCommandMenu ||
        !_sameCommands(oldMatches, _commandMatches)) {
      setState(() => _hasText = hasText);
    }
    final Future<void> Function(String text)? onDraftChanged =
        widget.onDraftChanged;
    if (!_suppressDraftSave && onDraftChanged != null) {
      unawaited(onDraftChanged(_controller.text));
    }
  }

  bool get _showCommandMenu =>
      !_menuDismissed && _commandMatches.isNotEmpty && !_running;

  static bool _sameCommands(List<NativeCommand> a, List<NativeCommand> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i].name != b[i].name) return false;
    }
    return true;
  }

  void _refilterCommands() {
    final String text = _controller.text;
    if (!text.startsWith('/') || text.contains(_commandWhitespace)) {
      _commandMatches = const <NativeCommand>[];
      _activeCommand = 0;
      return;
    }
    final String query = text.substring(1).toLowerCase();
    _commandMatches = <NativeCommand>[
      for (final NativeCommand command in widget.commands)
        if (command.name.toLowerCase().startsWith(query)) command,
    ];
    _activeCommand = 0;
  }

  void _selectCommand(NativeCommand command) {
    _menuDismissed = true;
    _controller.value = TextEditingValue(
      text: '/${command.name} ',
      selection: TextSelection.collapsed(offset: command.name.length + 2),
    );
    setState(() => _commandMatches = const <NativeCommand>[]);
    (widget.focusNode ?? _ownedFocusNode).requestFocus();
  }

  void _moveCommand(int delta) {
    if (!_showCommandMenu) return;
    setState(() {
      _activeCommand = (_activeCommand + delta).clamp(
        0,
        _commandMatches.length - 1,
      );
    });
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
    final List<OutgoingAttachment> shared = List<OutgoingAttachment>.of(
      widget.sharedAttachments,
    );
    attachments.addAll(shared);
    if ((text.isEmpty && attachments.isEmpty) || _running || !mounted) {
      return;
    }
    _suppressDraftSave = true;
    _controller.clear();
    _suppressDraftSave = false;
    setState(() {
      _hasText = false;
      _attachments.clear();
      _commandMatches = const <NativeCommand>[];
    });
    unawaited(_dispatch(text, attachments, shared));
  }

  void _submitFromKeyboard() {
    if (_showCommandMenu) {
      _selectCommand(_commandMatches[_activeCommand]);
      return;
    }
    _send();
  }

  /// Runs the send future; restores the draft (text into the field AND
  /// attachments into the chip row) when it fails so a rejected send (e.g.
  /// a conflict surfaced as a SnackBar by the pane) never loses the user's
  /// message.
  Future<void> _dispatch(
    String text,
    List<OutgoingAttachment> attachments,
    List<OutgoingAttachment> shared,
  ) async {
    try {
      await widget.onSend(text, attachments);
    } catch (_) {
      if (!mounted) return;
      _controller.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      );
      setState(
        () => _attachments.addAll(
          attachments.where((OutgoingAttachment a) => !shared.contains(a)),
        ),
      );
      return;
    }
    if (shared.isNotEmpty) widget.onSharedAttachmentsSent?.call(shared);
    final Future<void> Function(String text)? onDraftChanged =
        widget.onDraftChanged;
    if (onDraftChanged != null) {
      // Usually empty. If the user already started a following message while
      // the send was being accepted, preserve that newer text.
      await onDraftChanged(mounted ? _controller.text : '');
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
                if (_attachments.isNotEmpty ||
                    widget.sharedAttachments.isNotEmpty)
                  _AttachmentChips(
                    attachments: <OutgoingAttachment>[
                      ..._attachments,
                      ...widget.sharedAttachments,
                    ],
                    onRemove: (OutgoingAttachment attachment) {
                      if (widget.sharedAttachments.contains(attachment)) {
                        widget.onRemoveSharedAttachment?.call(attachment);
                      } else {
                        _removeAttachment(attachment);
                      }
                    },
                  ),
                if (_showCommandMenu)
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 224),
                    child: ListView.builder(
                      key: const Key('slash-command-menu'),
                      shrinkWrap: true,
                      itemCount: _commandMatches.length,
                      itemBuilder: (BuildContext context, int index) {
                        final NativeCommand command = _commandMatches[index];
                        return ListTile(
                          key: Key('slash-command-/${command.name}'),
                          dense: true,
                          selected: index == _activeCommand,
                          title: Text(
                            '/${command.name}${command.argumentHint == null ? '' : ' ${command.argumentHint}'}',
                          ),
                          subtitle: Text(command.description),
                          onTap: () => _selectCommand(command),
                        );
                      },
                    ),
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
                    if (_showCommandMenu) ...<ShortcutActivator, Intent>{
                      const SingleActivator(LogicalKeyboardKey.arrowDown):
                          const _MoveCommandIntent(1),
                      const SingleActivator(LogicalKeyboardKey.arrowUp):
                          const _MoveCommandIntent(-1),
                      const SingleActivator(LogicalKeyboardKey.escape):
                          const _DismissCommandIntent(),
                      const SingleActivator(LogicalKeyboardKey.tab):
                          const _SendMessageIntent(),
                    },
                  },
                  child: Actions(
                    actions: <Type, Action<Intent>>{
                      PasteTextIntent: _pasteImageAction,
                      _SendMessageIntent: CallbackAction<_SendMessageIntent>(
                        onInvoke: (_) {
                          _submitFromKeyboard();
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
                      _MoveCommandIntent: CallbackAction<_MoveCommandIntent>(
                        onInvoke: (_MoveCommandIntent intent) {
                          _moveCommand(intent.delta);
                          return null;
                        },
                      ),
                      _DismissCommandIntent:
                          CallbackAction<_DismissCommandIntent>(
                            onInvoke: (_) {
                              setState(() => _menuDismissed = true);
                              return null;
                            },
                          ),
                    },
                    child: TextField(
                      focusNode: widget.focusNode ?? _ownedFocusNode,
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
