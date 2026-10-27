# SPDX-License-Identifier: MPL-2.0
# Copyright 2026 Arpit Sinha

"""Tests the actual HTTP/SSE handler with a lightweight backend, no weights."""
import importlib.util
import json
from concurrent.futures import ThreadPoolExecutor
from http.server import ThreadingHTTPServer
from pathlib import Path
from threading import Thread
import urllib.error
import urllib.request
import unittest

spec = importlib.util.spec_from_file_location('qwen_server', Path(__file__).with_name('qwen_server.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

class FakeBackend:
    kind = 'fixture'
    def generate(self, messages, tokens, publish, cancelled, deadline):
        if messages[0]['content'] == 'error':
            raise ValueError('Invalid fixture prompt')
        publish('token', 'Hello ')
        publish('token', 'world')
        return {'finish_reason':'stop'}

class ServerTests(unittest.TestCase):
    def setUp(self):
        self.executor = ThreadPoolExecutor(max_workers=1)
        self.server = ThreadingHTTPServer(('127.0.0.1', 0), module.create_handler(FakeBackend(), self.executor, 'fixture', Path('/fixture')))
        self.server.daemon_threads = True
        self.thread = Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.url = f'http://127.0.0.1:{self.server.server_port}'
    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.executor.shutdown()
    def request(self, streaming=True, content='hello'):
        body=json.dumps({'model':'fixture','messages':[{'role':'user','content':content}], 'stream':streaming}).encode()
        return urllib.request.urlopen(urllib.request.Request(self.url+'/v1/chat/completions', data=body, headers={'Content-Type':'application/json'}), timeout=5)
    def test_sse_status_tokens_and_done(self):
        with self.request() as response:
            text=response.read().decode()
        self.assertIn('text/event-stream', response.headers['Content-Type'])
        self.assertIn('"phase": "thinking"', text)
        self.assertIn('"phase": "writing"', text)
        self.assertIn('Hello ', text)
        self.assertIn('[DONE]', text)
    def test_nonstream_compatibility_and_health(self):
        with self.request(False) as response:
            data=json.load(response)
        self.assertEqual(data['choices'][0]['message']['content'], 'Hello world')
        with urllib.request.urlopen(self.url+'/health') as response:
            self.assertTrue(json.load(response)['streaming'])
    def test_errors_are_not_successful_completions(self):
        with self.request(content='error') as response:
            text=response.read().decode()
        self.assertIn('event: error', text)
        self.assertNotIn('[DONE]', text)
    def test_remote_origins_are_rejected(self):
        request = urllib.request.Request(self.url+'/v1/chat/completions', data=b'{}', headers={'Content-Type':'application/json','Origin':'https://example.com'})
        with self.assertRaises(urllib.error.HTTPError) as error:
            urllib.request.urlopen(request)
        self.assertEqual(error.exception.code,403)

if __name__ == '__main__':
    unittest.main()
