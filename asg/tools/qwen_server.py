# SPDX-License-Identifier: MPL-2.0
# Copyright 2026 Arpit Sinha

"""Local Qwen inference bridge: MLX (preferred) or legacy Torch, with SSE."""
import argparse
import importlib.util
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


class GenerationCancelled(Exception):
    pass


class Backend:
    def __init__(self, folder, kind):
        self.kind = kind
        if kind == 'mlx':
            from mlx_lm import load
            self.model, self.tokenizer = load(str(folder))
        else:
            import torch
            from transformers import AutoTokenizer, Qwen3_5ForConditionalGeneration
            if not torch.backends.mps.is_available():
                raise RuntimeError('Apple Metal unavailable')
            self.tokenizer = AutoTokenizer.from_pretrained(folder, local_files_only=True, trust_remote_code=False)
            self.model = Qwen3_5ForConditionalGeneration.from_pretrained(folder, local_files_only=True, trust_remote_code=False, dtype=torch.bfloat16, device_map='mps').eval()

    def generate(self, messages, tokens, publish, cancelled, deadline):
        def check(*_):
            if cancelled.is_set():
                raise GenerationCancelled()
            if time.monotonic() > deadline:
                raise TimeoutError('Generation deadline exceeded')
        check()
        prompt = self.tokenizer.apply_chat_template(messages, tokenize=False, add_generation_prompt=True, enable_thinking=False)
        if len(self.tokenizer.encode(prompt)) > 4096:
            raise ValueError('Input exceeds 4096-token limit')
        if self.kind == 'mlx':
            from mlx_lm import stream_generate
            from mlx_lm.sample_utils import make_sampler
            result = None
            for result in stream_generate(self.model, self.tokenizer, prompt=prompt, max_tokens=tokens, sampler=make_sampler(temp=0), prefill_step_size=256, prompt_progress_callback=check):
                check()
                if result.text:
                    publish('token', result.text)
            return {'finish_reason': result.finish_reason if result else 'stop', 'tokens_per_second': result.generation_tps if result else 0, 'peak_memory_gb': result.peak_memory if result else 0}
        import torch
        from transformers import TextStreamer, StoppingCriteria, StoppingCriteriaList
        class TokenStreamer(TextStreamer):
            def on_finalized_text(self, text, stream_end=False):
                if text:
                    publish('token', text)
        class Stop(StoppingCriteria):
            def __call__(self, *_args, **_kwargs):
                return cancelled.is_set() or time.monotonic() > deadline
        inputs = self.tokenizer(prompt, return_tensors='pt').to('mps')
        with torch.inference_mode():
            output = self.model.generate(**inputs, max_new_tokens=tokens, do_sample=False, streamer=TokenStreamer(self.tokenizer, skip_prompt=True, skip_special_tokens=True), stopping_criteria=StoppingCriteriaList([Stop()]))
        check()
        reason = 'length' if output.shape[-1] - inputs.input_ids.shape[-1] >= tokens else 'stop'
        return {'finish_reason': reason}


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
                self.respond(200, {'status': 'ready', 'phase': phase['value'], 'model': model_id, 'model_path': str(model_path), 'device': 'metal', 'backend': backend.kind, 'streaming': True})
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
    parser.add_argument('--model', type=Path, required=True)
    parser.add_argument('--port', type=int, default=8765)
    parser.add_argument('--model-id', default='Qwen3.5-9B')
    parser.add_argument('--backend', choices=['auto', 'mlx', 'torch'], default='auto')
    parser.add_argument('--parent-pid', type=int)
    args = parser.parse_args()
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
    kind = ('mlx' if importlib.util.find_spec('mlx_lm') else 'torch') if args.backend == 'auto' else args.backend
    executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix='qwen-inference')
    print(f'Loading {args.model_id} using {kind}. Local weights only.', flush=True)
    backend = executor.submit(Backend, folder, kind).result()
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
