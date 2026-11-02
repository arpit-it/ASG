# SPDX-License-Identifier: MPL-2.0
# Copyright 2026 Arpit Sinha
"""CLI refusal regressions only; these tests never claim live inference."""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).with_name('live_mlx_profile.py')


class ProbeRefusalTest(unittest.TestCase):
    def invoke(self, folder, *extra, optimized=False):
        output = Path(folder) / 'report.json'
        args = [sys.executable, '-B'] + (['-O'] if optimized else [])
        return subprocess.run(args + [str(SCRIPT), '--origin', 'http://127.0.0.1:1',
            '--model', 'synthetic', '--checkpoint', str(Path(folder) / 'PRIVATE-CHECKPOINT'),
            '--source-revision', 'a' * 40, '--output', str(output), *extra],
            capture_output=True, timeout=5), output

    def test_explicit_live_consent_required(self):
        with tempfile.TemporaryDirectory() as folder:
            result, output = self.invoke(folder)
            self.assertEqual(result.returncode, 2)
            self.assertFalse(output.exists())

    def test_existing_report_preserved_before_any_request(self):
        with tempfile.TemporaryDirectory() as folder:
            output = Path(folder) / 'report.json'
            output.write_text('retained evidence')
            result, _ = self.invoke(folder, '--confirm-live')
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(output.read_text(), 'retained evidence')

    def test_nonlocal_or_credentialed_origins_rejected(self):
        for origin in ('https://127.0.0.1:1', 'http://example.com',
                       'http://user:secret@127.0.0.1', 'http://127.0.0.1/private',
                       'http://127.0.0.1?private=1'):
            with self.subTest(origin=origin), tempfile.TemporaryDirectory() as folder:
                result, output = self.invoke(folder, '--confirm-live', '--origin', origin)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(output.exists())
                self.assertNotIn(b'secret', result.stderr)

    def test_failure_has_no_private_diagnostics(self):
        with tempfile.TemporaryDirectory() as folder:
            result, output = self.invoke(folder, '--confirm-live')
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(output.exists())
            self.assertNotIn(folder.encode(), result.stderr)
            self.assertNotIn(b'Traceback', result.stderr)
            self.assertNotIn(b'PRIVATE-CHECKPOINT', result.stderr)

    def test_optimized_python_cannot_disable_acceptance_checks(self):
        with tempfile.TemporaryDirectory() as folder:
            result, output = self.invoke(folder, '--confirm-live', optimized=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(output.exists())




class ProbeDeadlineTest(unittest.TestCase):
    def test_absolute_deadline_interrupts_headers_json_and_sse(self):
        import json
        import time
        from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
        from threading import Thread
        for stage in ('headers', 'json', 'structured-sse', 'disconnect-sse'):
            with self.subTest(stage=stage), tempfile.TemporaryDirectory() as folder:
                seen = []
                class Handler(BaseHTTPRequestHandler):
                    def log_message(self, *_):
                        pass

                    def drip(self, prefix):
                        self.wfile.write(prefix)
                        self.wfile.flush()
                        for _ in range(400):
                            self.wfile.write(b' ')
                            self.wfile.flush()
                            time.sleep(.01)

                    def respond(self, value):
                        body = json.dumps(value).encode()
                        self.send_response(200)
                        self.send_header('Content-Length', str(len(body)))
                        self.end_headers()
                        self.wfile.write(body)

                    def do_GET(self):
                        seen.append(self.path)
                        try:
                            if stage == 'headers':
                                self.drip(b'HTTP/1.0 200 OK\r\nX-Drip: ')
                            elif stage == 'json':
                                self.send_response(200)
                                self.end_headers()
                                self.drip(b'{')
                            elif self.path == '/health':
                                self.respond({'backend': 'mlx', 'device': 'metal',
                                    'phase': 'idle', 'model': 'synthetic'})
                            else:
                                self.respond({'data': [{'id': 'synthetic', 'asg_request_limits': {
                                    'schema_version': 1, 'max_input_tokens': 4096,
                                    'max_output_tokens': 4096, 'checkpoint_context_tokens': None}}]})
                        except OSError:
                            pass

                    def do_POST(self):
                        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
                        seen.append('stream' if body['stream'] else 'json-request')
                        metric = {'finish_reason': 'stop', 'prompt_tokens': 20,
                            'completion_tokens': 2, 'tokens_per_second': 10,
                            'peak_memory_gb': 5}
                        try:
                            if not body['stream']:
                                self.respond({'choices': [{'finish_reason': 'stop',
                                    'message': {'content': 'READY'}}], 'metrics': metric})
                                return
                            self.send_response(200)
                            self.end_headers()
                            if stage == 'structured-sse' or body['max_tokens'] == 4096:
                                self.drip(b'data: {')
                            else:
                                for part in ('{ "status": "ready",', '"count": 3 }'):
                                    event = {'choices': [{'delta': {'content': part}}]}
                                    self.wfile.write(b'data: ' + json.dumps(event).encode() + b'\n\n')
                                self.wfile.write(b'data: ' + json.dumps({'metrics': metric}).encode() + b'\n\ndata: [DONE]\n\n')
                        except OSError:
                            pass

                server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
                worker = Thread(target=server.serve_forever, daemon=True)
                worker.start()
                try:
                    checkpoint = Path(folder) / 'checkpoint'
                    checkpoint.mkdir()
                    for name in ('config.json', 'tokenizer_config.json',
                                 'model.safetensors.index.json', 'weights.safetensors'):
                        (checkpoint / name).write_text('{}')
                    output = Path(folder) / 'report.json'
                    wrapper = ('import importlib.metadata,runpy,sys; '
                        'importlib.metadata.version=lambda _: "fixture-only"; '
                        'sys.argv=sys.argv[1:];runpy.run_path(sys.argv[0],run_name="__main__")')
                    started = time.monotonic()
                    result = subprocess.run([sys.executable, '-B', '-c', wrapper, str(SCRIPT),
                        '--origin', 'http://127.0.0.1:' + str(server.server_port),
                        '--checkpoint', str(checkpoint), '--model', 'synthetic',
                        '--source-revision', 'a' * 40, '--output', str(output),
                        '--operation-timeout', '.25', '--confirm-live'],
                        capture_output=True, timeout=2)
                    self.assertLess(time.monotonic() - started, 2)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertFalse(output.exists())
                    self.assertNotIn(b'Traceback', result.stderr)
                    if stage == 'structured-sse':
                        self.assertEqual(seen.count('stream'), 1)
                    if stage == 'disconnect-sse':
                        self.assertEqual(seen.count('stream'), 2)
                finally:
                    server.shutdown()
                    server.server_close()
                    worker.join(timeout=1)


if __name__ == '__main__':
    unittest.main()
