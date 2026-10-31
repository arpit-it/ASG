# SPDX-License-Identifier: MPL-2.0
# Copyright 2026 Arpit Sinha

"""Local Qwen inference bridge: MLX (preferred) or legacy Torch, with SSE."""
import argparse
import json
import os
import queue
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from threading import Event, Lock, Thread
from urllib.parse import urlparse

sys.path.insert(0, str(Path(__file__).parent / '.runtime-deps'))
os.environ['HF_HUB_OFFLINE'] = '1'
os.environ['TRANSFORMERS_OFFLINE'] = '1'

from qwen_backends import GenerationCancelled, discover_capabilities, load_backend, select_backend



def create_handler(backend, executor, model_id, model_path):
    lock = Lock()
    phase = {'value': 'idle'}
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def local_origin(self):
            origin = self.headers.get('Origin')
            if not origin:
                return True
            parsed = urlparse(origin)
            return parsed.scheme == 'http' and parsed.hostname in ('localhost', '127.0.0.1', '::1')

        def send_headers(self, code, content_type, length=None):
            self.send_response(code)
            origin = self.headers.get('Origin')
            if origin and self.local_origin():
                self.send_header('Access-Control-Allow-Origin', origin)
                self.send_header('Vary', 'Origin')
                self.send_header('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
                self.send_header('Access-Control-Allow-Headers', 'Content-Type')
            self.send_header('Content-Type', content_type)
            self.send_header('Cache-Control', 'no-cache')
            if length is not None:
                self.send_header('Content-Length', str(length))
            self.end_headers()

        def respond(self, code, data):
            body = json.dumps(data).encode()
            self.send_headers(code, 'application/json', len(body))
            try:
                self.wfile.write(body)
            except (BrokenPipeError, ConnectionResetError):
                pass

        def sse(self, event, data):
            body = data if isinstance(data, str) else json.dumps(data)
            self.wfile.write(f'event: {event}\ndata: {body}\n\n'.encode())
            self.wfile.flush()

        def do_OPTIONS(self):
            self.respond(200 if self.local_origin() else 403, {})

        def do_GET(self):
            if self.path == '/health':
                self.respond(200, {'status': 'ready', 'phase': phase['value'], 'model': model_id, 'model_path': str(model_path), 'device': getattr(backend, 'device', 'unknown'), 'backend': backend.kind, 'streaming': True})
            elif self.path == '/v1/models':
                self.respond(200, {'data': [{'id': model_id, 'object': 'model'}]})
            else:
                self.respond(404, {'error': 'Unknown route'})

        def do_POST(self):
            if not self.local_origin() or self.headers.get('Content-Type', '').split(';')[0].strip() != 'application/json':
                self.respond(403, {'error': 'Local JSON requests only'})
                return
            if self.path != '/v1/chat/completions':
                self.respond(404, {'error': 'Unknown route'})
                return
            try:
                self.connection.settimeout(15)
                size = int(self.headers.get('Content-Length', '0'))
                if not 0 < size <= 32768:
                    self.respond(413, {'error': 'Request size limit'})
                    return
                request = json.loads(self.rfile.read(size))
                if request.get('model') != model_id:
                    raise ValueError('Use the configured model ID')
                messages = request.get('messages')
                if not isinstance(messages, list) or not 1 <= len(messages) <= 32 or any(not isinstance(m, dict) or m.get('role') not in ('user', 'assistant', 'system') or not isinstance(m.get('content'), str) for m in messages):
                    raise ValueError('Invalid text messages')
                # Reviewed full-file source proposals request 4096 tokens. Chat
                # retains its smaller caller-selected limit and 256 default.
                tokens = min(4096, max(1, int(request.get('max_tokens', 256))))
                streaming = request.get('stream') is True
            except (ValueError, TypeError, AttributeError):
                self.respond(400, {'error': 'Invalid request or model ID'})
                return
            if not lock.acquire(blocking=False):
                self.respond(429, {'error': 'Model busy; cancel or wait for the current request'})
                return
            cancelled = Event()
            events = queue.Queue(maxsize=64)
            deadline = time.monotonic() + 180
            phase['value'] = 'thinking'
            def publish(kind, value):
                if kind == 'token':
                    phase['value'] = 'writing'
                while not cancelled.is_set():
                    try:
                        events.put((kind, value), timeout=0.25)
                        return
                    except queue.Full:
                        if time.monotonic() > deadline:
                            raise TimeoutError('Client is not reading')
                raise GenerationCancelled()
            def generate():
                try:
                    metrics = backend.generate(messages, tokens, publish, cancelled, deadline)
                    publish('finish', metrics)
                except GenerationCancelled:
                    pass
                except Exception as error:
                    try:
                        publish('error', str(error) if isinstance(error, (ValueError, TimeoutError)) else f'Local generation failed ({type(error).__name__})')
                    except GenerationCancelled:
                        pass
                finally:
                    phase['value'] = 'idle'
                    lock.release()
            try:
                executor.submit(generate)
            except Exception:
                lock.release()
                raise
            try:
                if streaming:
                    self.send_headers(200, 'text/event-stream; charset=utf-8')
                    self.sse('status', {'phase': 'thinking'})
                fragments = []
                writing = False
                while True:
                    if time.monotonic() > deadline:
                        raise TimeoutError('Generation exceeded 180 seconds')
                    try:
                        kind, value = events.get(timeout=1)
                    except queue.Empty:
                        if streaming:
                            self.sse('ping', {'phase': phase['value']})
                        continue
                    if kind == 'token':
                        fragments.append(value)
                        if not writing:
                            writing = True
                            if streaming:
                                self.sse('status', {'phase': 'writing'})
                        if streaming:
                            self.sse('message', {'choices': [{'delta': {'content': value}}]})
                    elif kind == 'finish':
                        reason = value['finish_reason']
                        if streaming:
                            self.sse('message', {'choices': [{'delta': {}, 'finish_reason': reason}], 'metrics': value})
                            self.sse('message', '[DONE]')
                        else:
                            self.respond(200, {'model': model_id, 'choices': [{'message': {'role': 'assistant', 'content': ''.join(fragments)}, 'finish_reason': reason}], 'metrics': value})
                        break
                    else:
                        if streaming:
                            self.sse('error', {'error': value})
                        else:
                            self.respond(500, {'error': value})
                        break
            except (BrokenPipeError, ConnectionResetError, TimeoutError, OSError) as error:
                if streaming:
                    try:
                        self.sse('error', {'error': 'Generation interrupted or timed out'})
                    except OSError:
                        pass
                else:
                    self.respond(504, {'error': 'Generation interrupted or timed out'})
            finally:
                cancelled.set()
    return Handler


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--model', type=Path)
    parser.add_argument('--capabilities', action='store_true', help='Report dependencies without loading weights or probing devices')
    parser.add_argument('--probe-devices', action='store_true', help='With --capabilities, query device APIs without loading weights')
    parser.add_argument('--port', type=int, default=8765)
    parser.add_argument('--model-id', default='Qwen3.5-9B')
    parser.add_argument('--backend', choices=['auto', 'mlx', 'torch'], default='auto')
    parser.add_argument('--parent-pid', type=int)
    args = parser.parse_args()
    if args.capabilities:
        print(json.dumps(discover_capabilities(probe_devices=args.probe_devices), sort_keys=True))
        return
    if args.probe_devices:
        parser.error('--probe-devices requires --capabilities')
    if args.model is None:
        parser.error('--model is required unless --capabilities is used')
    folder = args.model.resolve(strict=True)
    config = json.loads((folder / 'config.json').read_text())
    if 'Qwen3_5ForConditionalGeneration' not in config.get('architectures', []):
        raise ValueError('Unsupported model architecture')
    index = folder / 'model.safetensors.index.json'
    shards = set(json.loads(index.read_text())['weight_map'].values()) if index.exists() else {'model.safetensors'}
    for shard in shards:
        if not (folder / shard).resolve(strict=True).is_relative_to(folder):
            raise ValueError('Shard outside model folder')
    if args.parent_pid:
        def watch_parent():
            while True:
                try:
                    os.kill(args.parent_pid, 0)
                except ProcessLookupError:
                    os._exit(0)
                time.sleep(2)
        Thread(target=watch_parent, daemon=True).start()
    kind = select_backend(args.backend, config)
    executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix='qwen-inference')
    print(f'Loading {args.model_id} using {kind}. Local weights only.', flush=True)
    backend = executor.submit(load_backend, folder, kind).result()
    server = ThreadingHTTPServer(('127.0.0.1', args.port), create_handler(backend, executor, args.model_id, folder))
    server.daemon_threads = True
    print(f'Ready at http://127.0.0.1:{args.port}/v1 ({kind}, streaming)', flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
        executor.shutdown(wait=False, cancel_futures=True)


if __name__ == '__main__':
    main()
