import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';

/// Compact offline transcripts, isolated by configured daemon and session.
/// The watermark advances only after a complete catch-up, never for live echoes.
class LocalHistory {
  LocalHistory(this.daemonId);

  final String daemonId;
  Future<void> _tail = Future<void>.value();

  String _key(String id) =>
      'speeddial.history.v1.${base64Url.encode(utf8.encode(daemonId))}.'
      '${base64Url.encode(utf8.encode(id))}';

  Future<({List<SessionEvent> events, int watermark, bool complete})?> read(
    String id,
  ) async {
    await _tail;
    return _read(id);
  }

  Future<({List<SessionEvent> events, int watermark, bool complete})?> _read(
    String id,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key(id));
    if (raw == null) return null;
    final json = jsonDecode(raw) as Map<String, dynamic>;
    return (
      events: (json['events'] as List)
          .map(
            (e) => SessionEvent.fromJson(Map<String, Object?>.from(e as Map)),
          )
          .toList(),
      watermark: json['watermark'] as int,
      complete: json['complete'] as bool? ?? (json['watermark'] as int) > 0,
    );
  }

  Future<List<Map<String, Object?>>?> readIndex(String kind) async {
    await _tail;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('${_key('')}.$kind');
    if (raw == null) return null;
    return (jsonDecode(raw) as List)
        .map((e) => Map<String, Object?>.from(e as Map))
        .toList();
  }

  Future<void> writeIndex(
    String kind,
    List<Map<String, Object?>> rows, {
    bool replace = false,
    String? removeId,
  }) => _enqueue(() async {
    final prefs = await SharedPreferences.getInstance();
    final key = '${_key('')}.$kind';
    final raw = prefs.getString(key);
    final byId = <String, Map<String, Object?>>{};
    if (!replace && raw != null) {
      for (final row in jsonDecode(raw) as List) {
        final map = Map<String, Object?>.from(row as Map);
        byId[map['id'] as String] = map;
      }
    }
    for (final row in rows) {
      byId[row['id'] as String] = row;
    }
    byId.remove(removeId);
    if (!await prefs.setString(key, jsonEncode(byId.values.toList()))) {
      throw StateError('Could not save offline session index');
    }
  });

  Future<void> merge(String id, List<SessionEvent> events, {int? watermark}) {
    // Copy before queuing: callers may reuse their page buffer.
    final incoming = List<SessionEvent>.of(events);
    return _enqueue(() async {
      final previous = await _read(id);
      final bySeq = <int, SessionEvent>{
        for (final event in previous?.events ?? <SessionEvent>[])
          if (event.seq != null) event.seq!: event,
      };
      for (final event in incoming) {
        if (event.seq != null &&
            (event is UserMessageEvent ||
                event is AgentMessageChunkEvent ||
                event is TurnCompleteEvent ||
                event is SessionErrorEvent ||
                event is HistoryRewoundEvent)) {
          bySeq[event.seq!] = event;
        }
      }
      // Retain rewind markers so a late older page cannot resurrect text.
      for (final rewind
          in bySeq.values.whereType<HistoryRewoundEvent>().toList()) {
        bySeq.removeWhere(
          (seq, _) => seq >= rewind.beforeSeq && seq < rewind.seq!,
        );
      }
      final sorted = bySeq.values.toList()
        ..sort((a, b) => a.seq!.compareTo(b.seq!));
      final prefs = await SharedPreferences.getInstance();
      final saved = await prefs.setString(
        _key(id),
        jsonEncode({
          'watermark': watermark ?? previous?.watermark ?? 0,
          'complete': watermark != null || (previous?.complete ?? false),
          'events': sorted.map((e) => e.toJson()).toList(),
        }),
      );
      if (!saved) throw StateError('Could not save offline session history');
    });
  }

  Future<void> remove(String id) => _enqueue(() async {
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.remove(_key(id))) {
      throw StateError('Could not remove offline session history');
    }
  });

  Future<void> _enqueue(Future<void> Function() operation) {
    final result = _tail.then(
      (_) => operation(),
      onError: (Object _, StackTrace _) => operation(),
    );
    // Callers receive errors; subsequent reads/writes can still retry.
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }
}
