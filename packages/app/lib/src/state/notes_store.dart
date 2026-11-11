import 'dart:async';

import 'package:speeddial_protocol/speeddial_protocol.dart';

import '../api/daemon_client.dart';
import 'store_base.dart';

/// Checked-off and total note counts for one session.
typedef NoteCounts = ({int done, int total});

/// A session on a particular daemon.
typedef DaemonSessionKey = ({String daemonId, String sessionId});

/// Session notes (a per-session to-do list) for every daemon someone asked
/// about through [ensureLoaded].
///
/// Each daemon's notes load once with `notes.list` and then stay fresh from
/// `note.updated` / `note.removed` / `session.removed` notifications, with a
/// full reload after every reconnect. A load that fails, or that is asked for
/// while the daemon is still connecting, is retried when the daemon's
/// connection status changes ([onConnectionChanged]).
///
/// Mutations apply optimistically and roll back on failure; every failure is
/// recorded in [lastError] (loads also in [errorFor]), notified, and
/// rethrown.
class NotesStore extends StoreBase {
  NotesStore({
    required DaemonClient Function(String daemonId) clientFor,
    required bool Function(String daemonId) canLoad,
  }) : _clientFor = clientFor, // ignore: prefer_initializing_formals
       _canLoad = canLoad; // ignore: prefer_initializing_formals

  final DaemonClient Function(String daemonId) _clientFor;

  /// Whether requests to the daemon can be attempted now (connected, or a
  /// client that never connects such as a registered fake).
  final bool Function(String daemonId) _canLoad;

  /// daemonId → noteId → note.
  final Map<String, Map<String, SessionNote>> _notes =
      <String, Map<String, SessionNote>>{};

  /// Each session's notes, oldest first. Rebuilt lazily after any change so
  /// rows can read counts without scanning.
  Map<DaemonSessionKey, List<SessionNote>>? _bySession;

  final Set<String> _wanted = <String>{};
  final Set<String> _loaded = <String>{};
  final Map<String, Future<void>> _loading = <String, Future<void>>{};
  final Map<String, Object> _loadErrors = <String, Object>{};
  final Map<String, List<StreamSubscription<Object?>>> _subscriptions =
      <String, List<StreamSubscription<Object?>>>{};

  /// The most recent failure of any load or mutation.
  Object? lastError;

  bool hasLoaded(String daemonId) => _loaded.contains(daemonId);

  bool isLoading(String daemonId) => _loading.containsKey(daemonId);

  Object? errorFor(String daemonId) => _loadErrors[daemonId];

  /// Starts loading [daemonId]'s notes unless they are loaded, loading, or
  /// failed (failures retry on the next connection change). Safe to call
  /// from `build`: nothing notifies synchronously.
  void ensureLoaded(String daemonId) {
    _wanted.add(daemonId);
    _maybeLoad(daemonId);
  }

  /// Retries daemons that were asked for but could not load yet.
  void onConnectionChanged() {
    for (final String daemonId in _wanted.toList(growable: false)) {
      _loadErrors.remove(daemonId);
      _maybeLoad(daemonId);
    }
  }

  /// Stops tracking daemons that are no longer configured.
  void retainDaemons(Set<String> daemonIds) {
    for (final String daemonId in _wanted.toList(growable: false)) {
      if (daemonIds.contains(daemonId)) continue;
      _wanted.remove(daemonId);
      _loaded.remove(daemonId);
      _loadErrors.remove(daemonId);
      _notes.remove(daemonId);
      for (final StreamSubscription<Object?> sub
          in _subscriptions.remove(daemonId) ?? const []) {
        unawaited(sub.cancel());
      }
      _changed();
    }
  }

  void _maybeLoad(String daemonId) {
    if (isDisposed ||
        _loaded.contains(daemonId) ||
        _loading.containsKey(daemonId) ||
        _loadErrors.containsKey(daemonId) ||
        !_canLoad(daemonId)) {
      return;
    }
    unawaited(refresh(daemonId).then((_) {}, onError: (Object _) {}));
  }

  /// Reloads every note on [daemonId].
  Future<void> refresh(String daemonId) {
    final Future<void>? inFlight = _loading[daemonId];
    if (inFlight != null) return inFlight;
    final Future<void> load = _load(daemonId);
    _loading[daemonId] = load;
    return load;
  }

  Future<void> _load(String daemonId) async {
    // Yield first: [ensureLoaded] runs during build, and even a synchronous
    // failure below must not notify until the frame is done.
    await null;
    try {
      final DaemonClient client = _clientFor(daemonId);
      _subscribe(daemonId, client);
      final List<SessionNote> notes = await client.listNotes();
      _notes[daemonId] = <String, SessionNote>{
        for (final SessionNote note in notes) note.id: note,
      };
      _loaded.add(daemonId);
      _loadErrors.remove(daemonId);
    } catch (error) {
      _loadErrors[daemonId] = error;
      lastError = error;
      rethrow;
    } finally {
      _loading.remove(daemonId);
      _changed();
    }
  }

  void _subscribe(String daemonId, DaemonClient client) {
    if (_subscriptions.containsKey(daemonId)) return;
    _subscriptions[daemonId] = <StreamSubscription<Object?>>[
      client.noteUpdates.listen((SessionNote note) => _upsert(daemonId, note)),
      client.noteRemovals.listen((String noteId) => _remove(daemonId, noteId)),
      client.sessionRemovals.listen((String sessionId) {
        final Map<String, SessionNote>? notes = _notes[daemonId];
        if (notes == null) return;
        final int before = notes.length;
        notes.removeWhere(
          (String _, SessionNote note) => note.sessionId == sessionId,
        );
        if (notes.length != before) _changed();
      }),
      client.resynced.listen((void _) {
        unawaited(refresh(daemonId).then((_) {}, onError: (Object _) {}));
      }),
    ];
  }

