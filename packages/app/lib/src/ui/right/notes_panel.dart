import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';

import '../../scope.dart';
import '../../state/notes_store.dart';
import '../daemon_error_text.dart';
import '../toast.dart';
import 'note_check.dart';

/// How long a note checked off in the open list stays put, struck through,
/// before it folds away; long enough to see the check land and to undo.
const Duration kNoteLinger = Duration(milliseconds: 700);

/// How long a note row takes to fold open or closed.
const Duration kNoteFold = Duration(milliseconds: 240);

/// The right-hand pane: every open (unchecked) note across all daemons and
/// projects, grouped by session, with the selected session's group first.
/// The selected session also gets a field for new notes and, collapsed, the
/// notes it has already checked off.
class NotesPanel extends StatefulWidget {
  const NotesPanel({super.key});

  @override
  State<NotesPanel> createState() => _NotesPanelState();
}

typedef _Linger = ({String daemonId, String sessionId, bool leaving});

class _NotesPanelState extends State<NotesPanel> {
  final Set<String> _sessionsRequested = <String>{};
  final Set<String> _projectsRequested = <String>{};

  /// `daemonId/noteId` → notes just checked off here, still shown in the
  /// open list until their linger and fold finish.
  final Map<String, _Linger> _lingering = <String, _Linger>{};
  final Map<String, Timer> _lingerTimers = <String, Timer>{};

  /// Sessions (`daemonId/sessionId`) whose checked-off notes are expanded.
  final Set<String> _showDone = <String>{};

  /// Notes known at the previous build, by `daemonId/noteId`, and the
  /// daemons that had loaded then: only notes that arrive later fold in.
  Set<String> _seen = <String>{};
  Set<String> _loadedDaemons = <String>{};

  @override
  void dispose() {
    for (final Timer timer in _lingerTimers.values) {
      timer.cancel();
    }
    super.dispose();
  }

  static String _key(String daemonId, String id) => '$daemonId/$id';

  Future<void> _setDone(
    AppData data,
    String daemonId,
    SessionNote note,
    bool done,
  ) async {
    final String key = _key(daemonId, note.id);
    _lingerTimers.remove(key)?.cancel();
    if (_lingering.remove(key) != null) setState(() {});
    if (done && !MediaQuery.of(context).disableAnimations) {
      setState(() {
        _lingering[key] = (
          daemonId: daemonId,
          sessionId: note.sessionId,
          leaving: false,
        );
      });
      _lingerTimers[key] = Timer(kNoteLinger, () {
        if (!mounted) return;
        setState(() {
          _lingering[key] = (
            daemonId: daemonId,
            sessionId: note.sessionId,
            leaving: true,
          );
        });
        _lingerTimers[key] = Timer(kNoteFold, () {
          if (!mounted) return;
          _lingerTimers.remove(key);
          setState(() => _lingering.remove(key));
        });
      });
    }
    try {
      await data.notes.setDone(daemonId, note.id, done);
    } catch (error) {
      _lingerTimers.remove(key)?.cancel();
      if (mounted) setState(() => _lingering.remove(key));
      _toast(
        done ? 'Could not check off the note' : 'Could not reopen the note',
        error,
      );
    }
  }

  Future<void> _edit(
    AppData data,
    String daemonId,
    SessionNote note,
    String text,
  ) async {
    final String trimmed = text.trim();
    if (trimmed == note.text) return;
    if (trimmed.isEmpty) return _delete(data, daemonId, note);
    try {
      await data.notes.edit(daemonId, note.id, trimmed);
    } catch (error) {
      _toast('Could not save the note', error);
    }
  }

  Future<void> _delete(AppData data, String daemonId, SessionNote note) async {
    try {
      await data.notes.remove(daemonId, note.id);
    } catch (error) {
      _toast('Could not delete the note', error);
    }
  }

  Future<bool> _add(
    AppData data,
    String daemonId,
    String sessionId,
    String text,
  ) async {
    try {
      await data.notes.add(daemonId, sessionId, text);
      return true;
    } catch (error) {
      _toast('Could not add the note', error);
      return false;
    }
  }

  void _toast(String action, Object error) {
    if (!mounted) return;
    final String detail = error is DaemonConnectionError
        ? kConnectionLostMessage
        : error is DaemonError
        ? error.message
        : '$error';
    showToast(context, '$action: $detail', tone: ToastTone.error);
  }

