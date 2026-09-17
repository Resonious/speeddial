/// Synthetic, local-only search benchmark. Run from packages/daemon:
/// dart run tool/benchmark_session_search.dart [sessions=10000] [messages=10]
/// Creates and removes its own temporary database; never starts agents.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:speeddial_daemon/src/store/daemon_store.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';
import 'package:sqlite3/sqlite3.dart' hide Session;

Future<void> main(List<String> args) async {
  final int sessions = args.isEmpty ? 10000 : int.parse(args[0]);
  final int messages = args.length < 2 ? 10 : int.parse(args[1]);
  final Directory directory = Directory.systemTemp.createTempSync(
    'search-benchmark-',
  );
  final String path = '${directory.path}/search.db';
  final DaemonStore initial = DaemonStore(path);
  final DateTime now = DateTime.now().toUtc();
  initial.insertProject(
    Project(
      id: 'p',
      name: 'Benchmark',
      path: directory.path,
      addedAt: now,
      lastActiveAt: now,
    ),
  );
  initial.dispose();
  final Database db = sqlite3.open(path);
  final PreparedStatement insertSession = db.prepare('''
    INSERT INTO sessions(id, project_id, provider_id, title, status, mode,
      cwd, archived, created_at, last_activity_at, updated_at)
    VALUES (?, 'p', 'fake', ?, 'idle', 'build', '/synthetic', 0, 0, ?, ?)
  ''');
  final PreparedStatement insertEvent = db.prepare('''
    INSERT INTO session_events(session_id, seq, timestamp, json) VALUES (?, ?, 0, ?)
  ''');
  int bytes = 0;
  try {
    db.execute('BEGIN');
    for (int i = 0; i < sessions; i++) {
      final String id = 's$i';
      insertSession.execute(<Object?>[id, 'Work on task $i', i, i]);
      for (int j = 1; j <= messages; j++) {
        final String text =
            'Session $i message $j: ${'Review the configuration and verify behavior. ' * 45}'
            ' trace-token-$i result $j.';
        bytes += text.length;
        insertEvent.execute(<Object?>[
          id,
          j,
          jsonEncode(<String, Object?>{'type': 'userMessage', 'text': text}),
        ]);
      }
    }
    // A single long streamed message exercises tail indexing rather than
    // repeatedly concatenating/reindexing its entire accumulated transcript.
    insertSession.execute(<Object?>[
      'long',
      'Long streamed session',
      sessions,
      sessions,
    ]);
    for (int seq = 1; seq <= 20000; seq++) {
      final String text = 'Stream chunk $seq ${'content ' * 14}';
      bytes += text.length;
      insertEvent.execute(<Object?>[
        'long',
        seq,
        jsonEncode(<String, Object?>{
          'type': 'agentMessageChunk',
          'messageId': 'message',
          'text': text,
        }),
      ]);
    }
    db.execute('COMMIT');
  } finally {
    insertEvent.close();
    insertSession.close();
    db.close();
  }
  stdout.writeln(
    '${sessions + 1} sessions, ${sessions * messages + 20000} events, '
    '${(bytes / 1024 / 1024).toStringAsFixed(1)} MiB of message text',
  );
  final DaemonStore store = DaemonStore(path);
  final Stopwatch build = Stopwatch()..start();
  int previousTick = 0;
  int maxGap = 0;
  final Timer heartbeat = Timer.periodic(const Duration(milliseconds: 16), (_) {
    final int tick = build.elapsedMilliseconds;
    final int gap = tick - previousTick;
    if (gap > maxGap) maxGap = gap;
    previousTick = tick;
  });
  try {
    while ((await store.searchSessionText(query: 'missing-needle')).indexing) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    heartbeat.cancel();
    stdout.writeln(
      'Initial indexing: ${build.elapsedMilliseconds} ms; '
      'largest 16 ms timer gap: $maxGap ms',
    );
    for (final String query in <String>[
      'trace-token-${sessions - 1}',
      'missing-needle',
      'configuration',
      'Stream chunk',
    ]) {
      final List<double> times = <double>[];
      int count = 0;
      for (int i = 0; i < 12; i++) {
        final Stopwatch watch = Stopwatch()..start();
        final SessionSearchPage page = await store.searchSessionText(
          query: query,
        );
        count = page.results.length;
        times.add(watch.elapsedMicroseconds / 1000);
      }
      times.sort();
      stdout.writeln(
        '$query: $count results; median ${times[6].toStringAsFixed(1)} ms, '
        'p95 ${times[11].toStringAsFixed(1)} ms',
      );
    }
    stdout.writeln(
      'Database: ${(File(path).lengthSync() / 1024 / 1024).toStringAsFixed(1)} MiB',
    );
  } finally {
    heartbeat.cancel();
    store.dispose();
    if (args.contains('--keep')) {
      stdout.writeln('Kept benchmark database: $path');
    } else {
      directory.deleteSync(recursive: true);
    }
  }
}
