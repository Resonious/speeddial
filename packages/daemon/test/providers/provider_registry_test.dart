@TestOn('vm')
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:speeddial_daemon/src/providers/provider_registry.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';
import 'package:test/test.dart';

/// Probe stub: no provider has models. Keeps tests off real agent CLIs.
Future<List<String>> noModels(List<String> command) async => const <String>[];

ProviderRegistry registryWith(Map<String, Object?> overrides) =>
    ProviderRegistry(configOverrides: overrides, modelsProbe: noModels);

Map<String, Object?> fakeProvider(String name, List<String> command) =>
    <String, Object?>{
      'providers': <String, Object?>{
        'fake': <String, Object?>{'name': name, 'command': command},
      },
    };

/// Config that overrides the built-in `omp` entry with a spawnable command
/// (the current Dart VM) so availability gates pass without a real `omp`.
Map<String, Object?> spawnableOmp({Map<String, Object?>? extra}) =>
    <String, Object?>{
      'providers': <String, Object?>{
        'omp': <String, Object?>{
          'name': 'OMP',
          'command': <String>[Platform.resolvedExecutable, 'acp'],
          ...?extra,
        },
      },
    };

/// Path of the fake Ante fixture (its `catalog` mode emits the real
/// `ante catalog` JSON shape).
String resolveAnteFixture() => <String>[
  p.join(Directory.current.path, 'test', 'fixtures', 'fake_ante_agent.dart'),
  p.join(
    Directory.current.path,
    'packages',
    'daemon',
    'test',
    'fixtures',
    'fake_ante_agent.dart',
  ),
].firstWhere((String path) => File(path).existsSync());

/// Config that overrides the built-in `ante` entry with a spawnable command
/// and a fixture-backed catalog command, so probes run without a real ante.
Map<String, Object?> spawnableAnte({Map<String, Object?>? extra}) =>
    <String, Object?>{
      'providers': <String, Object?>{
        'ante': <String, Object?>{
          'name': 'Ante',
          'command': <String>[Platform.resolvedExecutable, 'serve'],
          'protocol': 'ante',
          'catalogCommand': <String>[
            Platform.resolvedExecutable,
            resolveAnteFixture(),
            'catalog',
          ],
          ...?extra,
        },
      },
    };

