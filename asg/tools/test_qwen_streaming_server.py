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
        self.finish_reason = 'stop'
    def generate(self, messages, tokens, publish, cancelled, deadline):
        self.tokens = tokens
        if messages[0]['content'] == 'error':
            raise ValueError('Invalid fixture prompt')
        publish('token', 'Hello ')
        publish('token', 'world')
        return {'finish_reason': self.finish_reason}

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

    def test_sse_terminal_event_reports_exact_model_for_stop_and_length(self):
        for reason in ('stop', 'length'):
            self.backend.finish_reason = reason
            with self.subTest(reason=reason), self.request() as response:
                data = [line[6:] for line in response.read().decode().splitlines()
                        if line.startswith('data: ')]
                self.assertEqual(data[-1], '[DONE]')
                self.assertEqual(json.loads(data[-2]), {
                    'model': 'fixture',
                    'choices': [{'delta': {}, 'finish_reason': reason}],
                    'metrics': {'finish_reason': reason},
                })
                self.assertTrue(all('model' not in json.loads(item) for item in data[:-2]))

    def test_stream_requires_a_boolean_when_present(self):
        for invalid in ('private fixture value', 'true', 1, None, [], {}):
            with self.subTest(stream=invalid):
                self.backend.tokens = None
                with self.assertRaises(urllib.error.HTTPError) as failure:
                    with self.request(streaming=invalid) as response:
                        response.read()
                with failure.exception as response:
                    self.assertEqual(response.code, 400)
                    self.assertEqual(response.headers.get_content_type(), 'application/json')
                    self.assertEqual(json.load(response), {'error': 'stream must be a boolean'})
                self.assertIsNone(self.backend.tokens)

    def test_health_reports_a_snapshot_of_both_bridge_source_hashes(self):
        import hashlib
        from unittest.mock import patch
        import qwen_backends

        expected = {
            'qwen_server.py': hashlib.sha256(Path(module.__file__).read_bytes()).hexdigest(),
            'qwen_backends.py': hashlib.sha256(Path(qwen_backends.__file__).read_bytes()).hexdigest(),
        }
        with patch.object(Path, 'open', side_effect=OSError('source no longer readable')):
            with urllib.request.urlopen(self.url + '/health', timeout=5) as response:
                health = json.load(response)
        self.assertEqual(health['bridge_source_sha256'], expected)
        self.assertEqual(health['status'], 'ready')

    def test_health_omits_source_hashes_when_a_file_cannot_be_observed(self):
        from unittest.mock import patch

        with patch.object(Path, 'open', side_effect=OSError('private fixture path')):
            handler = module.create_handler(self.backend, self.executor, 'fixture', Path('/fixture'))
        with ThreadingHTTPServer(('127.0.0.1', 0), handler) as server:
            thread = Thread(target=server.serve_forever, daemon=True)
            thread.start()
            try:
                with urllib.request.urlopen(f'http://127.0.0.1:{server.server_port}/health', timeout=5) as response:
                    health = json.load(response)
                self.assertEqual(health['status'], 'ready')
                self.assertNotIn('bridge_source_sha256', health)
                self.assertNotIn('private fixture path', json.dumps(health))
            finally:
                server.shutdown()
                thread.join(5)

    def test_token_probability_requests_are_rejected_before_dispatch(self):
        from unittest.mock import patch

        invalid = (
            {'logprobs': True},
            {'logprobs': True, 'top_logprobs': 2},
            {'logprobs': 'private fixture value'},
            {'logprobs': 0},
            {'logprobs': False, 'top_logprobs': 2},
            {'top_logprobs': 1},
            {'top_logprobs': -1},
            {'top_logprobs': False},
            {'top_logprobs': 0.0},
        )
        for streaming in (True, False):
            for options in invalid:
                with self.subTest(streaming=streaming, options=options):
                    self.backend.tokens = None
                    with patch.object(self.executor, 'submit', wraps=self.executor.submit) as submit:
                        with self.assertRaises(urllib.error.HTTPError) as failure:
                            with self.request(streaming, **options) as response:
                                response.read()
                        with failure.exception as response:
                            self.assertEqual(response.code, 400)
                            self.assertEqual(json.load(response), {
                                'error': 'Token probabilities are not supported by this local bridge',
                            })
                        submit.assert_not_called()
                    self.assertIsNone(self.backend.tokens)
            valid = ({}, {'logprobs': None, 'top_logprobs': None},
                     {'logprobs': False, 'top_logprobs': 0})
            for options in valid:
                with self.subTest(streaming=streaming, options=options):
                    with self.request(streaming, **options) as response:
                        body = response.read().decode()
                    if streaming:
                        self.assertIn('[DONE]', body)
                    else:
                        self.assertEqual(json.loads(body)['model'], 'fixture')

    def test_custom_stop_sequences_are_rejected_before_dispatch(self):
        from unittest.mock import patch

        for streaming in (True, False):
            for stop in ('private fixture stop', ['world'], '', False, 1, {}):
                with self.subTest(streaming=streaming, stop=stop):
                    self.backend.tokens = None
                    with patch.object(self.executor, 'submit', wraps=self.executor.submit) as submit:
                        with self.assertRaises(urllib.error.HTTPError) as failure:
                            with self.request(streaming, stop=stop) as response:
                                response.read()
                        with failure.exception as response:
                            self.assertEqual(response.code, 400)
                            self.assertEqual(json.load(response), {
                                'error': 'Custom stop sequences are not supported by this local bridge',
                            })
                        submit.assert_not_called()
                    self.assertIsNone(self.backend.tokens)
            for options in ({}, {'stop': None}, {'stop': []}):
                with self.subTest(streaming=streaming, options=options):
                    with self.request(streaming, **options) as response:
                        body = response.read().decode()
                    if streaming:
                        self.assertIn('world', body)
                        self.assertIn('[DONE]', body)
                    else:
                        result = json.loads(body)
                        self.assertEqual(result['choices'][0]['message']['content'], 'Hello world')

    def test_completion_count_requires_one_choice(self):
        from unittest.mock import patch

        for streaming in (True, False):
            for count in (2, 0, -1, True, 1.0, '1', None, []):
                with self.subTest(streaming=streaming, count=count):
                    self.backend.tokens = None
                    with patch.object(self.executor, 'submit', wraps=self.executor.submit) as submit:
                        with self.assertRaises(urllib.error.HTTPError) as failure:
                            with self.request(streaming, n=count) as response:
                                response.read()
                        with failure.exception as response:
                            self.assertEqual(response.code, 400)
                            self.assertEqual(json.load(response), {
                                'error': 'n must be 1; this local bridge returns one completion',
                            })
                        submit.assert_not_called()
                    self.assertIsNone(self.backend.tokens)
            for options in ({}, {'n': 1}):
                with self.subTest(streaming=streaming, options=options):
                    with self.request(streaming, **options) as response:
                        body = response.read().decode()
                    if streaming:
                        events = [line[6:] for line in body.splitlines() if line.startswith('data: ')]
                        self.assertEqual(events[-1], '[DONE]')
                        result = json.loads(events[-2])
                    else:
                        result = json.loads(body)
                    self.assertEqual(result['model'], 'fixture')
                    self.assertEqual(len(result['choices']), 1)

    def test_omitted_stream_defaults_to_json(self):
        body = json.dumps({
            'model': 'fixture',
            'messages': [{'role': 'user', 'content': 'hello'}],
        }).encode()
        request = urllib.request.Request(
            self.url + '/v1/chat/completions', data=body,
            headers={'Content-Type': 'application/json'},
        )
        with urllib.request.urlopen(request, timeout=5) as response:
            self.assertEqual(response.headers.get_content_type(), 'application/json')
            self.assertEqual(json.load(response)['model'], 'fixture')

    def test_wrong_model_is_rejected_before_generation(self):
        with self.assertRaises(urllib.error.HTTPError) as error:
            self.request(model='different-model')
        with error.exception as response:
            self.assertEqual(response.code, 400)
            self.assertIn('error', json.load(response))
        self.assertIsNone(self.backend.tokens)

    def test_unsupported_chat_options_fail_before_generation(self):
        private = 'private_fixture_detail'
        cases = (
            ({'response_format': {'type': 'json_schema', 'json_schema': {'name': private}}}, 'JSON formats'),
            ({'response_format': {'type': 'json_object'}}, 'JSON formats'),
            ({'response_format': 'text'}, 'JSON formats'),
            ({'tools': [{'type': 'function', 'function': {'name': private}}]}, 'Tool calls'),
            ({'tool_choice': 'auto'}, 'Tool calls'),
            ({'parallel_tool_calls': True}, 'Tool calls'),
            ({'functions': [{'name': private}]}, 'Tool calls'),
            ({'function_call': {'name': private}}, 'Tool calls'),
            ({'messages': [{'role': 'assistant', 'content': '', 'tool_calls': [{'id': private}]}]}, 'Tool calls'),
            ({'messages': [{'role': 'assistant', 'content': '', 'function_call': {'name': private}}]}, 'Tool calls'),
            ({'messages': [{'role': 'tool', 'content': private, 'tool_call_id': private}]}, 'Tool calls'),
        )
        for streaming in (True, False):
            for options, message in cases:
                with self.subTest(streaming=streaming, options=options):
                    with self.assertRaises(urllib.error.HTTPError) as failure:
                        self.request(streaming, **options)
                    with failure.exception as response:
                        self.assertEqual(response.code, 400)
                        self.assertEqual(response.headers.get_content_type(), 'application/json')
                        body = json.load(response)
                    self.assertEqual(set(body), {'error'})
                    self.assertIn(message, body['error'])
                    self.assertNotIn(private, body['error'])
                    self.assertIsNone(self.backend.tokens)
        with self.request(False) as response:
            self.assertEqual(json.load(response)['model'], 'fixture')

    def test_duplicate_request_fields_are_rejected_before_dispatch(self):
        from unittest.mock import patch

        cases = (
            '"messages":[{"role":"user","content":"fixture"}],'
            '"max_tokens":1,"max_tokens":256',
            '"messages":[{"role":"user","content":"fixture"}],'
            r'"max_completion_tokens":1,"max_completion_\u0074okens":256',
            '"messages":[{"role":"user","content":"PRIVATE_VALUE","content":"fixture"}]',
            '"messages":[{"role":"user","content":"fixture"}],'
            '"PRIVATE_FIELD":1,"PRIVATE_FIELD":2',
        )
        for streaming in ('true', 'false'):
            for fields in cases:
                with self.subTest(streaming=streaming, fields=fields):
                    body = ('{"model":"fixture","stream":' + streaming + ',' + fields + '}').encode()
                    request = urllib.request.Request(
                        self.url + '/v1/chat/completions', data=body,
                        headers={'Content-Type': 'application/json'},
                    )
                    with patch.object(self.executor, 'submit', wraps=self.executor.submit) as submit:
                        with self.assertRaises(urllib.error.HTTPError) as failure:
                            urllib.request.urlopen(request, timeout=5)
                        with failure.exception as response:
                            self.assertEqual(response.code, 400)
                            self.assertEqual(response.headers.get_content_type(), 'application/json')
                            self.assertEqual(json.load(response), {
                                'error': 'Duplicate JSON fields are not supported; send each field once.',
                            })
                        submit.assert_not_called()
                    self.assertIsNone(self.backend.tokens)
        with self.request(False, max_completion_tokens=1, messages=[
            {'role': 'user', 'content': 'first'}, {'role': 'assistant', 'content': 'second'},
        ]) as response:
            self.assertEqual(json.load(response)['model'], 'fixture')
        self.assertEqual(self.backend.tokens, 1)

    def test_ambiguous_or_malformed_origins_fail_before_dispatch(self):
        import http.client
        import socket
        from unittest.mock import patch

        body = json.dumps({'model': 'fixture', 'messages': [
            {'role': 'user', 'content': 'private fixture prompt'},
        ]}).encode()

        def send(method, route, origins):
            payload = body if method == 'POST' else b''
            headers = [f'{method} {route} HTTP/1.1', 'Host: localhost',
                       'Content-Type: application/json',
                       f'Content-Length: {len(payload)}',
                       *(f'Origin: {origin}' for origin in origins), '', '']
            with socket.create_connection(self.server.server_address, timeout=5) as connection:
                connection.sendall('\r\n'.join(headers).encode() + payload)
                with http.client.HTTPResponse(connection) as response:
                    response.begin()
                    return (response.status, response.getheader('Access-Control-Allow-Origin'),
                            json.load(response))

        cases = (('',), ('http://localhost/private',), ('http://localhost?',),
                 ('http://private@localhost',), ('http://localhost:65536',),
                 ('http://localhost:0',), ('http://localhost:\r\n 8080',),
                 ('http://10.0.2.2',), ('http://localhost', 'http://localhost'),
                 ('http://localhost', 'https://external.invalid'))
        route = '/v1/chat/completions'
        for origins in cases:
            for method in ('POST', 'OPTIONS'):
                with self.subTest(origins=origins, method=method):
                    with patch.object(self.executor, 'submit', wraps=self.executor.submit) as submit:
                        status, cors, result = send(method, route, origins)
                        self.assertEqual(status, 403)
                        self.assertIsNone(cors)
                        self.assertEqual(result, {'error': 'Local JSON requests only'}
                                         if method == 'POST' else {})
                        submit.assert_not_called()
        self.assertIsNone(self.backend.tokens)
        status, cors, result = send('GET', '/health', ('http://localhost/private',))
        self.assertEqual((status, cors, result['phase']), (200, None, 'idle'))
        for origin in ('http://localhost', 'http://127.0.0.1:8080', 'http://[::1]:8080'):
            with self.subTest(origin=origin):
                self.assertEqual(send('OPTIONS', route, (origin,))[:2], (200, origin))
                status, cors, result = send('POST', route, (origin,))
                self.assertEqual((status, cors, result['model']), (200, origin, 'fixture'))
        self.assertEqual(send('POST', route, ())[:2], (200, None))

    def test_loopback_host_required_before_routing_or_dispatch(self):
        import http.client
        import socket
        from unittest.mock import patch

        def send(method, route, hosts, streaming=False):
            body = json.dumps({'model': 'fixture', 'stream': streaming, 'messages': [
                {'role': 'user', 'content': 'PRIVATE_PROMPT'},
            ]}).encode() if method == 'POST' else b''
            headers = [f'{method} {route} HTTP/1.1',
                       *(f'Host: {host}' for host in hosts),
                       'Origin: http://localhost:8080',
                       'Content-Type: application/json',
                       f'Content-Length: {len(body)}', '', '']
            with socket.create_connection(self.server.server_address, timeout=5) as connection:
                connection.sendall('\r\n'.join(headers).encode() + body)
                response = http.client.HTTPResponse(connection)
                response.begin()
                return response.status, response.getheader('Access-Control-Allow-Origin'), response.read()

        routes = (('GET', '/health'), ('GET', '/v1/models'),
                  ('OPTIONS', '/v1/chat/completions'), ('POST', '/v1/chat/completions'))
        invalid = ((), ('untrusted.example',), ('localhost', 'localhost'),
                   ('localhost, localhost',), ('localhost@127.0.0.1',),
                   ('localhost:65536',), ('localhost:0',), ('[::1',))
        for hosts in invalid:
            for method, route in routes:
                with self.subTest(hosts=hosts, method=method, route=route):
                    with patch.object(self.executor, 'submit', wraps=self.executor.submit) as submit:
                        status, cors, body = send(method, route, hosts)
                        self.assertEqual(status, 403)
                        self.assertIsNone(cors)
                        self.assertNotIn(b'PRIVATE_PROMPT', body)
                        self.assertNotIn(b'/fixture', body)
                        self.assertNotIn(b'untrusted.example', body)
                        submit.assert_not_called()

        port = self.server.server_port
        for host in ('localhost', f'LOCALHOST:{port}', f'127.0.0.1:{port}',
                     f'[::1]:{port}', f'10.0.2.2:{port}'):
            with self.subTest(local_host=host):
                status, cors, _ = send('OPTIONS', '/v1/chat/completions', (host,))
                self.assertEqual((status, cors), (200, 'http://localhost:8080'))
                for streaming in (False, True):
                    status, _, body = send('POST', '/v1/chat/completions', (host,), streaming)
                    self.assertEqual(status, 200)
                    if streaming:
                        self.assertIn(b'[DONE]', body)
                    else:
                        self.assertEqual(json.loads(body)['model'], 'fixture')

    def test_neutral_chat_options_preserve_text_and_streaming(self):
        with self.request(False, response_format={'type': 'text'}, tools=[],
                          functions=[], tool_choice='none', function_call='none',
                          parallel_tool_calls=False) as response:
            self.assertEqual(json.load(response)['choices'][0]['message']['content'],
                             'Hello world')
        with self.request(True, response_format=None, tools=None) as response:
            result = response.read().decode()
        self.assertIn('[DONE]', result)
        self.assertNotIn('event: error', result)

    def test_nonstream_compatibility_and_health(self):
        with self.request(False) as response:
            data=json.load(response)
        self.assertEqual(data['choices'][0]['message']['content'], 'Hello world')
        with urllib.request.urlopen(self.url+'/health') as response:
            health = json.load(response)
            self.assertTrue(health['streaming'])
            self.assertEqual(health['device'], 'fixture-device')
    def test_actual_inventory_reports_bridge_and_checkpoint_limits_without_generation(self):
        for kind in ('mlx', 'torch', 'fixture'):
            self.backend.kind = kind
            for context in (None, 8192):
                self.backend.declared_context_tokens = context
                with self.subTest(kind=kind, context=context):
                    with urllib.request.urlopen(self.url+'/v1/models', timeout=5) as response:
                        entry = json.load(response)['data'][0]
                    self.assertEqual(entry['id'], 'fixture')
                    if kind == 'fixture':
                        self.assertNotIn('asg_request_limits', entry)
                    else:
                        self.assertEqual(entry['asg_request_limits'], {
                            'schema_version': 1, 'max_input_tokens': 4096,
                            'max_output_tokens': 4096, 'checkpoint_context_tokens': context})
                    self.assertIsNone(self.backend.tokens)
        with self.request(False) as response:
            self.assertEqual(json.load(response)['choices'][0]['message']['content'], 'Hello world')

    def test_actual_http_transports_preserve_backend_token_accounting(self):
        original = self.backend.generate
        def counted(*args):
            return {**original(*args), 'prompt_tokens': 4096, 'completion_tokens': 2}
        self.backend.generate = counted
        for streaming in (True, False):
            with self.subTest(streaming=streaming), self.request(streaming, max_tokens=2) as response:
                if streaming:
                    frames = [json.loads(line[6:]) for line in response.read().decode().splitlines()
                              if line.startswith('data: {')]
                    metrics = next(frame['metrics'] for frame in frames if 'metrics' in frame)
                else:
                    metrics = json.load(response)['metrics']
                self.assertEqual(metrics, {'finish_reason': 'stop', 'prompt_tokens': 4096, 'completion_tokens': 2})
        self.backend.generate = original
        with self.request(False) as response:
            self.assertEqual(json.load(response)['metrics'], {'finish_reason': 'stop'})

    def test_actual_mlx_bridge_token_list_and_counts_over_both_transports(self):
        from types import SimpleNamespace
        from unittest.mock import Mock, patch
        import sys
        import qwen_backends
        backend = object.__new__(qwen_backends.MLXBackend)
        backend.model = object()
        tokenizer = Mock(bos_token='<bos>')
        tokenizer.apply_chat_template.return_value = '<bos>prompt'
        ids = list(range(4096))
        tokenizer.encode.return_value = ids
        backend.tokenizer = tokenizer
        stream = Mock(return_value=iter(()))
        original = self.backend.generate
        self.backend.generate = backend.generate
        try:
            with patch.dict(sys.modules, {
                'mlx_lm': SimpleNamespace(stream_generate=stream),
                'mlx_lm.sample_utils': SimpleNamespace(make_sampler=lambda **kw: kw),
            }):
                for streaming in (True, False):
                    stream.reset_mock()
                    tokenizer.encode.return_value = [*ids, 4096]
                    if streaming:
                        with self.request(True) as response:
                            refused = response.read().decode()
                        self.assertIn('event: error', refused)
                        self.assertNotIn('[DONE]', refused)
                    else:
                        with self.assertRaises(urllib.error.HTTPError) as failure:
                            self.request(False)
                        with failure.exception as response:
                            self.assertEqual(response.code, 400)
                            refused = response.read().decode()
                    self.assertIn('Input exceeds 4096-token limit', refused)
                    stream.assert_not_called()
                    tokenizer.encode.return_value = ids
                    stream.return_value = iter([SimpleNamespace(
                        text='actual bridge', finish_reason='stop', generation_tps=1,
                        peak_memory=.1, generation_tokens=2)])
                    with self.request(streaming, max_tokens=5) as response:
                        if streaming:
                            frames = [json.loads(line[6:]) for line in response.read().decode().splitlines()
                                      if line.startswith('data: {')]
                            metrics = next(frame['metrics'] for frame in frames if 'metrics' in frame)
                        else:
                            metrics = json.load(response)['metrics']
                    self.assertEqual(metrics['prompt_tokens'], 4096)
                    self.assertEqual(metrics['completion_tokens'], 2)
                    self.assertIs(stream.call_args.kwargs['prompt'], ids)
                    tokenizer.encode.assert_called_with(
                        '<bos>prompt', add_special_tokens=False, truncation=False)
        finally:
            self.backend.generate = original

    def test_actual_context_refusal_and_retry_over_json_and_sse(self):
        from types import SimpleNamespace
        from unittest.mock import Mock, patch
        import sys
        import qwen_backends
        backend = object.__new__(qwen_backends.MLXBackend)
        backend.model = object()
        backend.tokenizer = Mock(bos_token=None)
        backend.tokenizer.apply_chat_template.return_value = 'prompt'
        backend.tokenizer.encode.return_value = [1, 2, 3]
        stream = Mock()
        original = self.backend.generate
        self.backend.generate = backend.generate
        try:
            with patch.dict(sys.modules, {
                'mlx_lm': SimpleNamespace(stream_generate=stream),
                'mlx_lm.sample_utils': SimpleNamespace(make_sampler=lambda **kw: kw),
            }):
                for streaming in (True, False):
                    backend.declared_context_tokens = 7
                    stream.reset_mock()
                    if streaming:
                        with self.request(True, max_tokens=5) as response:
                            refused = response.read().decode()
                    else:
                        with self.assertRaises(urllib.error.HTTPError) as failure:
                            self.request(False, max_tokens=5)
                        self.assertEqual(failure.exception.code, 400)
                        refused = failure.exception.read().decode()
                    self.assertIn('Prompt plus requested output exceeds checkpoint declared context limit', refused)
                    self.assertNotIn('[DONE]', refused)
                    self.assertNotIn('completion_tokens', refused)
                    stream.assert_not_called()
                    backend.declared_context_tokens = 8
                    stream.return_value = iter([SimpleNamespace(text='ok', finish_reason='stop',
                        generation_tps=1, peak_memory=.1, generation_tokens=2)])
                    with self.request(streaming, max_tokens=5) as response:
                        accepted = response.read().decode()
                    self.assertIn('completion_tokens', accepted)
                    self.assertEqual(stream.call_args.kwargs['max_tokens'], 5)
        finally:
            self.backend.generate = original

    def test_errors_are_not_successful_completions(self):
        with self.request(content='error') as response:
            text=response.read().decode()
        self.assertIn('event: error', text)
        self.assertNotIn('[DONE]', text)
        self.assertIn('Invalid fixture prompt', text)
        self.assertNotIn('"model":', text)
        with self.assertRaises(urllib.error.HTTPError) as failure:
            self.request(False, content='error')
        with failure.exception as response:
            self.assertEqual(response.code, 500)
    def test_remote_origins_are_rejected(self):
        request = urllib.request.Request(self.url+'/v1/chat/completions', data=b'{}', headers={'Content-Type':'application/json','Origin':'https://example.com'})
        with self.assertRaises(urllib.error.HTTPError) as error:
            urllib.request.urlopen(request)
        self.assertEqual(error.exception.code,403)
    def test_source_proposal_budget_and_bounded_chat_limits(self):
        for streaming in (True, False):
            for requested in (1, 256, 512, 1024, 1536, 2048, 4095, 4096):
                with self.subTest(streaming=streaming, requested=requested):
                    with self.request(streaming, max_tokens=requested) as response:
                        response.read()
                    self.assertEqual(self.backend.tokens, requested)
            with self.request(streaming) as response:
                response.read()
            self.assertEqual(self.backend.tokens, 256)
    def test_completion_budget_is_forwarded_exactly(self):
        for streaming in (True, False):
            for requested in (1, 512, 4096):
                with self.subTest(streaming=streaming, requested=requested):
                    with self.request(streaming, max_completion_tokens=requested) as response:
                        response.read()
                    self.assertEqual(self.backend.tokens, requested)

    def test_invalid_token_budget_is_rejected_before_inference(self):
        from unittest.mock import patch
        invalid = (0, -1, 4097, 9000, 10**100, True, False, None,
                   1.0, 1.5, '256', 'PRIVATE_BUDGET', [], {})
        cases = [
            ({field: value},
             f'{field} must be an integer from 1 to 4096; no budget was changed or generation started')
            for field in ('max_tokens', 'max_completion_tokens')
            for value in invalid
        ] + [
            ({'max_tokens': 256, 'max_completion_tokens': value},
             'Send only one of max_tokens or max_completion_tokens; no generation started')
            for value in (1, 256, None)
        ]
        for streaming in (True, False):
            for options, message in cases:
                with self.subTest(streaming=streaming, options=options):
                    self.backend.tokens = None
                    with patch.object(self.executor, 'submit', wraps=self.executor.submit) as submit:
                        with self.assertRaises(urllib.error.HTTPError) as error:
                            self.request(streaming, **options)
                        with error.exception as response:
                            self.assertEqual(response.code, 400)
                            self.assertEqual(json.load(response), {'error': message})
                        submit.assert_not_called()
                    self.assertIsNone(self.backend.tokens)
                    with urllib.request.urlopen(self.url+'/health') as response:
                        self.assertEqual(json.load(response)['phase'], 'idle')
                    # Rejection never owns the model lock or poisons a retry.
                    with self.request(streaming, max_tokens=1536) as response:
                        self.assertIn('Hello ', response.read().decode())
                    self.assertEqual(self.backend.tokens, 1536)

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

    def test_actual_shared_torch_context_refusal_and_retry(self):
        for streaming in (True, False):
            self.fixture.backend.declared_context_tokens = 4
            self.fixture.model.generate.reset_mock()
            if streaming:
                with self.request() as response:
                    refused = response.read().decode()
            else:
                with self.assertRaises(urllib.error.HTTPError) as failure:
                    self.request(False)
                self.assertEqual(failure.exception.code, 400)
                refused = failure.exception.read().decode()
            self.assertIn('Prompt plus requested output exceeds checkpoint declared context limit', refused)
            self.assertNotIn('completion_tokens', refused)
            self.fixture.model.generate.assert_not_called()
            self.fixture.backend.declared_context_tokens = 5
            with self.request(streaming) as response:
                accepted = response.read().decode()
            self.assertIn('completion_tokens', accepted)
            self.assertEqual(self.fixture.model.generate.call_args.kwargs['max_new_tokens'], 2)

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
                                     {'error': 'max_tokens must be an integer from 1 to 4096; no budget was changed or generation started'})
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

    def test_checkpoint_structured_output_default_completes_on_both_transports(self):
        from types import SimpleNamespace
        original = self.fixture.model.generate.side_effect
        def configured(**kwargs):
            result = original(**kwargs)
            return (SimpleNamespace(sequences=result)
                    if kwargs.get('return_dict_in_generate', True) else result)
        self.fixture.model.generate.side_effect = configured
        for streaming in (True, False):
            for output_length, reason in ((4, 'stop'), (5, 'length')):
                with self.subTest(streaming=streaming, reason=reason):
                    self.fixture.output_length = output_length
                    with self.request(streaming) as response:
                        result = response.read().decode()
                    if streaming:
                        self.assertIn('[DONE]', result)
                        self.assertNotIn('event: error', result)
                        self.assertIn('"finish_reason": "' + reason + '"', result)
                        self.assertIn('Hello ', result)
                    else:
                        choice = json.loads(result)['choices'][0]
                        self.assertEqual(choice['message']['content'], 'Hello CPU')
                        self.assertEqual(choice['finish_reason'], reason)
                    self.executor.submit(lambda: None).result(timeout=3)
                    with urllib.request.urlopen(self.url+'/health', timeout=5) as response:
                        self.assertEqual(json.load(response)['phase'], 'idle')

    def test_checkpoint_beam_search_default_completes_on_both_transports(self):
        from types import SimpleNamespace
        original = self.fixture.model.generate.side_effect
        def configured(**kwargs):
            # Persisted beam/multiple-sequence defaults are incompatible with
            # the single-completion TextStreamer, even with do_sample=False.
            if kwargs.get('num_beams', 4) != 1:
                raise ValueError('streamer cannot be used with beam search')
            if kwargs.get('num_return_sequences', 2) != 1:
                raise ValueError('greedy generation requires one sequence')
            return original(**kwargs)
        self.fixture.model.generate.side_effect = configured
        for streaming in (True, False):
            for output_length, reason in ((4, 'stop'), (5, 'length')):
                with self.subTest(streaming=streaming, reason=reason):
                    self.fixture.output_length = output_length
                    with self.request(streaming) as response:
                        result = response.read().decode()
                    if streaming:
                        self.assertIn('[DONE]', result)
                        self.assertNotIn('event: error', result)
                        self.assertIn('"finish_reason": "' + reason + '"', result)
                        self.assertIn('Hello ', result)
                    else:
                        choice = json.loads(result)['choices'][0]
                        self.assertEqual(choice['message']['content'], 'Hello CPU')
                        self.assertEqual(choice['finish_reason'], reason)
                    self.executor.submit(lambda: None).result(timeout=3)
                    with urllib.request.urlopen(self.url+'/health', timeout=5) as response:
                        self.assertEqual(json.load(response)['phase'], 'idle')

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
            self.assertNotIn(b'"model":', received)
            self.assertNotIn(b'[DONE]', received)
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
