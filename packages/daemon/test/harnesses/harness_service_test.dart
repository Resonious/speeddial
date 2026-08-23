@TestOn('vm')
library;

import 'dart:io';

import 'package:speeddial_daemon/src/harnesses/harness_service.dart';
import 'package:speeddial_protocol/speeddial_protocol.dart';
import 'package:test/test.dart';

void main() {
  test(
    'lists only installed supported harnesses with probed versions',
    () async {
      final List<String> invocations = <String>[];
      final HarnessService service = HarnessService(
        environmentProvider: () => const <String, String>{
          'SPEEDIAL_TEST_TOKEN': 'managed',
        },
        executableResolver: (
          String executable,
          Map<String, String> environment,
        ) => executable != 'claude',
        processRunner:
            (
              String executable,
              List<String> arguments, {
              required Map<String, String> environment,
            }) async {
              expect(environment['SPEEDIAL_TEST_TOKEN'], 'managed');
              invocations.add('$executable ${arguments.join(' ')}');
              return ProcessResult(
                1,
                0,
                '$executable version 1.2.3\nextra output',
                '',
              );
            },
      );

      final List<HarnessInfo> harnesses = await service.list();

      expect(harnesses.map((HarnessInfo value) => value.id), <String>[
        'omp',
        'codex',
        'ante',
      ]);
      expect(harnesses.map((HarnessInfo value) => value.version), <String>[
        'omp version 1.2.3',
        'codex version 1.2.3',
        'ante version 1.2.3',
      ]);
      expect(invocations, <String>[
        'omp --version',
        'codex --version',
        'ante --version',
      ]);
    },
  );

  test('updates with the native command and reprobes the version', () async {
    String version = '1.0.0';
    final List<String> invocations = <String>[];
    final HarnessService service = HarnessService(
      executableResolver: (
        String executable,
        Map<String, String> environment,
      ) => true,
      processRunner:
          (
            String executable,
            List<String> arguments, {
            required Map<String, String> environment,
          }) async {
            invocations.add('$executable ${arguments.join(' ')}');
            if (arguments.single == 'update') version = '2.0.0';
            return ProcessResult(1, 0, '$executable $version', '');
          },
    );

    final HarnessInfo updated = await service.update('codex');

    expect(updated.version, 'codex 2.0.0');
    expect(invocations, <String>['codex update', 'codex --version']);
  });

  test('reports unknown, unavailable, and failed updates', () async {
    final HarnessService unavailable = HarnessService(
      executableResolver: (
        String executable,
        Map<String, String> environment,
      ) => false,
    );
    await expectLater(
      unavailable.update('missing'),
      throwsA(isA<DaemonError>().having((e) => e.code, 'code', kErrNotFound)),
    );
    await expectLater(
      unavailable.update('ante'),
      throwsA(
        isA<DaemonError>().having(
          (e) => e.code,
          'code',
          kErrProviderUnavailable,
        ),
      ),
    );

    final HarnessService failed = HarnessService(
      executableResolver: (
        String executable,
        Map<String, String> environment,
      ) => true,
      processRunner: (
        String executable,
        List<String> arguments, {
        required Map<String, String> environment,
      }) async => ProcessResult(1, 17, '', 'update refused'),
    );
    await expectLater(
      failed.update('omp'),
      throwsA(
        isA<DaemonError>()
            .having((e) => e.code, 'code', kErrAgentProcess)
            .having((e) => e.message, 'message', contains('update refused')),
      ),
    );
  });
}