  void _open(AppData data, String daemonId, String projectId, String id) {
    data.selection.selectSession(
      daemonId: daemonId,
      projectId: projectId,
      sessionId: id,
    );
    // On narrow layouts the panel is a bottom sheet over the chat.
    if (ModalRoute.of(context) is ModalBottomSheetRoute) {
      Navigator.of(context).pop();
    }
  }

  /// Notes name their sessions; make sure the stores can say what those
  /// are. The stores notify as they start loading, so this waits for the
  /// frame to finish building.
  void _requestNames(AppData data, String daemonId, Session? session) {
    final bool sessions = session == null && _sessionsRequested.add(daemonId);
    final bool projects =
        !data.projects.hasLoaded(daemonId) && _projectsRequested.add(daemonId);
    if (!sessions && !projects) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (sessions) {
        unawaited(
          data.sessions.refresh(daemonId).then((_) {}, onError: (Object _) {}),
        );
      }
      if (projects) {
        unawaited(
          data.projects.refresh(daemonId).then((_) {}, onError: (Object _) {}),
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final AppData data = AppScope.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[
        data.notes,
        data.sessions,
        data.projects,
        data.selection,
        data.connections,
      ]),
      builder: (BuildContext context, Widget? _) => _panel(context, data),
    );
  }

  Widget _panel(BuildContext context, AppData data) {
    final List<DaemonEndpoint> endpoints = data.connections.endpoints;
    for (final DaemonEndpoint endpoint in endpoints) {
      data.notes.ensureLoaded(endpoint.id);
    }
    final String? selectedDaemon = data.selection.selectedDaemonId;
    final String? selectedSession = data.selection.selectedSessionId;
    final DaemonSessionKey? selected =
        selectedDaemon == null || selectedSession == null
        ? null
        : (daemonId: selectedDaemon, sessionId: selectedSession);
    if (selected != null) data.notes.ensureLoaded(selected.daemonId);

    // Which notes fold in: those that arrived since the last build on a
    // daemon that had already loaded.
    final Set<String> seen = <String>{};
    final Set<String> loaded = <String>{};
    final Set<String> arriving = <String>{};
    final Set<String> daemonIds = <String>{
      for (final DaemonEndpoint endpoint in endpoints) endpoint.id,
      ?selected?.daemonId,
    };
    for (final String daemonId in daemonIds) {
      if (!data.notes.hasLoaded(daemonId)) continue;
      loaded.add(daemonId);
      for (final SessionNote note in data.notes.notesOn(daemonId)) {
        final String key = _key(daemonId, note.id);
        seen.add(key);
        if (_loadedDaemons.contains(daemonId) && !_seen.contains(key)) {
          arriving.add(key);
        }
      }
    }
    _seen = seen;
    _loadedDaemons = loaded;

    final Set<DaemonSessionKey> others = <DaemonSessionKey>{
      ...data.notes.sessionsWithOpenNotes(),
      for (final _Linger linger in _lingering.values)
        (daemonId: linger.daemonId, sessionId: linger.sessionId),
    };
    others.remove(selected);
    final List<DaemonSessionKey> ordered = others.toList()
      ..sort((DaemonSessionKey a, DaemonSessionKey b) {
        final Session? sa = data.sessions.sessionOnDaemon(
          a.daemonId,
          a.sessionId,
        );
        final Session? sb = data.sessions.sessionOnDaemon(
          b.daemonId,
          b.sessionId,
        );
        if (sa != null && sb != null) {
          final int byActivity = sb.lastActivityAt.compareTo(sa.lastActivityAt);
          if (byActivity != 0) return byActivity;
        } else if (sa != null || sb != null) {
          return sa != null ? -1 : 1;
        }
        return _key(
          a.daemonId,
          a.sessionId,
        ).compareTo(_key(b.daemonId, b.sessionId));
      });

    final bool manyDaemons = daemonIds.length > 1;
    final List<Widget> groups = <Widget>[];
    for (final DaemonSessionKey key in <DaemonSessionKey>[
      ?selected,
      ...ordered,
    ]) {
      final bool isSelected = key == selected;
      final List<SessionNote> notes = data.notes.notesFor(
        key.daemonId,
        key.sessionId,
      );
      if (notes.isEmpty && !isSelected) continue;
      final Session? session = data.sessions.sessionOnDaemon(
        key.daemonId,
        key.sessionId,
      );
      _requestNames(data, key.daemonId, session);
      final String? projectId =
          session?.projectId ?? notes.firstOrNull?.projectId;
      String? projectName;
      if (projectId != null) {
        for (final Project project in data.projects.projectsFor(key.daemonId)) {
          if (project.id == projectId) projectName = project.name;
        }
      }
      String? daemonName;
      if (manyDaemons) {
        for (final DaemonEndpoint endpoint in endpoints) {
          if (endpoint.id == key.daemonId) daemonName = endpoint.name;
        }
      }
      final List<SessionNote> open = <SessionNote>[];
      final List<SessionNote> done = <SessionNote>[];
      for (final SessionNote note in notes) {
        if (!note.done || _lingering.containsKey(_key(key.daemonId, note.id))) {
          open.add(note);
        } else {
          done.add(note);
        }
      }
      final bool leaving =
          !isSelected &&
          open.every(
            (SessionNote note) =>
                _lingering[_key(key.daemonId, note.id)]?.leaving ?? false,
          );
      final String groupKey = _key(key.daemonId, key.sessionId);
      groups.add(
        NoteFold(
          key: ValueKey<String>('notes-group-$groupKey'),
          visible: !leaving,
          appear: false,
          child: _SessionNotesGroup(
            daemonId: key.daemonId,
            sessionId: key.sessionId,
            session: session,
            projectName: projectName,
            daemonName: daemonName,
            selected: isSelected,
            open: open,
            done: isSelected ? done : const <SessionNote>[],
            showDone: _showDone.contains(groupKey),
            lingering: _lingering,
            arriving: arriving,
            onToggleDone: () => setState(() {
              if (!_showDone.remove(groupKey)) _showDone.add(groupKey);
            }),
            onOpen: projectId == null
                ? null
                : () => _open(data, key.daemonId, projectId, key.sessionId),
            onSetDone: (SessionNote note, bool value) =>
                _setDone(data, key.daemonId, note, value),
            onEdit: (SessionNote note, String text) =>
                _edit(data, key.daemonId, note, text),
            onDelete: (SessionNote note) => _delete(data, key.daemonId, note),
            onAdd: (String text) =>
                _add(data, key.daemonId, key.sessionId, text),
          ),
        ),
      );
    }

    final List<Widget> problems = <Widget>[
      for (final String daemonId in daemonIds)
        if (data.notes.errorFor(daemonId) != null &&
            !data.notes.isLoading(daemonId))
          _LoadProblem(
            message: manyDaemons
                ? 'Could not load notes from '
                      '${endpoints.where((DaemonEndpoint e) => e.id == daemonId).firstOrNull?.name ?? daemonId}'
                : 'Could not load notes',
            onRetry: () => unawaited(
              data.notes.refresh(daemonId).then((_) {}, onError: (Object _) {}),
            ),
          ),
    ];
    final bool empty = groups.isEmpty;

    // Bottom-only: the panel's content must clear the system navigation
    // area on edge-to-edge Android. The narrow layout's bottom sheet already
    // applies a SafeArea, so this is a no-op there.
    return SafeArea(
      top: false,
      left: false,
      right: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _NotesHeader(openCount: data.notes.openCount),
          ...problems,
          Expanded(
            child: empty
                ? const _EmptyNotes()
                : ListView(
                    padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
                    children: groups,
                  ),
          ),
        ],
      ),
    );
  }
}

