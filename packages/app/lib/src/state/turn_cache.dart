import 'dart:collection';

import 'package:speeddial_protocol/speeddial_protocol.dart';

/// Reuses completed turns while deriving only the mutable tail during streaming.
/// Input may append events or replace its last chunk; a prepend/refetch resets
/// the cache. Results share the append-only completed prefix without copying it.
class TurnCache<T> {
  TurnCache(this.derive);

  final List<T> Function(List<SessionEvent> events, bool running) derive;
  List<T> _completed = <T>[];
  int _tailStart = 0;
  int _scanned = 0;
  SessionEvent? _first;
  SessionEvent? _boundary;
  final Map<String, int> _activityOrigins = <String, int>{};

  List<T> update(List<SessionEvent> events, {bool running = false}) {
    if (events.length < _scanned ||
        (events.isNotEmpty && !identical(events.first, _first)) ||
        (_tailStart > 0 && !identical(events[_tailStart - 1], _boundary))) {
      _completed = <T>[];
      _tailStart = 0;
      _scanned = 0;
      _activityOrigins.clear();
    }
    _first = events.firstOrNull;
    // Activity ids are session-scoped. A late snapshot can invalidate a sealed
    // turn, including when history arrives in one batch. Rebuild only on such
    // updates; ordinary streaming still derives just the mutable tail.
    bool lateActivity = false;
    int boundary = _tailStart;
    for (int i = _scanned; i < events.length; i++) {
      final SessionEvent event = events[i];
      if (event is UserMessageEvent) boundary = i;
      if (event is AgentActivityEvent) {
        final int origin = _activityOrigins.putIfAbsent(
          event.activity.id,
          () => i,
        );
        if (origin < boundary) lateActivity = true;
      }
      if (event is TurnCompleteEvent || event is SessionErrorEvent) {
        boundary = i + 1;
      }
    }
    if (lateActivity) {
      _completed = <T>[];
      _tailStart = 0;
      _boundary = null;
    }
    // A merged chunk at the previous tail can change, but cannot introduce a
    // turn boundary. Only newly appended events need boundary inspection.
    for (int i = _scanned; !lateActivity && i < events.length; i++) {
      final SessionEvent event = events[i];
      if (event is UserMessageEvent && i > _tailStart) {
        _seal(events, i);
      }
      if (event is TurnCompleteEvent || event is SessionErrorEvent) {
        _seal(events, i + 1);
      }
    }
    _scanned = events.length;
    final List<T> tail = derive(events.sublist(_tailStart), running);
    return _JoinedList<T>(_completed, tail);
  }

  void _seal(List<SessionEvent> events, int end) {
    _completed.addAll(derive(events.sublist(_tailStart, end), false));
    _tailStart = end;
    _boundary = events[end - 1];
  }
}

class _JoinedList<T> extends ListBase<T> {
  _JoinedList(this.head, this.tail) : _headLength = head.length;

  final int _headLength;
  final List<T> head;
  final List<T> tail;

  @override
  int get length => _headLength + tail.length;
  @override
  set length(int value) => throw UnsupportedError('Read-only timeline');
  @override
  T operator [](int index) =>
      index < _headLength ? head[index] : tail[index - _headLength];
  @override
  void operator []=(int index, T value) =>
      throw UnsupportedError('Read-only timeline');
}
