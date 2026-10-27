#!/usr/bin/env python3
"""Build release downloads and serve their live status using only the stdlib."""
import concurrent.futures
import datetime
import json
import os
from pathlib import Path
import select
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer

ARTIFACTS = {
    'speeddial.apk': 'Android',
    'speeddial-wear.apk': 'Wear OS',
    'speeddial-linux.tar.gz': 'Linux (x64)',
    'speeddial-daemon-linux-x64.tar.gz': 'Daemon (Linux x64)',
}


def timestamp(seconds=None):
    return datetime.datetime.fromtimestamp(
        seconds if seconds is not None else time.time(),
        datetime.timezone.utc).isoformat()


class BuildServer:
    def __init__(self, repo, downloads):
        self.repo = Path(repo)
        self.downloads = Path(downloads)
        self.lock = threading.RLock()
        self.state = {'status': 'idle', 'commit': None, 'startedAt': None,
                      'finishedAt': None, 'error': None}
        self.stopping = threading.Event()
        self.processes = set()
        self.last_commit = None

    def head(self):
        return subprocess.check_output(
            ['git', '-C', str(self.repo), 'rev-parse', 'HEAD'], text=True).strip()

    def snapshot(self):
        with self.lock:
            result = dict(self.state)
            result['artifacts'] = []
            for name, label in ARTIFACTS.items():
                path = self.downloads / name
                stat = path.stat() if path.is_file() else None
                result['artifacts'].append({
                    'name': name, 'label': label,
                    'size': stat.st_size if stat else None,
                    'builtAt': timestamp(stat.st_mtime) if stat else None,
                })
            return result

    def run(self, args, cwd):
        with self.lock:
            if self.stopping.is_set():
                raise RuntimeError('Build stopped')
            process = subprocess.Popen(args, cwd=cwd, start_new_session=True)
            self.processes.add(process)
        try:
            if process.wait() != 0:
                raise RuntimeError(f'{" ".join(args)} failed')
        finally:
            with self.lock:
                self.processes.discard(process)

    def build(self, commit):
        with self.lock:
            self.state.update(status='building', commit=commit,
                              startedAt=timestamp(), finishedAt=None, error=None)
        print(f'Building {commit}', flush=True)
        try:
            # All outputs are prepared on the destination filesystem. Downloads
            # remain intact until every build and packaging operation succeeds.
            with tempfile.TemporaryDirectory(prefix='.build-', dir=self.downloads) as temp:
                stage = Path(temp)

                def app():
                    cwd = self.repo / 'packages/app'
                    self.run(['flutter', 'build', 'apk', '--release'], cwd)
                    self.run(['python3', str(self.repo / 'scripts/check_android_jni.py'),
                              'build/app/outputs/mapping/release/mapping.txt'], cwd)
                    shutil.copyfile(cwd / 'build/app/outputs/flutter-apk/app-release.apk', stage / 'speeddial.apk')
                    self.run(['flutter', 'build', 'linux', '--release'], cwd)
                    self.run(['tar', '-czf', str(stage / 'speeddial-linux.tar.gz'),
                              '-C', 'build/linux/x64/release', 'bundle'], cwd)

                def wear():
                    cwd = self.repo / 'packages/wear'
                    self.run(['flutter', 'pub', 'get'], cwd)
                    self.run(['flutter', 'build', 'apk', '--release'], cwd)
                    self.run(['python3', str(self.repo / 'scripts/check_android_jni.py'),
                              'build/app/outputs/mapping/release/mapping.txt'], cwd)
                    shutil.copyfile(cwd / 'build/app/outputs/flutter-apk/app-release.apk', stage / 'speeddial-wear.apk')

                def daemon():
                    cwd = self.repo / 'packages/daemon'
                    output = stage / 'daemon'
                    self.run(['dart', 'build', 'cli', '-t', 'bin/speeddial.dart', '-o', str(output)], cwd)
                    self.run(['tar', '-czf', str(stage / 'speeddial-daemon-linux-x64.tar.gz'),
                              '-C', str(output), 'bundle'], cwd)

                with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
                    futures = [pool.submit(job) for job in (app, wear, daemon)]
                    for future in futures:
                        future.result()
                with self.lock:
                    for name in ARTIFACTS:
                        os.utime(stage / name, None)
                        os.replace(stage / name, self.downloads / name)
            with self.lock:
                self.state.update(status='idle', finishedAt=timestamp())
        except Exception as error:
            print(f'Build failed: {error}', file=sys.stderr, flush=True)
            with self.lock:
                self.state.update(status='failed', finishedAt=timestamp(), error=str(error))

    def check(self, manual=False):
        commit = self.head()
        if manual or commit != self.last_commit:
            self.last_commit = commit  # Failed builds retry on Enter or a new HEAD.
            self.build(commit)

    def stop(self):
        self.stopping.set()
        with self.lock:
            for process in self.processes:
                try:
                    os.killpg(process.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass


def handler_for(builder):
    class Handler(SimpleHTTPRequestHandler):
        def __init__(self, *args, **kwargs):
            super().__init__(*args, directory=str(builder.downloads), **kwargs)

        def end_headers(self):
            self.send_header('Cache-Control', 'no-store')
            super().end_headers()

        def do_GET(self):
            path = self.path.split('?', 1)[0]
            if path == '/status.json':
                body = json.dumps(builder.snapshot()).encode()
                content_type = 'application/json'
            elif path in ('/', '/index.html'):
                body = Path(__file__).with_name('downloads.html').read_bytes()
                content_type = 'text/html; charset=utf-8'
            elif path.lstrip('/') in ARTIFACTS:
                return super().do_GET()
            else:
                self.send_error(404)
                return
            self.send_response(200)
            self.send_header('Content-Type', content_type)
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_HEAD(self):
            if self.path.split('?', 1)[0].lstrip('/') in ARTIFACTS:
                super().do_HEAD()
            else:
                self.send_error(404)
    return Handler


def main():
    repo = Path(__file__).resolve().parent.parent
    downloads = Path(os.environ.get('DOWNLOAD_DIR', '~/speeddial-download')).expanduser().resolve()
    downloads.mkdir(parents=True, exist_ok=True)
    builder = BuildServer(repo, downloads)
    server = ThreadingHTTPServer(('0.0.0.0', int(sys.argv[1] if len(sys.argv) > 1 else os.environ.get('PORT', '8777'))), handler_for(builder))
    for sig in (signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, lambda *_: builder.stop())
    threading.Thread(target=server.serve_forever, daemon=True).start()
    print(f'Serving http://0.0.0.0:{server.server_port}/; watching HEAD every 2s. Enter=rebuild, q=quit', flush=True)
    stdin = sys.stdin
    try:
        while not builder.stopping.is_set():
            manual = False
            if stdin and select.select([stdin], [], [], 0)[0]:
                line = stdin.readline()
                if not line:
                    stdin = None  # Detached services keep watching after EOF.
                elif line.strip() in ('q', 'quit'):
                    break
                else:
                    manual = True
            try:
                builder.check(manual)
            except subprocess.CalledProcessError as error:
                print(f'Cannot read HEAD: {error}', file=sys.stderr, flush=True)
            builder.stopping.wait(2)
    finally:
        builder.stop()
        server.shutdown()
        server.server_close()


if __name__ == '__main__':
    main()
