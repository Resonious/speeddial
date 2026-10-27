import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from build_server import BuildServer, ARTIFACTS


class BuildServerTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.server = BuildServer(self.root, self.root)

    def test_head_changes_and_manual_retry(self):
        with patch.object(self.server, 'head', side_effect=['a', 'a', 'b', 'b']), patch.object(self.server, 'build') as build:
            for manual in (False, False, False, True):
                self.server.check(manual)
            self.assertEqual([call.args[0] for call in build.call_args_list], ['a', 'b', 'b'])

    def test_metadata_uses_actual_bytes_and_each_files_timestamp(self):
        (self.root / 'speeddial.apk').write_bytes(b'x' * 1234)
        import os
        os.utime(self.root / 'speeddial.apk', (1000, 1000))
        artifacts = self.server.snapshot()['artifacts']
        self.assertEqual(artifacts[0]['size'], 1234)
        self.assertEqual(artifacts[0]['builtAt'], '1970-01-01T00:16:40+00:00')
        self.assertIsNone(artifacts[1]['size'])

    def test_failed_build_keeps_downloads_and_reports_error(self):
        for name in ARTIFACTS:
            (self.root / name).write_bytes(b'previous')
        with patch.object(self.server, 'run', side_effect=RuntimeError('compiler failed')):
            self.server.build('abc')
        self.assertEqual(self.server.snapshot()['status'], 'failed')
        self.assertIn('compiler failed', self.server.snapshot()['error'])
        for name in ARTIFACTS:
            self.assertEqual((self.root / name).read_bytes(), b'previous')
        self.assertEqual(len(list(self.root.iterdir())), len(ARTIFACTS))

    def test_success_publishes_all_artifacts_after_building(self):
        for package in ('app', 'wear'):
            apk = self.root / f'packages/{package}/build/app/outputs/flutter-apk/app-release.apk'
            apk.parent.mkdir(parents=True)
            apk.write_bytes(b'new apk')
        for name in ARTIFACTS:
            (self.root / name).write_bytes(b'old')

        def fake_run(args, cwd):
            self.assertEqual(self.server.snapshot()['status'], 'building')
            for name in ARTIFACTS:
                self.assertEqual((self.root / name).read_bytes(), b'old')
            if args[0] == 'tar':
                Path(args[2]).write_bytes(b'new archive')

        with patch.object(self.server, 'run', side_effect=fake_run):
            self.server.build('abc')
        self.assertEqual(self.server.snapshot()['status'], 'idle')
        for name in ARTIFACTS:
            self.assertTrue((self.root / name).read_bytes().startswith(b'new'))

    def test_new_head_during_build_is_built_next(self):
        with patch.object(self.server, 'head', side_effect=['old', 'new']), patch.object(self.server, 'build') as build:
            self.server.check()
            self.server.check()
            self.assertEqual([call.args[0] for call in build.call_args_list], ['old', 'new'])


if __name__ == '__main__':
    unittest.main()
