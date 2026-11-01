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
    device = 'fixture-device'
    def __init__(self):
        self.tokens = None
    def generate(self, messages, tokens, publish, cancelled, deadline):
        self.tokens = tokens
        if messages[0]['content'] == 'error':
            raise ValueError('Invalid fixture prompt')
        publish('token', 'Hello ')
        publish('token', 'world')
        return {'finish_reason':'stop'}

class ServerTests(unittest.TestCase):
    def setUp(self):
        self.executor = ThreadPoolExecutor(max_workers=1)
        self.backend = FakeBackend()
        self.server = ThreadingHTTPServer(('127.0.0.1', 0), module.create_handler(self.backend, self.executor, 'fixture', Path('/fixture')))
        self.server.daemon_threads = True
        self.thread = Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.url = f'http://127.0.0.1:{self.server.server_port}'
    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.executor.shutdown()
    def request(self, streaming=True, content='hello', **options):
        body=json.dumps({'model':'fixture','messages':[{'role':'user','content':content}], 'stream':streaming, **options}).encode()
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
            health = json.load(response)
            self.assertTrue(health['streaming'])
            self.assertEqual(health['device'], 'fixture-device')
    def test_errors_are_not_successful_completions(self):
        with self.request(content='error') as response:
            text=response.read().decode()
        self.assertIn('event: error', text)
        self.assertNotIn('[DONE]', text)
        self.assertIn('Invalid fixture prompt', text)
    def test_remote_origins_are_rejected(self):
        request = urllib.request.Request(self.url+'/v1/chat/completions', data=b'{}', headers={'Content-Type':'application/json','Origin':'https://example.com'})
        with self.assertRaises(urllib.error.HTTPError) as error:
            urllib.request.urlopen(request)
        self.assertEqual(error.exception.code,403)
    def test_source_proposal_budget_and_bounded_chat_limits(self):
        for streaming in (True, False):
            for requested, expected in ((4096, 4096), (9000, 4096),
                                        (1536, 1536), (2048, 2048), (0, 1)):
                with self.subTest(streaming=streaming, requested=requested):
                    with self.request(streaming, max_tokens=requested) as response:
                        response.read()
                    self.assertEqual(self.backend.tokens, expected)
            with self.request(streaming) as response:
                response.read()
            self.assertEqual(self.backend.tokens, 256)
    def test_invalid_token_budget_is_rejected_before_inference(self):
        with self.assertRaises(urllib.error.HTTPError) as error:
            self.request(max_tokens='invalid')
        self.assertEqual(error.exception.code, 400)
        self.assertIsNone(self.backend.tokens)

    def test_real_executor_thread_start_failure_discards_queued_legacy_request(self):
        from unittest.mock import patch
        for streaming in (True, False):
            with self.subTest(streaming=streaming):
                # Real submit enqueues before _adjust_thread_count; the next
                # successful request must safely drain that abandoned work.
                with patch.object(self.executor, '_adjust_thread_count', side_effect=RuntimeError('PRIVATE_THREAD_PATH')), patch.object(self.backend, 'generate', wraps=self.backend.generate) as generate:
                    with self.assertRaises(urllib.error.HTTPError) as error:
                        self.request(streaming)
                    self.assertEqual(error.exception.code, 503)
                    self.assertNotIn('PRIVATE', error.exception.read().decode())
                    error.exception.close()
                    generate.assert_not_called()
                with patch.object(self.backend, 'generate', wraps=self.backend.generate) as generate:
                    with self.request(streaming) as response:
                        self.assertIn('Hello ', response.read().decode())
                    self.executor.submit(lambda: None).result(timeout=3)
                    self.assertEqual(generate.call_count, 1)
                with urllib.request.urlopen(self.url+'/health', timeout=5) as response:
                    self.assertEqual(json.load(response)['phase'], 'idle')