class _NotesHeader extends StatelessWidget {
  const _NotesHeader({required this.openCount});

  final int openCount;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Row(
        children: <Widget>[
          Text(
            'Notes',
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const Spacer(),
          if (openCount > 0)
            Text(
              '$openCount open',
              key: const Key('notes-open-count'),
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
        ],
      ),
    );
  }
}

class _EmptyNotes extends StatelessWidget {
  const _EmptyNotes();

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color muted = theme.colorScheme.onSurfaceVariant;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.checklist_rounded, size: 32, color: muted),
            const SizedBox(height: 12),
            Text('No open notes', style: theme.textTheme.titleSmall),
            const SizedBox(height: 6),
            Text(
              'Select a session to give it a to-do list. Sessions with '
              'open notes are never archived automatically.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(color: muted),
            ),
          ],
        ),
      ),
    );
  }
}

class _LoadProblem extends StatelessWidget {
  const _LoadProblem({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 8, 4),
      child: Row(
        children: <Widget>[
          Icon(Icons.cloud_off, size: 14, color: theme.colorScheme.error),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              message,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ),
          TextButton(onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
    );
  }
}

/// One session's notes: a header naming the session (tap to open it), its
/// open notes, and for the selected session a field for new notes and its
/// checked-off notes behind a toggle.
class _SessionNotesGroup extends StatelessWidget {
  const _SessionNotesGroup({
    required this.daemonId,
    required this.sessionId,
    required this.session,
    required this.projectName,
    required this.daemonName,
    required this.selected,
    required this.open,
    required this.done,
    required this.showDone,
    required this.lingering,
    required this.arriving,
    required this.onToggleDone,
    required this.onOpen,
    required this.onSetDone,
    required this.onEdit,
    required this.onDelete,
    required this.onAdd,
  });

