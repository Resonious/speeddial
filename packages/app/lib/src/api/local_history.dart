import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:shared_preferences_platform_interface/types.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';

/// Live-only user messages and completed final replies. History reads never
/// populate this cache. Transient reply buffers retain only the latest message.
class LocalHistory {
  LocalHistory(this.daemonId);

  final String daemonId;
  Future<void> _tail = Future<void>.value();
  final Map<String, _FinalReply> _replies = {};
  static Future<void> _migration = Future<void>.value();
  static SharedPreferences? _migratedPreferences;

  Future<SharedPreferences> _preferences() async {
    final prefs = await SharedPreferences.getInstance();
    if (identical(_migratedPreferences, prefs)) return prefs;
    final operation = _migration.then((_) async {
      if (identical(_migratedPreferences, prefs)) return;
      if (prefs.getKeys().any(
        (key) => key.startsWith('speeddial.history.v1.'),
      )) {
        final removed = await SharedPreferencesStorePlatform.instance
            .clearWithParameters(
              ClearParameters(
                filter: PreferencesFilter(
                  prefix: 'flutter.speeddial.history.v1.',
                ),
              ),
            );
        if (!removed) {
          throw StateError('Could not remove oversized history cache');
        }
        await prefs.reload();
      }
      _migratedPreferences = prefs;
    });
    _migration = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    await operation;
    return prefs;
  }

  Future<void> record(String id, SessionEvent event) {
    if (event is AgentMessageChunkEvent) {
      final current = _replies[id];
      if (current == null ||
          current.messageId != event.messageId ||
          current.breakLegacy) {
        _replies[id] = _FinalReply(event);
      } else {
        current.append(event);
      }
      return Future<void>.value();
    }
    if (event is UserMessageEvent) {
      _replies.remove(id);
      return _merge(id, [event]);
    }
    if (event is HistoryRewoundEvent) {
      final current = _replies[id];
      if (current != null && (current.seq ?? 0) < (event.seq ?? 0)) {
        _replies.remove(id);
      }
      return _merge(id, [event]);
    }
    if (event is TurnCompleteEvent) {
      final reply = _replies.remove(id);
      return _merge(id, [if (reply != null) reply.event, event]);
    }
    if (event is SessionErrorEvent) _replies.remove(id);
    final current = _replies[id];
    if (current != null &&
        current.messageId == null &&
        event is! UsageEvent &&
        event is! AgentActivityEvent) {
      current.breakLegacy = true;
    }
    return Future<void>.value();
  }

  String _key(String id) =>
      'speeddial.history.v2.${base64Url.encode(utf8.encode(daemonId))}.'
      '${base64Url.encode(utf8.encode(id))}';

  Future<({List<SessionEvent> events, bool complete})?> read(String id) async {
    await _tail;
    return _read(id);
  }

  Future<({List<SessionEvent> events, bool complete})?> _read(String id) async {
    final prefs = await _preferences();
    final raw = prefs.getString(_key(id));
    if (raw == null) return null;
    final json = jsonDecode(raw) as Map<String, dynamic>;
    return (
      events: (json['events'] as List)
          .map(
            (e) => SessionEvent.fromJson(Map<String, Object?>.from(e as Map)),
          )
          .toList(),
      complete: false,
    );
  }

  Future<List<Map<String, Object?>>?> readIndex(String kind) async {
    await _tail;
    final prefs = await _preferences();
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
    final prefs = await _preferences();
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

  Future<void> _merge(String id, List<SessionEvent> events) {
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
      final prefs = await _preferences();
      final saved = await prefs.setString(
        _key(id),
        jsonEncode({'events': sorted.map((e) => e.toJson()).toList()}),
      );
      if (!saved) throw StateError('Could not save offline session history');
    });
  }

  Future<void> remove(String id) {
    _replies.remove(id);
    return _enqueue(() async {
      final prefs = await _preferences();
      if (!await prefs.remove(_key(id))) {
        throw StateError('Could not remove offline session history');
      }
    });
  }

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

class _FinalReply {
  _FinalReply(AgentMessageChunkEvent first) : messageId = first.messageId {
    append(first);
  }
  final String? messageId;
  final StringBuffer text = StringBuffer();
  int? seq;
  DateTime? timestamp;
  bool breakLegacy = false;

  void append(AgentMessageChunkEvent chunk) {
    text.write(chunk.text);
    seq = chunk.seq;
    timestamp = chunk.timestamp;
  }

  AgentMessageChunkEvent get event => AgentMessageChunkEvent(
    text: text.toString(),
    messageId: messageId,
    seq: seq,
    timestamp: timestamp,
  );
}
