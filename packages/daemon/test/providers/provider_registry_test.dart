@TestOn('vm')
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:speeddial_daemon/src/providers/provider_registry.dart';
import 'package:test/test.dart';

ProviderRegistry registryWith(Map<String, Object?> overrides) =>
    ProviderRegistry(configOverrides: overrides);

Map<String, Object?> fakeProvider(String name, List<String> command) =>
    <String, Object?>{
      'providers': <String, Object?>{
        'fake': <String, Object?>{
          'name': name,
          'command': command,
        },
      },
    };

void main() {
  test('built-in providers are present and listed first', () {
    final registry = ProviderRegistry();
    final providers = registry.list();

    expect(
      providers.map((info) => info.id),
      <String>['omp', 'claude', 'codex'],
    );
    final omp = registry.byId('omp')!;
    expect(omp.name, 'OMP');
    expect(omp.command, <String>['omp', 'acp']);
    final claude = registry.byId('claude')!;
    expect(
      claude.command,
      <String>['npx', '-y', '@zed-industries/claude-code-acp'],
    );
    final codex = registry.byId('codex')!;
    expect(
      codex.command,
      <String>['npx', '-y', '@zed-industries/codex-acp'],
    );

    // ProviderInfo carries the joined command and an empty model list.
    expect(providers.first.command, 'omp acp');
    expect(providers.first.models, isEmpty);
    expect(providers.first.name, isNotEmpty);
  });

  test('byId returns null for unknown providers', () {
    expect(ProviderRegistry().byId('nope'), isNull);
    expect(ProviderRegistry().byId(''), isNull);
  });

  test('availability is false for commands that do not resolve', () {
    final registry = registryWith(<String, Object?>{
      'providers': <String, Object?>{
        'bogus': <String, Object?>{
          'name': 'Bogus',
          'command': <String>['definitely-not-a-real-binary-xyz-9876'],
        },
        'absMissing': <String, Object?>{
          'name': 'AbsMissing',
          'command': <String>[p.join(Directory.systemTemp.path, 'nope-xyz')],
        },
      },
    });

    expect(registry.isAvailable('bogus'), isFalse);
    expect(registry.isAvailable('absMissing'), isFalse);
    final info = registry.list().firstWhere((p) => p.id == 'absMissing');
    expect(info.available, isFalse);
    expect(registry.byId('bogus'), isNotNull);
  });

  test('availability is true for an absolute existing executable', () {
    final registry = registryWith(fakeProvider('Fake', <String>[
      Platform.resolvedExecutable,
      '--help',
    ]));
    expect(registry.isAvailable('fake'), isTrue);
    final info = registry.list().firstWhere((p) => p.id == 'fake');
    expect(info.available, isTrue);
  });

  test('availability resolves bare commands via PATH', () {
    final pathEnv = Platform.environment['PATH'];
    expect(pathEnv, isNotNull, reason: 'PATH is set on the test host');
    String? knownExe;
    for (final dir in pathEnv!.split(Platform.isWindows ? ';' : ':')) {
      if (dir.isEmpty) continue;
      for (final candidate in <String>['sh', 'echo', 'dart']) {
        if (File(p.join(dir, candidate)).existsSync()) {
          knownExe = candidate;
          break;
        }
      }
      if (knownExe != null) break;
    }
    expect(knownExe, isNotNull, reason: 'expected a common executable on PATH');

    final registry =
        registryWith(fakeProvider('PathFinder', <String>[knownExe!]));
    expect(registry.isAvailable('fake'), isTrue);
    expect(
      registry.list().firstWhere((info) => info.id == 'fake').available,
      isTrue,
    );
  });

  test('config overrides a built-in and adds a custom provider', () {
    final registry = registryWith(<String, Object?>{
      'providers': <String, Object?>{
        'omp': <String, Object?>{
          'name': 'My OMP',
          'command': <String>['/usr/bin/omp', 'acp'],
        },
        'custom': <String, Object?>{
          'name': 'Custom Agent',
          'command': <String>['custom-agent', '--flag'],
        },
      },
    });

    final omp = registry.byId('omp')!;
    expect(omp.name, 'My OMP');
    expect(omp.command, <String>['/usr/bin/omp', 'acp']);
    expect(
      registry.list().map((info) => info.id),
      <String>['omp', 'claude', 'codex', 'custom'],
    );
    final customInfo = registry.list().firstWhere((info) => info.id == 'custom');
    expect(customInfo.name, 'Custom Agent');
    expect(customInfo.command, 'custom-agent --flag');
    expect(customInfo.models, isEmpty);
  });

  test('malformed config entries are skipped defensively', () {
    final registry = registryWith(<String, Object?>{
      'providers': <String, Object?>{
        'badCommand': <String, Object?>{'name': 'Bad', 'command': 'not-a-list'},
        'missingName': <String, Object?>{'command': <String>['x', 'y']},
        'emptyCommand': <String, Object?>{'name': 'Empty', 'command': <String>[]},
        'badItem': <String, Object?>{
          'name': 'BadItem',
          'command': <Object>['ok', 42],
        },
        'good': <String, Object?>{
          'name': 'Good',
          'command': <String>['g', '--x'],
        },
      },
    });

    expect(registry.byId('badCommand'), isNull);
    expect(registry.byId('missingName'), isNull);
    expect(registry.byId('emptyCommand'), isNull);
    expect(registry.byId('badItem'), isNull);
    final good = registry.byId('good')!;
    expect(good.name, 'Good');
    expect(registry.list().map((info) => info.id), contains('good'));
  });

  test('config without a providers key changes nothing', () {
    final registry = registryWith(<String, Object?>{'other': 1});
    expect(
      registry.list().map((info) => info.id),
      <String>['omp', 'claude', 'codex'],
    );
    expect(registry.byId('omp')!.command, <String>['omp', 'acp']);
  });
}