class CPUHTTPTests(unittest.TestCase):
    """Actual sockets and backend code; injected tensor APIs are not live inference."""
    def setUp(self):
        from test_qwen_backends import CPUBackendTests
        self.fixture = CPUBackendTests()
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        self.executor = ThreadPoolExecutor(max_workers=1)
        self.server = ThreadingHTTPServer(('127.0.0.1', 0), module.create_handler(
            self.fixture.backend, self.executor, 'cpu-fixture', Path('/local model with spaces')))
        self.server.daemon_threads = True
        self.thread = Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.url = f'http://127.0.0.1:{self.server.server_port}'

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.executor.shutdown()
        self.thread.join(timeout=2)

    def request(self, streaming=True, raw_budget=None):
        body = json.dumps({'model': 'cpu-fixture', 'messages': [{'role': 'user', 'content': 'fixture'}], 'stream': streaming, 'max_tokens': 2}).encode()
        if raw_budget is not None:
            body = body.replace(b'"max_tokens": 2', b'"max_tokens": ' + raw_budget.encode())
        return urllib.request.urlopen(urllib.request.Request(self.url+'/v1/chat/completions', data=body, headers={'Content-Type': 'application/json'}), timeout=5)

    def test_dispatch_failure_is_private_idle_and_retryable_before_sse(self):
        from unittest.mock import patch
        original_submit = self.executor.submit
        for streaming in (True, False):
            for enqueue, failure in ((False, RuntimeError('PRIVATE_DISPATCH_PATH')),
                                     (False, MemoryError('PRIVATE_DISPATCH_PROMPT')),
                                     (True, RuntimeError('PRIVATE_THREAD_START'))):
                with self.subTest(streaming=streaming, failure=type(failure).__name__, enqueue=enqueue):
                    self.fixture.tokenizer.apply_chat_template.reset_mock()
                    self.fixture.model.generate.reset_mock()
                    queued = []
                    def reject(work):
                        if enqueue:
                            queued.append(original_submit(work))
                        raise failure
                    with patch.object(self.executor, 'submit', side_effect=reject), patch.object(self.server, 'handle_error') as handler_error:
                        with self.assertRaises(urllib.error.HTTPError) as error:
                            self.request(streaming)
                        self.assertEqual(error.exception.code, 503)
                        self.assertEqual(error.exception.headers['Content-Type'], 'application/json')
                        self.assertEqual(json.load(error.exception), {'error': 'Generation worker unavailable; retry the request or restart the local runtime'})
                        error.exception.close()
                        handler_error.assert_not_called()
                    for future in queued:
                        future.result(timeout=3)
                    self.fixture.tokenizer.apply_chat_template.assert_not_called()
                    self.fixture.model.generate.assert_not_called()
                    with urllib.request.urlopen(self.url+'/health', timeout=5) as response:
                        self.assertEqual(json.load(response)['phase'], 'idle')
                    with self.request(streaming) as response:
                        result = response.read().decode()
                    if streaming:
                        self.assertIn('[DONE]', result)
                    else:
                        self.assertEqual(json.loads(result)['choices'][0]['finish_reason'], 'stop')

    def test_ambiguous_cpu_request_framing_rejects_before_inference_and_allows_retry(self):
        import http.client
        import socket
        from unittest.mock import patch
        for streaming in (True, False):
            body = json.dumps({'model': 'cpu-fixture', 'messages': [
                {'role': 'user', 'content': 'PRIVATE_PROMPT'}], 'stream': streaming}).encode()
            length = b'Content-Length: ' + str(len(body)).encode() + b'\r\n'
            for headers in (length + length, length + b'Content-Length: 1\r\n',
                            b'Content-Length: 1\r\n' + length,
                            length + b'Transfer-Encoding: chunked\r\n',
                            length + b'Transfer-Encoding: identity\r\n',
                            length + b'Transfer-Encoding:\r\n',
                            b'Transfer-Encoding: chunked\r\n'):
                with self.subTest(streaming=streaming, headers=headers):
                    self.fixture.tokenizer.apply_chat_template.reset_mock()
                    self.fixture.model.generate.reset_mock()
                    with patch.object(self.server, 'handle_error') as handler_error:
                        with socket.create_connection(self.server.server_address, timeout=5) as connection:
                            connection.sendall(
                                b'POST /v1/chat/completions HTTP/1.1\r\nHost: localhost\r\n'
                                b'Content-Type: application/json\r\n' + headers + b'\r\n' + body)
                            response = http.client.HTTPResponse(connection)
                            response.begin()
                            self.assertEqual(response.status, 400)
                            self.assertEqual(json.load(response), {'error': 'Unsupported request framing; send one Content-Length and no Transfer-Encoding'})
                            response.close()
                        handler_error.assert_not_called()
                    self.fixture.tokenizer.apply_chat_template.assert_not_called()
                    self.fixture.model.generate.assert_not_called()
                    with urllib.request.urlopen(self.url+'/health', timeout=5) as response:
                        self.assertEqual(json.load(response)['phase'], 'idle')
                    with self.request(streaming) as response:
                        result = response.read().decode()
                    if streaming:
                        self.assertIn('[DONE]', result)
                    else:
                        self.assertEqual(json.loads(result)['choices'][0]['finish_reason'], 'stop')

    def test_unsupported_cpu_framing_does_not_wait_for_a_body(self):
        import http.client
        import socket
        for headers in (b'Content-Length: 100\r\nContent-Length: 100\r\n',
                        b'Content-Length: 100\r\nTransfer-Encoding: chunked\r\n'):
            with self.subTest(headers=headers):
                # Leave the write side open and send no body. Rejection must
                # precede the production 15-second body-read timeout.
                with socket.create_connection(self.server.server_address, timeout=2) as connection:
                    connection.sendall(b'POST /v1/chat/completions HTTP/1.1\r\nHost: localhost\r\n'
                        b'Content-Type: application/json\r\n' + headers + b'\r\n')
                    response = http.client.HTTPResponse(connection)
                    response.begin()
                    self.assertEqual(response.status, 400)
                    self.assertIn('Unsupported request framing', json.load(response)['error'])
                    response.close()
        self.fixture.tokenizer.apply_chat_template.assert_not_called()
        self.fixture.model.generate.assert_not_called()

    def test_nonfinite_cpu_token_budgets_fail_before_inference_and_allow_retry(self):
        for streaming in (True, False):
            for budget in ('Infinity', '-Infinity', 'NaN', '1e999', '-1e999'):
                with self.subTest(streaming=streaming, budget=budget):
                    self.fixture.tokenizer.apply_chat_template.reset_mock()
                    self.fixture.model.generate.reset_mock()
                    with self.assertRaises(urllib.error.HTTPError) as failure:
                        self.request(streaming, raw_budget=budget)
                    self.assertEqual(failure.exception.code, 400)
                    self.assertEqual(json.load(failure.exception),
                                     {'error': 'Invalid request or model ID'})
                    self.fixture.tokenizer.apply_chat_template.assert_not_called()
                    self.fixture.model.generate.assert_not_called()
                    with urllib.request.urlopen(self.url+'/health', timeout=5) as response:
                        self.assertEqual(json.load(response)['phase'], 'idle')
                    with self.request(streaming) as response:
                        body = response.read().decode()
                    if streaming:
                        self.assertIn('[DONE]', body)
                    else:
                        self.assertEqual(json.loads(body)['choices'][0]['finish_reason'], 'stop')

    def test_malformed_cpu_origins_reject_privately_and_allow_retry(self):
        from unittest.mock import patch
        for origin in ('http://[', 'http://[not-ipv6]'):
            for streaming in (True, False):
                with self.subTest(origin=origin, streaming=streaming):
                    self.fixture.tokenizer.apply_chat_template.reset_mock()
                    self.fixture.model.generate.reset_mock()
                    body = json.dumps({'model': 'cpu-fixture', 'messages': [
                        {'role': 'user', 'content': 'PRIVATE_PROMPT'}],
                        'stream': streaming}).encode()
                    # Exercise actual HTTP header parsing before backend work.
                    import http.client
                    import socket
                    with patch.object(self.server, 'handle_error') as handler_error:
                        for method in ('POST', 'OPTIONS', 'GET'):
                            route = '/health' if method == 'GET' else '/v1/chat/completions'
                            with socket.create_connection(self.server.server_address, timeout=5) as connection:
                                connection.sendall((method + ' ' + route + ' HTTP/1.1\r\nHost: localhost\r\n'
                                    'Content-Type: application/json\r\nOrigin: ' + origin +
                                    '\r\nContent-Length: ' + str(len(body)) + '\r\n\r\n').encode() + body)
                                response = http.client.HTTPResponse(connection)
                                response.begin()
                                self.assertEqual(response.status, 200 if method == 'GET' else 403)
                                self.assertIsNone(response.headers.get('Access-Control-Allow-Origin'))
                                result = json.load(response)
                                if method == 'POST':
                                    self.assertEqual(result, {'error': 'Local JSON requests only'})
                                elif method == 'OPTIONS':
                                    self.assertEqual(result, {})
                                else:
                                    self.assertEqual(result['phase'], 'idle')
                                response.close()
                        handler_error.assert_not_called()
                    self.fixture.tokenizer.apply_chat_template.assert_not_called()
                    self.fixture.model.generate.assert_not_called()
                    with self.request(streaming) as response:
                        result = response.read().decode()
                    if streaming:
                        self.assertIn('[DONE]', result)
                    else:
                        self.assertEqual(json.loads(result)['choices'][0]['finish_reason'], 'stop')

    def test_valid_cpu_local_origins_keep_cors_and_generation(self):
        for origin in ('http://localhost:8080', 'http://127.0.0.1:8080', 'http://[::1]:8080'):
            with self.subTest(origin=origin):
                body = json.dumps({'model': 'cpu-fixture', 'messages': [
                    {'role': 'user', 'content': 'fixture'}]}).encode()
                request = urllib.request.Request(self.url+'/v1/chat/completions', data=body,
                    headers={'Content-Type': 'application/json', 'Origin': origin})
                with urllib.request.urlopen(request, timeout=5) as response:
                    self.assertEqual(response.headers['Access-Control-Allow-Origin'], origin)
                    self.assertEqual(json.load(response)['choices'][0]['finish_reason'], 'stop')

    def test_incomplete_cpu_body_fails_before_inference_and_allows_retry(self):
        import http.client
        import socket
        for streaming in (True, False):
            valid = json.dumps({'model': 'cpu-fixture', 'messages': [
                {'role': 'user', 'content': 'PRIVATE_PROMPT'}],
                'stream': streaming}).encode()
            for body in (valid, valid[:-1], b''):
                with self.subTest(streaming=streaming, body_length=len(body)):
                    self.fixture.tokenizer.apply_chat_template.reset_mock()
                    self.fixture.model.generate.reset_mock()
                    with socket.create_connection(self.server.server_address, timeout=5) as connection:
                        connection.sendall(
                            b'POST /v1/chat/completions HTTP/1.1\r\nHost: localhost\r\n'
                            b'Content-Type: application/json\r\nContent-Length: ' +
                            str(len(valid) + 10).encode() + b'\r\n\r\n' + body)
                        # EOF ends the read immediately, even when the prefix is
                        # valid JSON. It must not start an unintended generation.
                        connection.shutdown(socket.SHUT_WR)
                        response = http.client.HTTPResponse(connection)
                        response.begin()
                        self.assertEqual(response.status, 400)
                        self.assertEqual(response.headers['Content-Type'], 'application/json')
                        self.assertEqual(json.load(response),
                                         {'error': 'Incomplete request body; send the complete JSON request and retry'})
                        response.close()
                    self.fixture.tokenizer.apply_chat_template.assert_not_called()
                    self.fixture.model.generate.assert_not_called()
                    with urllib.request.urlopen(self.url+'/health', timeout=5) as response:
                        self.assertEqual(json.load(response)['phase'], 'idle')
                    with self.request(streaming) as response:
                        result = response.read().decode()
                    if streaming:
                        self.assertIn('[DONE]', result)
                    else:
                        self.assertEqual(json.loads(result)['choices'][0]['finish_reason'], 'stop')

    def test_stalled_cpu_request_body_returns_timeout_before_inference_and_allows_retry(self):
        import http.client
        import socket
        from unittest.mock import patch
        original_timeout = socket.socket.settimeout

        def short_body_timeout(connection, seconds):
            # Exercise the real socket timeout without a 15-second test delay.
            return original_timeout(connection, 0.05 if seconds == 15 else seconds)

        for streaming in (True, False):
            with self.subTest(streaming=streaming):
                self.fixture.tokenizer.apply_chat_template.reset_mock()
                self.fixture.model.generate.reset_mock()
                partial = (b'{"model":"cpu-fixture","stream":' +
                           (b'true' if streaming else b'false') + b',"messages":[')
                with patch.object(socket.socket, 'settimeout', short_body_timeout):
                    with socket.create_connection(self.server.server_address, timeout=5) as connection:
                        connection.sendall(
                            b'POST /v1/chat/completions HTTP/1.1\r\nHost: localhost\r\n'
                            b'Content-Type: application/json\r\nContent-Length: 200\r\n\r\n' + partial)
                        response = http.client.HTTPResponse(connection)
                        response.begin()
                        self.assertEqual(response.status, 408)
                        self.assertEqual(response.headers['Content-Type'], 'application/json')
                        self.assertEqual(json.load(response),
                                         {'error': 'Request body timed out; send the complete JSON request and retry'})
                        response.close()
                self.fixture.tokenizer.apply_chat_template.assert_not_called()
                self.fixture.model.generate.assert_not_called()
                with urllib.request.urlopen(self.url+'/health', timeout=5) as response:
                    self.assertEqual(json.load(response)['phase'], 'idle')
                with self.request(streaming) as response:
                    result = response.read().decode()
                if streaming:
                    self.assertIn('[DONE]', result)
                else:
                    self.assertEqual(json.loads(result)['choices'][0]['finish_reason'], 'stop')

    def test_deep_cpu_json_fails_before_inference_and_allows_retry(self):
        for streaming in (True, False):
            for opening, closing in ((b'', b''), (b'{"nested":', b'}')):
                with self.subTest(streaming=streaming, container=opening):
                    self.fixture.tokenizer.apply_chat_template.reset_mock()
                    self.fixture.model.generate.reset_mock()
                    # Fit both shapes below the byte limit while exceeding the
                    # decoder recursion budget on supported Python versions.
                    nested = opening + b'[' * 12000 + b'0' + b']' * 12000 + closing
                    body = (b'{"model":"cpu-fixture","messages":[{"role":"user",'
                            b'"content":"fixture"}],"stream":' +
                            (b'true' if streaming else b'false') + b',"extra":' +
                            nested + b'}')
                    self.assertLessEqual(len(body), 32768)
                    request = urllib.request.Request(
                        self.url+'/v1/chat/completions', data=body,
                        headers={'Content-Type': 'application/json'})
                    with self.assertRaises(urllib.error.HTTPError) as failure:
                        urllib.request.urlopen(request, timeout=5)
                    self.assertEqual(failure.exception.code, 400)
                    self.assertEqual(json.load(failure.exception),
                                     {'error': 'Invalid request or model ID'})
                    self.fixture.tokenizer.apply_chat_template.assert_not_called()
                    self.fixture.model.generate.assert_not_called()
                    with urllib.request.urlopen(self.url+'/health', timeout=5) as response:
                        self.assertEqual(json.load(response)['phase'], 'idle')
                    with self.request(streaming) as response:
                        result = response.read().decode()
                    if streaming:
                        self.assertIn('[DONE]', result)
                    else:
                        self.assertEqual(json.loads(result)['choices'][0]['finish_reason'], 'stop')

    def test_cpu_health_sse_nonstream_and_reuse(self):
        with urllib.request.urlopen(self.url+'/health', timeout=5) as response:
            health = json.load(response)
        self.assertEqual((health['backend'], health['device'], health['phase']), ('torch', 'cpu', 'idle'))
        with self.request() as response:
            text = response.read().decode()
        self.assertIn('Hello ', text)
        self.assertIn('CPU', text)
        self.assertIn('[DONE]', text)
        self.assertIn('"finish_reason": "stop"', text)
        self.fixture.output_length = 5
        with self.request(False) as response:
            data = json.load(response)
        self.assertEqual(data['choices'][0]['message']['content'], 'Hello CPU')
        self.assertEqual(data['choices'][0]['finish_reason'], 'length')

    def test_cpu_errors_have_no_success_marker_and_allow_retry(self):
        self.fixture.model.generate.side_effect = RuntimeError('PRIVATE /model path')
        with self.request() as response:
            text = response.read().decode()
        self.assertIn('event: error', text)
        self.assertNotIn('[DONE]', text)
        self.assertNotIn('PRIVATE', text)
        self.fixture.model.generate.side_effect = lambda **kwargs: type('Output', (), {'shape': (1, 3)})()
        with self.request(False) as response:
            self.assertEqual(json.load(response)['choices'][0]['finish_reason'], 'stop')

    def test_cpu_failure_diagnostics_are_private_for_both_transports_and_retry(self):
        # Optional tensor/tokenizer errors may contain prompts, paths, newlines,
        # or even a dynamically named exception type. Never publish any of them.
        private = 'PRIVATE_PROMPT /secret/checkpoint\nevent: message\ndata: [DONE]'
        private_type = type('PRIVATE_EXCEPTION_TYPE', (RuntimeError,), {})
        for stage in ('tokenizer', 'model'):
            for error_type in (ValueError, TimeoutError, MemoryError, RuntimeError, private_type):
                for streaming in (True, False):
                    with self.subTest(stage=stage, error=error_type.__name__, streaming=streaming):
                        target = (self.fixture.tokenizer.apply_chat_template if stage == 'tokenizer'
                                  else self.fixture.model.generate)
                        original_effect = target.side_effect
                        target.side_effect = error_type(private)
                        if streaming:
                            with self.request() as response:
                                body = response.read().decode()
                            self.assertIn('event: error', body)
                            self.assertNotIn('[DONE]', body)
                            self.assertNotIn('finish_reason', body)
                        else:
                            with self.assertRaises(urllib.error.HTTPError) as failure:
                                self.request(False)
                            self.assertEqual(failure.exception.code, 500)
                            body = failure.exception.read().decode()
                            self.assertEqual(set(json.loads(body)), {'error'})
                        self.assertNotIn('PRIVATE', body)
                        self.assertNotIn('/secret', body)
                        expected = ('CPU generation ran out of memory; choose smaller compatible weights or free memory.'
                                    if error_type is MemoryError else
                                    'CPU generation timed out; reduce input or requested output and retry.'
                                    if error_type is TimeoutError else
                                    'CPU generation failed; check input length, compatible local weights, tokenizer and installed loader APIs, then retry.')
                        if streaming:
                            payload = next(line[6:] for line in body.splitlines() if line.startswith('data: {"error"'))
                            self.assertEqual(json.loads(payload), {'error': expected})
                        else:
                            self.assertEqual(json.loads(body), {'error': expected})
                        # An executor barrier also verifies the worker released its lock.
                        self.executor.submit(lambda: None).result(timeout=3)
                        with urllib.request.urlopen(self.url+'/health', timeout=5) as response:
                            self.assertEqual(json.load(response)['phase'], 'idle')
                        target.side_effect = original_effect
                        with self.request(False) as response:
                            self.assertEqual(json.load(response)['choices'][0]['finish_reason'], 'stop')

    def test_disconnect_stops_cpu_stream_and_releases_owned_worker(self):
        import socket
        import struct
        import time
        from threading import Event
        stopped = Event()
        def generate(**kwargs):
            try:
                for _ in range(1000):
                    kwargs['streamer'].on_finalized_text('cpu fixture ' * 100)
                    time.sleep(0.005)
                self.fail('Disconnected worker did not observe cancellation')
            finally:
                stopped.set()
        self.fixture.model.generate.side_effect = generate
        body = json.dumps({'model': 'cpu-fixture', 'messages': [{'role': 'user', 'content': 'fixture'}], 'stream': True}).encode()
        sock = socket.create_connection(('127.0.0.1', self.server.server_port), timeout=5)
        try:
            sock.sendall(b'POST /v1/chat/completions HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: ' + str(len(body)).encode() + b'\r\n\r\n' + body)
            received = b''
            while b'cpu fixture' not in received:
                received += sock.recv(8192)
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack('ii', 1, 0))
        finally:
            sock.close()
        self.assertTrue(stopped.wait(3), 'CPU backend did not stop after client disconnect')
        # Future completion proves cleanup/lock release without racing the worker.
        self.executor.submit(lambda: None).result(timeout=3)
        self.fixture.model.generate.side_effect = lambda **kwargs: type('Output', (), {'shape': (1, 3)})()
        with self.request(False) as response:
            self.assertEqual(response.status, 200)


if __name__ == '__main__':
    unittest.main()
