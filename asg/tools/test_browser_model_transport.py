# SPDX-License-Identifier: MPL-2.0
# Copyright 2026 Arpit Sinha
"""Run production BrowserClient against disposable, loopback-only HTTP fixtures.

No model is loaded. The servers accept only the fixed public test payload.
"""
import json
import os
import signal
from pathlib import Path
import subprocess
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


PROMPT = 'Disposable browser transport probe'
MODEL = 'browser-selected'
CODES = (301, 302, 303, 307, 308)


def main():
    lock = threading.Lock()
    counts = {str(code): 0 for code in CODES} | {'json': 0, 'sse': 0, 'target': 0}
    failures = []

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def send(self, status, body=b'', content_type='application/json', location=None):
            self.send_response(status)
            self.send_header('Access-Control-Allow-Origin', '*')
            self.send_header('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
            self.send_header('Access-Control-Allow-Headers', 'Content-Type')
            self.send_header('Content-Type', content_type)
            self.send_header('Content-Length', str(len(body)))
            if location:
                self.send_header('Location', location)
            self.end_headers()
            self.wfile.write(body)

        def do_OPTIONS(self):
            self.send(204)

        def do_GET(self):
            if self.server is target:
                with lock:
                    counts['target'] += 1
                self.send(200, b'{"choices":[{"message":{"content":"Wrong source"}}]}')
            elif self.path == '/stats':
                with lock:
                    body = json.dumps({'counts': counts, 'failures': failures}).encode()
                self.send(200, body)
            else:
                self.send(404)

        def do_POST(self):
            if self.server is target:
                with lock:
                    counts['target'] += 1
                self.send(200, b'{"choices":[{"message":{"content":"Wrong source"}}]}')
                return
            try:
                length = int(self.headers.get('Content-Length', '0'))
                if not 0 < length <= 4096:
                    raise ValueError()
                body = json.loads(self.rfile.read(length))
                if body != {'model': MODEL, 'messages': [{'role': 'user', 'content': PROMPT}],
                            'stream': True, 'max_tokens': 256, 'temperature': 0.2}:
                    raise ValueError()
                parts = self.path.strip('/').split('/')
                if len(parts) != 4 or parts[1:] != ['v1', 'chat', 'completions']:
                    raise ValueError()
                key = parts[0]
                if key not in counts or key == 'target':
                    raise ValueError()
                with lock:
                    counts[key] += 1
                if key in ('json', 'sse'):
                    if key == 'json':
                        self.send(200, b'{"model":"browser-selected","choices":[{"message":{"content":"Ready"}}]}')
                    else:
                        self.send(200, b'data: {"model":"browser-selected","choices":[{"delta":{"content":"Stream ready"}}]}\n\ndata: [DONE]\n\n', 'text/event-stream')
                else:
                    self.send(int(key), location=f'http://127.0.0.1:{target.server_port}/private-target')
            except (ValueError, TypeError, KeyError):
                with lock:
                    failures.append('Invalid fixture request')
                self.send(400)

    source = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    target = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    threads = []
    try:
        for server in (source, target):
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            threads.append(thread)
        command = ['flutter', 'test', '--no-pub', '--platform', 'chrome',
                   'test/browser_model_transport_test.dart',
                   f'--dart-define=ASG_BROWSER_TRANSPORT_PORT={source.server_port}']
        process = subprocess.Popen(command, cwd=Path(__file__).resolve().parents[1],
                                   start_new_session=True)
        try:
            result = process.wait(timeout=180)
        finally:
            # Confine cleanup to this disposable test process group. Never kill
            # a pre-existing browser, model server or installed application.
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait(timeout=5)
        if result:
            raise SystemExit(result)
        expected = {str(code): 1 for code in CODES} | {'json': 2, 'sse': 1, 'target': 0}
        with lock:
            if failures or counts != expected:
                raise SystemExit('Browser fixture did not observe the exact required HTTP requests.')
        print('Actual Chrome: five redirects refused, zero target requests, JSON/SSE retries passed.')
    finally:
        for server in (source, target):
            server.shutdown()
            server.server_close()
        for thread in threads:
            thread.join(timeout=2)


if __name__ == '__main__':
    main()