void main() {
  test('built-in providers are present and listed first', () async {
    final registry = ProviderRegistry(modelsProbe: noModels);
    final providers = await registry.list();

    expect(providers.map((info) => info.id), <String>[
      'omp',
      'claude',
      'codex',
      'ante',
    ]);
    final omp = registry.byId('omp')!;
    expect(omp.name, 'OMP');
    expect(omp.command, <String>['omp', 'acp']);
    expect(omp.modelsCommand, <String>['omp', 'models', '--json']);
    final claude = registry.byId('claude')!;
    expect(claude.command, <String>[
      'npx',
      '-y',
      '@zed-industries/claude-code-acp',
    ]);
    final codex = registry.byId('codex')!;
    expect(codex.command, <String>['codex', 'app-server', '--stdio']);
    expect(codex.protocol, ProviderProtocol.codex);
    final ante = registry.byId('ante')!;
    expect(ante.command, <String>['ante', 'serve', '--stdio']);
    expect(ante.protocol, ProviderProtocol.ante);
    expect(ante.catalogCommand, <String>['ante', 'catalog']);

    // ProviderInfo carries the joined command and the (stubbed) model list.
    expect(providers.first.command, 'omp acp');
    expect(providers.first.models, isEmpty);
    expect(providers.first.name, isNotEmpty);
    expect(providers.first.sandboxModes, isEmpty);
    expect(
      providers.firstWhere((info) => info.id == 'codex').sandboxModes,
      <SessionSandboxMode>[
        SessionSandboxMode.workspaceWrite,
        SessionSandboxMode.unrestricted,
      ],
    );
  });

  test('byId returns null for unknown providers', () {
    expect(ProviderRegistry(modelsProbe: noModels).byId('nope'), isNull);
    expect(ProviderRegistry(modelsProbe: noModels).byId(''), isNull);
  });

  test('availability is false for commands that do not resolve', () async {
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
    final providers = await registry.list();
    final info = providers.firstWhere((p) => p.id == 'absMissing');
    expect(info.available, isFalse);
    expect(registry.byId('bogus'), isNotNull);
  });

  test('availability is true for an absolute existing executable', () async {
    final registry = registryWith(
      fakeProvider('Fake', <String>[Platform.resolvedExecutable, '--help']),
    );
    expect(registry.isAvailable('fake'), isTrue);
    final info = (await registry.list()).firstWhere((p) => p.id == 'fake');
    expect(info.available, isTrue);
  });

  test('availability resolves bare commands via PATH', () async {
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

    final registry = registryWith(
      fakeProvider('PathFinder', <String>[knownExe!]),
    );
    expect(registry.isAvailable('fake'), isTrue);
    expect(
      (await registry.list()).firstWhere((info) => info.id == 'fake').available,
      isTrue,
    );
  });

  test('config overrides a built-in and adds a custom provider', () async {
    final registry = registryWith(<String, Object?>{
      'providers': <String, Object?>{
        'omp': <String, Object?>{
          'name': 'My OMP',
          'command': <String>[Platform.resolvedExecutable, 'acp'],
        },
        'custom': <String, Object?>{
          'name': 'Custom Agent',
          'command': <String>['custom-agent', '--flag'],
        },
      },
    });

    final omp = registry.byId('omp')!;
    expect(omp.name, 'My OMP');
    expect(omp.command, <String>[Platform.resolvedExecutable, 'acp']);
    // An override that omits modelsCommand inherits the previous entry's.
    expect(omp.modelsCommand, <String>['omp', 'models', '--json']);
    final providers = await registry.list();
    expect(providers.map((info) => info.id), <String>[
      'omp',
      'claude',
      'codex',
      'ante',
      'custom',
    ]);
    final customInfo = providers.firstWhere((info) => info.id == 'custom');
    expect(customInfo.name, 'Custom Agent');
    expect(customInfo.command, 'custom-agent --flag');
    expect(customInfo.models, isEmpty);
  });

  test('custom providers can select direct wire protocols', () {
    final ProviderRegistry registry = registryWith(<String, Object?>{
      'providers': <String, Object?>{
        'customAnte': <String, Object?>{
          'name': 'Custom Ante',
          'command': <String>['custom-ante', 'serve'],
          'protocol': 'ante',
          'catalogCommand': <String>['custom-ante', 'catalog'],
        },
        'customCodex': <String, Object?>{
          'name': 'Custom Codex',
          'command': <String>['custom-codex', 'app-server'],
          'protocol': 'codex',
        },
      },
    });

    final ProviderSpec customAnte = registry.byId('customAnte')!;
    expect(customAnte.protocol, ProviderProtocol.ante);
    expect(customAnte.catalogCommand, <String>['custom-ante', 'catalog']);
    expect(registry.byId('customCodex')!.protocol, ProviderProtocol.codex);
  });

  test('an override without protocol defaults to ACP', () {
    final ProviderRegistry registry = registryWith(<String, Object?>{
      'providers': <String, Object?>{
        'codex': <String, Object?>{
          'name': 'Legacy Codex ACP',
          'command': <String>['codex-acp'],
        },
      },
    });

    expect(registry.byId('codex')!.protocol, ProviderProtocol.acp);
  });

  test('malformed config entries are skipped defensively', () async {
    final registry = registryWith(<String, Object?>{
      'providers': <String, Object?>{
        'badCommand': <String, Object?>{'name': 'Bad', 'command': 'not-a-list'},
        'missingName': <String, Object?>{
          'command': <String>['x', 'y'],
        },
        'emptyCommand': <String, Object?>{
          'name': 'Empty',
          'command': <String>[],
        },
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
    expect((await registry.list()).map((info) => info.id), contains('good'));
  });

  test('config without a providers key changes nothing', () async {
    final registry = registryWith(<String, Object?>{'other': 1});
    expect((await registry.list()).map((info) => info.id), <String>[
      'omp',
      'claude',
      'codex',
      'ante',
    ]);
    expect(registry.byId('omp')!.command, <String>['omp', 'acp']);
  });

  group('models', () {
    test('probed models populate ProviderInfo via modelsCommand', () async {
      var probedWith = <String>[];
      final registry = ProviderRegistry(
        configOverrides: spawnableOmp(),
        modelsProbe: (command) async {
          probedWith = command;
          return <String>['m1', 'm2'];
        },
      );
      final omp = (await registry.list()).firstWhere((p) => p.id == 'omp');
      expect(omp.models, <String>['m1', 'm2']);
      expect(probedWith, <String>['omp', 'models', '--json']);
    });

    test('ante models are catalog-probed as provider-qualified ids', () async {
      // The fixture's `catalog` mode emits the real `ante catalog` shape.
      final registry = ProviderRegistry(
        configOverrides: spawnableAnte(),
        modelsProbe: noModels,
      );
      final ante = (await registry.list()).firstWhere((p) => p.id == 'ante');
      expect(ante.models, const <String>[
        'fake-provider/fake-model',
        'fake-provider/fake-large',
      ]);
    });

    test('ante catalog probe failure degrades to empty models', () async {
      final registry = ProviderRegistry(
        configOverrides: spawnableAnte(),
        modelsProbe: noModels,
        catalogProbe: (command) async => throw const FileSystemException('x'),
      );
      final ante = (await registry.list()).firstWhere((p) => p.id == 'ante');
      expect(ante.models, isEmpty);
    });

    test('static config models win and skip the probe', () async {
      var probes = 0;
      final registry = ProviderRegistry(
        configOverrides: spawnableOmp(
          extra: <String, Object?>{
            'models': <String>['static-a', 'static-b'],
          },
        ),
        modelsProbe: (command) async {
          probes++;
          return <String>['probed'];
        },
      );
      final omp = (await registry.list()).firstWhere((p) => p.id == 'omp');
      expect(omp.models, <String>['static-a', 'static-b']);
      expect(probes, 0);
    });

    test('explicit empty modelsCommand disables probing', () async {
      var probes = 0;
      final registry = ProviderRegistry(
        configOverrides: spawnableOmp(
          extra: <String, Object?>{'modelsCommand': <String>[]},
        ),
        modelsProbe: (command) async {
          probes++;
          return <String>['probed'];
        },
      );
      final omp = (await registry.list()).firstWhere((p) => p.id == 'omp');
      expect(omp.models, isEmpty);
      expect(probes, 0);
    });

    test('probe failure yields empty models and is retried', () async {
      var probes = 0;
      final registry = ProviderRegistry(
        configOverrides: spawnableOmp(),
        modelsProbe: (command) async {
          probes++;
          throw StateError('boom');
        },
      );
      expect(
        (await registry.list()).firstWhere((p) => p.id == 'omp').models,
        isEmpty,
      );
      expect(
        (await registry.list()).firstWhere((p) => p.id == 'omp').models,
        isEmpty,
      );
      expect(probes, 2, reason: 'failures are not cached');
    });

    test('probe successes are cached and shared across list() calls', () async {
      var probes = 0;
      final registry = ProviderRegistry(
        configOverrides: spawnableOmp(),
        modelsProbe: (command) async {
          probes++;
          return <String>['m1'];
        },
      );
      await Future.wait(<Future<Object?>>[registry.list(), registry.list()]);
      await registry.list();
      expect(probes, 1, reason: 'concurrent lists share one probe');
    });

    test('unavailable providers are not probed', () async {
      var probes = 0;
      final registry = ProviderRegistry(
        configOverrides: <String, Object?>{
          'providers': <String, Object?>{
            'omp': <String, Object?>{
              'name': 'OMP',
              'command': <String>['definitely-not-a-real-binary-xyz-9876'],
            },
          },
        },
        modelsProbe: (command) async {
          probes++;
          return <String>['m1'];
        },
      );
      final omp = (await registry.list()).firstWhere((p) => p.id == 'omp');
      expect(omp.available, isFalse);
      expect(omp.models, isEmpty);
      expect(probes, 0);
    });
  });
}