  final String daemonId;
  final String sessionId;
  final Session? session;
  final String? projectName;
  final String? daemonName;
  final bool selected;
  final List<SessionNote> open;
  final List<SessionNote> done;
  final bool showDone;
  final Map<String, _Linger> lingering;
  final Set<String> arriving;
  final VoidCallback onToggleDone;
  final VoidCallback? onOpen;
  final void Function(SessionNote note, bool done) onSetDone;
  final void Function(SessionNote note, String text) onEdit;
  final void Function(SessionNote note) onDelete;
  final Future<bool> Function(String text) onAdd;

  Widget _row(SessionNote note, {required bool inOpenList}) {
    final String key = '$daemonId/${note.id}';
    final _Linger? linger = inOpenList ? lingering[key] : null;
    return NoteFold(
      key: ValueKey<String>('note-${inOpenList ? 'open' : 'done'}-$key'),
      visible: !(linger?.leaving ?? false),
      appear: arriving.contains(key),
      child: NoteRow(
        note: note,
        onSetDone: (bool value) => onSetDone(note, value),
        onEdit: (String text) => onEdit(note, text),
        onDelete: () => onDelete(note),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final String title = session?.title ?? 'Session';
    final List<String> where = <String>[?daemonName, ?projectName];
    if (session?.archived ?? false) where.add('archived');
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: selected
            ? scheme.surfaceContainerHighest.withValues(alpha: 0.5)
            : null,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: selected ? null : onOpen,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: selected ? scheme.primary : null,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (where.isNotEmpty)
                    Text(
                      where.join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                        fontSize: 10,
                      ),
                    ),
                ],
              ),
            ),
          ),
          for (final SessionNote note in open) _row(note, inOpenList: true),
          if (selected)
            _NoteComposer(
              key: ValueKey<String>('note-composer-$daemonId/$sessionId'),
              onAdd: onAdd,
            ),
          if (done.isNotEmpty) ...<Widget>[
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                key: const Key('notes-show-done'),
                onPressed: onToggleDone,
                style: TextButton.styleFrom(
                  foregroundColor: scheme.onSurfaceVariant,
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                ),
                icon: Icon(
                  showDone ? Icons.expand_less : Icons.expand_more,
                  size: 16,
                ),
                label: Text(
                  '${done.length} done',
                  style: theme.textTheme.labelSmall,
                ),
              ),
            ),
            if (showDone)
              for (final SessionNote note in done)
                _row(note, inOpenList: false),
          ],
          const SizedBox(height: 4),
        ],
      ),
    );
  }
}

/// A note: its check, its text (tap to edit) and a delete button.
class NoteRow extends StatefulWidget {
  const NoteRow({
    super.key,
    required this.note,
    required this.onSetDone,
    required this.onEdit,
    required this.onDelete,
  });

  final SessionNote note;
  final ValueChanged<bool> onSetDone;
  final ValueChanged<String> onEdit;
  final VoidCallback onDelete;

  @override
  State<NoteRow> createState() => _NoteRowState();
}

