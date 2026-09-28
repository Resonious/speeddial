import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:speeddial_daemon/src/cli/auto_update.dart';
import 'package:test/test.dart';

void main() {
  test(
    'supervisor reloads source and preserves arguments, cwd and token',
    () async {
      final root = Directory.systemTemp.createTempSync('speeddial-supervisor-');
      addTearDown(() => root.deleteSync(recursive: true));
      final entrypoint = File(
        p.join(root.path, 'packages/daemon/bin/speeddial.dart'),
      );
      entrypoint.parent.createSync(recursive: true);
      // A local fake worker: no Git remotes, sockets, or agent processes.
      entrypoint.writeAsStringSync(r'''
import 'dart:convert';
import 'dart:io';
void main(List<String> args) {
  final log = File(args.last);
  log.writeAsStringSync(jsonEncode({
    'args': args, 'cwd': Directory.current.path,
    'worker': Platform.environment['SPEEDDIAL_DAEMON_WORKER'],
    'token': Platform.environment['SPEEDIAL_TOKEN'],
  }) + '\n');
  File.fromUri(Platform.script).writeAsStringSync("import 'dart:io'; void main(List<String> args) { File(args.last).writeAsStringSync(Platform.environment['SPEEDIAL_TOKEN']!, mode: FileMode.append); exit(0); }");
  exit(75);
}
''');
      final record = File(p.join(root.path, 'record'));
      final args = ['serve', '--host=0.0.0.0', '--port=7339', record.path];
      expect(await superviseDaemon(args, root.path), 0);
      final lines = record.readAsLinesSync();
      final first = jsonDecode(lines.first) as Map<String, dynamic>;
      expect(first['args'], args);
      expect(first['cwd'], Directory.current.path);
      expect(first['worker'], '1');
      expect(first['token'], isNotEmpty);
      expect(lines.last, first['token']);
    },
  );
}