  void _upsert(String daemonId, SessionNote note) {
    final Map<String, SessionNote> notes = _notes.putIfAbsent(
      daemonId,
      () => <String, SessionNote>{},
    );
    if (notes[note.id] == note) return;
    notes[note.id] = note;
    _changed();
  }

  void _remove(String daemonId, String noteId) {
    if (_notes[daemonId]?.remove(noteId) != null) _changed();
  }

  void _changed() {
    _bySession = null;
    notifyListeners();
  }

  Map<DaemonSessionKey, List<SessionNote>> get _index {
    final Map<DaemonSessionKey, List<SessionNote>>? cached = _bySession;
    if (cached != null) return cached;
    final Map<DaemonSessionKey, List<SessionNote>> index =
        <DaemonSessionKey, List<SessionNote>>{};
    for (final MapEntry<String, Map<String, SessionNote>> daemon
        in _notes.entries) {
      for (final SessionNote note in daemon.value.values) {
        index
            .putIfAbsent((
              daemonId: daemon.key,
              sessionId: note.sessionId,
            ), () => <SessionNote>[])
            .add(note);
      }
    }
    for (final List<SessionNote> notes in index.values) {
      notes.sort(_byCreation);
    }
    return _bySession = index;
  }

  static int _byCreation(SessionNote a, SessionNote b) {
    final int order = a.createdAt.compareTo(b.createdAt);
    return order != 0 ? order : a.id.compareTo(b.id);
  }

  /// [sessionId]'s notes on [daemonId], oldest first.
  List<SessionNote> notesFor(String daemonId, String sessionId) =>
      _index[(daemonId: daemonId, sessionId: sessionId)] ??
      const <SessionNote>[];

  NoteCounts countsFor(String daemonId, String sessionId) {
    final List<SessionNote> notes = notesFor(daemonId, sessionId);
    int done = 0;
    for (final SessionNote note in notes) {
      if (note.done) done++;
    }
    return (done: done, total: notes.length);
  }

  /// Sessions with at least one open note, in no particular order.
  List<DaemonSessionKey> sessionsWithOpenNotes() => <DaemonSessionKey>[
    for (final MapEntry<DaemonSessionKey, List<SessionNote>> entry
        in _index.entries)
      if (entry.value.any((SessionNote note) => !note.done)) entry.key,
  ];

  /// Every note on [daemonId] (empty until loaded), in no particular order.
  Iterable<SessionNote> notesOn(String daemonId) =>
      _notes[daemonId]?.values ?? const <SessionNote>[];

  /// Every open note across loaded daemons.
  int get openCount {
    int open = 0;
    for (final Map<String, SessionNote> notes in _notes.values) {
      for (final SessionNote note in notes.values) {
        if (!note.done) open++;
      }
    }
    return open;
  }

  Future<SessionNote> add(
    String daemonId,
    String sessionId,
    String text,
  ) async {
    try {
      final SessionNote note = await _clientFor(daemonId)
          .createNote(sessionId, text);
      _upsert(daemonId, note);
      return note;
    } catch (error) {
      lastError = error;
      notifyListeners();
      rethrow;
    }
  }

  Future<void> setDone(String daemonId, String noteId, bool done) =>
      _update(daemonId, noteId, done: done);

  Future<void> edit(String daemonId, String noteId, String text) =>
      _update(daemonId, noteId, text: text.trim());

  Future<void> _update(
    String daemonId,
    String noteId, {
    String? text,
    bool? done,
  }) async {
    final SessionNote? previous = _notes[daemonId]?[noteId];
    SessionNote? optimistic;
    if (previous != null) {
      final DateTime now = DateTime.now().toUtc();
      optimistic = previous.copyWith(
        text: text,
        done: done,
        updatedAt: now,
        doneAt: done == null || done == previous.done
            ? null
            : () => done ? now : null,
      );
      _upsert(daemonId, optimistic);
    }
    try {
      final SessionNote note = await _clientFor(daemonId)
          .updateNote(noteId, text: text, done: done);
      _upsert(daemonId, note);
    } catch (error) {
      final Map<String, SessionNote>? notes = _notes[daemonId];
      if (previous != null && notes != null && notes[noteId] == optimistic) {
        notes[noteId] = previous;
        _bySession = null;
      }
      lastError = error;
      notifyListeners();
      rethrow;
    }
  }

  Future<void> remove(String daemonId, String noteId) async {
    final SessionNote? previous = _notes[daemonId]?.remove(noteId);
    if (previous != null) _changed();
    try {
      await _clientFor(daemonId).deleteNote(noteId);
    } catch (error) {
      if (previous != null) {
        _notes.putIfAbsent(daemonId, () => <String, SessionNote>{})[noteId] =
            previous;
        _bySession = null;
      }
      lastError = error;
      notifyListeners();
      rethrow;
    }
  }

  @override
  void dispose() {
    for (final List<StreamSubscription<Object?>> subs
        in _subscriptions.values) {
      for (final StreamSubscription<Object?> sub in subs) {
        unawaited(sub.cancel());
      }
    }
    _subscriptions.clear();
    super.dispose();
  }
}