class _NoteRowState extends State<NoteRow> {
  TextEditingController? _editor;
  final FocusNode _focus = FocusNode();
  bool _hovered = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus && _editor != null) _commit();
    });
  }

  @override
  void dispose() {
    _editor?.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _startEditing() {
    setState(() {
      _editor = TextEditingController(text: widget.note.text);
    });
    _focus.requestFocus();
  }

  void _commit() {
    final TextEditingController? editor = _editor;
    if (editor == null) return;
    final String text = editor.text;
    setState(() => _editor = null);
    editor.dispose();
    widget.onEdit(text);
  }

  void _cancel() {
    final TextEditingController? editor = _editor;
    if (editor == null) return;
    setState(() => _editor = null);
    editor.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final bool touch =
        theme.platform == TargetPlatform.android ||
        theme.platform == TargetPlatform.iOS;
    final TextStyle? style = theme.textTheme.bodySmall?.copyWith(
      color: widget.note.done ? scheme.onSurfaceVariant : null,
      decoration: widget.note.done ? TextDecoration.lineThrough : null,
      decorationColor: scheme.onSurfaceVariant,
    );
    final TextEditingController? editor = _editor;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Padding(
        padding: const EdgeInsets.only(left: 4, right: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            NoteCheck(checked: widget.note.done, onChanged: widget.onSetDone),
            const SizedBox(width: 4),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: editor == null
                    ? GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: _startEditing,
                        child: Text(widget.note.text, style: style),
                      )
                    : CallbackShortcuts(
                        bindings: <ShortcutActivator, VoidCallback>{
                          const SingleActivator(LogicalKeyboardKey.escape):
                              _cancel,
                        },
                        child: TextField(
                          controller: editor,
                          focusNode: _focus,
                          style: theme.textTheme.bodySmall,
                          maxLength: kMaxNoteLength,
                          maxLines: null,
                          textInputAction: TextInputAction.done,
                          onSubmitted: (_) => _commit(),
                          decoration: const InputDecoration(
                            isDense: true,
                            filled: false,
                            counterText: '',
                            border: InputBorder.none,
                            enabledBorder: InputBorder.none,
                            focusedBorder: InputBorder.none,
                            contentPadding: EdgeInsets.zero,
                          ),
                        ),
                      ),
              ),
            ),
            AnimatedOpacity(
              opacity: touch || _hovered || editor != null ? 1 : 0,
              duration: const Duration(milliseconds: 120),
              child: Tooltip(
                message: 'Delete note',
                child: InkResponse(
                  onTap: widget.onDelete,
                  radius: 14,
                  child: SizedBox.square(
                    dimension: 26,
                    child: Icon(
                      Icons.close,
                      size: 16,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The field adding a note to the selected session. Keeps focus after a
/// note goes in so a list can be typed out line by line.
class _NoteComposer extends StatefulWidget {
  const _NoteComposer({super.key, required this.onAdd});

  final Future<bool> Function(String text) onAdd;

  @override
  State<_NoteComposer> createState() => _NoteComposerState();
}

class _NoteComposerState extends State<_NoteComposer> {
  final TextEditingController _text = TextEditingController();
  final FocusNode _focus = FocusNode();
  bool _busy = false;

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final String text = _text.text.trim();
    if (text.isEmpty || _busy) return;
    setState(() => _busy = true);
    final bool added = await widget.onAdd(text);
    if (!mounted) return;
    setState(() => _busy = false);
    if (added) _text.clear();
    _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
      child: TextField(
        key: const Key('note-composer'),
        controller: _text,
        focusNode: _focus,
        style: theme.textTheme.bodySmall,
        maxLength: kMaxNoteLength,
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => _submit(),
        decoration: InputDecoration(
          isDense: true,
          counterText: '',
          hintText: 'Add a note…',
          prefixIcon: const Icon(Icons.add, size: 16),
          prefixIconConstraints: const BoxConstraints(
            minWidth: 30,
            minHeight: 30,
          ),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 8,
            vertical: 8,
          ),
        ),
      ),
    );
  }
}

/// Folds its child open on arrival ([appear]) and closed when [visible]
/// turns false, fading as it goes, so rows never jolt the list. Reduced
/// motion shows or hides it at once.
class NoteFold extends StatefulWidget {
  const NoteFold({
    super.key,
    required this.visible,
    required this.appear,
    required this.child,
  });

  final bool visible;
  final bool appear;
  final Widget child;

  @override
  State<NoteFold> createState() => _NoteFoldState();
}

class _NoteFoldState extends State<NoteFold>
    with SingleTickerProviderStateMixin {
  late final AnimationController _fold = AnimationController(
    vsync: this,
    duration: kNoteFold,
    value: widget.visible && !widget.appear ? 1 : 0,
  );
  late final Animation<double> _size = CurvedAnimation(
    parent: _fold,
    curve: Curves.easeOutCubic,
    reverseCurve: Curves.easeInCubic,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(NoteFold oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.visible != widget.visible) _sync();
  }

  void _sync() {
    final double target = widget.visible ? 1 : 0;
    if (_fold.value == target) return;
    if (MediaQuery.of(context).disableAnimations) {
      _fold.value = target;
    } else if (widget.visible) {
      _fold.forward();
    } else {
      _fold.reverse();
    }
  }

  @override
  void dispose() {
    _fold.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizeTransition(
      sizeFactor: _size,
      alignment: Alignment.topCenter,
      child: FadeTransition(opacity: _size, child: widget.child),
    );
  }
}
