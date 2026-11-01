# SPDX-License-Identifier: MPL-2.0
# Copyright 2026 Arpit Sinha

"""Local Qwen inference bridge: MLX (preferred) or legacy Torch, with SSE."""
import argparse
import json
import math
import os
import queue
import subprocess
import sys
import time
from contextlib import contextmanager, nullcontext
from concurrent.futures import ThreadPoolExecutor
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from threading import Event, Lock, Thread
from urllib.parse import urlparse

sys.path.insert(0, str(Path(__file__).parent / '.runtime-deps'))
os.environ['HF_HUB_OFFLINE'] = '1'
os.environ['TRANSFORMERS_OFFLINE'] = '1'

from qwen_backends import GenerationCancelled, discover_capabilities, load_backend, select_backend, validate_model_config



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
            # A byte-bounded JSON body can still exhaust decoder recursion.
            # Reject it before acquiring the model lock or invoking a backend.
            except (ValueError, TypeError, AttributeError, OverflowError, RecursionError):
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
                        if getattr(backend, 'device', None) == 'cpu':
                            # Optional CPU tokenizer/model exceptions can contain
                            # prompts, paths or dynamically named types. Keep the
                            # public HTTP boundary fixed, including SSE failures.
                            if isinstance(error, MemoryError):
                                message = 'CPU generation ran out of memory; choose smaller compatible weights or free memory.'
                            elif isinstance(error, TimeoutError):
                                message = 'CPU generation timed out; reduce input or requested output and retry.'
                            else:
                                message = 'CPU generation failed; check input length, compatible local weights, tokenizer and installed loader APIs, then retry.'
                        else:
                            message = str(error) if isinstance(error, (ValueError, TimeoutError)) else f'Local generation failed ({type(error).__name__})'
                        publish('error', message)
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


class CPUStartupError(RuntimeError):
    """Bounded CPU loader failure safe for the CLI boundary."""


class CPUCheckpointError(ValueError):
    """Sanitized checkpoint failure safe for the explicit CPU CLI boundary."""


def _cpu_checkpoint_details(folder, max_weight_bytes=None):
    """Check local checkpoint structure without reading tensor contents.

    This is preflight only: the trusted loader still validates actual tensors.
    Files may change after inspection; this is not a filesystem sandbox.
    """
    if max_weight_bytes is not None and (type(max_weight_bytes) is not int or max_weight_bytes <= 0):
        raise CPUCheckpointError('CPU weight byte ceiling must be a positive integer')
    try:
        folder = folder.resolve(strict=True)
    except (OSError, RuntimeError):
        raise CPUCheckpointError('CPU checkpoint folder is unavailable; no model was loaded') from None

    def local_file(name):
        try:
            path = (folder / name).resolve(strict=True)
            if not path.is_relative_to(folder) or not path.is_file() or path.stat().st_size == 0:
                raise CPUCheckpointError()
            return path
        except (OSError, RuntimeError, ValueError):
            raise CPUCheckpointError('CPU checkpoint requires nonempty contained regular files') from None

    def metadata(name, limit):
        # Bound actual reads too: stat alone does not constrain a growing file.
        with local_file(name).open('rb') as source:
            content = source.read(limit + 1)
        if len(content) > limit:
            raise CPUCheckpointError()
        return json.loads(content.decode('utf-8'))

    try:
        config = metadata('config.json', 1024 * 1024)
        if not isinstance(config, dict):
            raise CPUCheckpointError()
        index = folder / 'model.safetensors.index.json'
        if index.exists() or index.is_symlink():
            manifest = metadata(index.name, 8 * 1024 * 1024)
            weights = manifest.get('weight_map') if isinstance(manifest, dict) else None
            if not isinstance(weights, dict) or not weights or any(
                    not isinstance(key, str) or not key or not isinstance(value, str) or
                    not value or Path(value).is_absolute() or
                    '..' in Path(value).parts or not value.endswith('.safetensors')
                    for key, value in weights.items()):
                raise CPUCheckpointError()
            shards = set(weights.values())
        else:
            shards = {'model.safetensors'}
        # Count canonical paths once; never open tensor files. This observed
        # disk footprint is not a loader allocation or post-inspection quota.
        paths = {local_file(shard) for shard in shards}
        weight_bytes = sum(path.stat().st_size for path in paths)
        if max_weight_bytes is not None and weight_bytes > max_weight_bytes:
            raise OverflowError()
        return config, weight_bytes, len(paths)
    except OverflowError:
        raise CPUCheckpointError('CPU checkpoint exceeds configured weight byte ceiling; no model was loaded') from None
    except (OSError, UnicodeError, ValueError, RuntimeError):
        raise CPUCheckpointError('Invalid CPU checkpoint: require contained config (up to 1 MiB), index (up to 8 MiB) and nonempty safetensors weights') from None


def validate_cpu_checkpoint(folder, max_weight_bytes=None):
    """Preserve the startup contract: return only validated config metadata."""
    return _cpu_checkpoint_details(folder, max_weight_bytes)[0]


def inspect_cpu_checkpoint(folder, max_weight_bytes=None):
    """Private structural report, without optional imports or runtime startup.

    No checkpoint paths, tensor names or arbitrary metadata enter the report.
    Dependencies, tokenizer/tensor validity, RAM fit and inference stay unknown.
    """
    try:
        config, weight_bytes, file_count = _cpu_checkpoint_details(folder, max_weight_bytes)
        validate_model_config('cpu', config)
    except OSError:
        raise ValueError('CPU checkpoint folder is unavailable; no model was loaded') from None
    return {'schema_version': 1, 'backend': 'torch', 'device': 'cpu',
            'experimental': True, 'readiness': 'unverified',
            'checkpoint_structure': 'validated', 'weight_bytes': weight_bytes,
            'weight_file_count': file_count, 'model_compatible': None,
            'memory_adequate': None, 'inference_verified': False,
            'scope': 'Local structure and observed disk bytes only; no dependency, tokenizer, tensor, RAM or inference validation.'}


# The independent interpreter must remain responsive even if a native loader
# holds this interpreter's GIL. EOF on its private pipe disarms it and also
# cleans it up if this runtime exits unexpectedly. No model/path enters argv.
_CPU_LOAD_WATCHDOG = r"""
import os, signal, sys, threading
parent, seconds = int(sys.argv[1]), float(sys.argv[2])
finished = threading.Event()
def watch_pipe():
    sys.stdin.buffer.read(1)
    finished.set()
threading.Thread(target=watch_pipe, daemon=True).start()
os.write(1, b'armed\n')
os.close(1)
if not finished.wait(seconds) and os.getppid() == parent:
    try:
        os.set_blocking(2, False)
        os.write(2, b'CPU model loading deadline exceeded; runtime process stopped. No fallback was started.\n')
    except OSError:
        pass
    finally:
        try:
            os.kill(parent, getattr(signal, 'SIGKILL', signal.SIGTERM))
        except ProcessLookupError:
            pass
# Avoid interpreter finalization waiting on the daemon pipe reader or logging
# to a full stderr pipe after the parent has been terminated.
os._exit(0)
"""


@contextmanager
def cpu_load_deadline(seconds):
    """Guard this dedicated runtime process, including a GIL-holding loader.

    Expiration terminates this process with a platform kill signal, rather than
    pretending to cancel a Future. It does not bound RAM or library descendants.
    """
    try:
        watcher = subprocess.Popen(
            [sys.executable, '-I', '-S', '-c', _CPU_LOAD_WATCHDOG,
             str(os.getpid()), str(seconds)],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    except OSError:
        raise RuntimeError('CPU load watchdog could not start; no model was loaded') from None
    acknowledgement = []
    def read_acknowledgement():
        try:
            acknowledgement.append(watcher.stdout.read(6))
        except OSError:
            pass
    reader = Thread(target=read_acknowledgement, daemon=True)
    try:
        reader.start()
        reader.join(timeout=5)
        if reader.is_alive() or acknowledgement != [b'armed\n'] or watcher.poll() is not None:
            raise RuntimeError('CPU load watchdog did not arm; no model was loaded')
        yield
    finally:
        # Close the disarm pipe even on failed startup. A helper that never
        # acknowledges must be terminated/reaped before returning the failure.
        try:
            watcher.stdin.close()
        except OSError:
            pass
        if reader.is_alive():
            watcher.kill()
        try:
            watcher.wait(timeout=5)
        except subprocess.TimeoutExpired:
            watcher.kill()
            watcher.wait()
        reader.join(timeout=1)
        watcher.stdout.close()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--model', type=Path)
    parser.add_argument('--inspect-cpu-checkpoint', action='store_true', help='Report experimental CPU checkpoint structure and disk bytes without loading or starting a runtime')
    parser.add_argument('--capabilities', action='store_true', help='Report dependencies without loading weights or probing devices')
    parser.add_argument('--probe-devices', action='store_true', help='With --capabilities, query device APIs without loading weights')
    parser.add_argument('--port', type=int, default=8765)
    parser.add_argument('--model-id', default='Qwen3.5-9B')
    parser.add_argument('--backend', choices=['auto', 'mlx', 'torch', 'cpu'], default='auto')
    parser.add_argument('--experimental-cpu', action='store_true', help='Opt in to unverified CPU implementation for controlled testing; not a supported backend')
    parser.add_argument('--cpu-threads', type=int, default=None, help='Experimental CPU intra-op thread limit, 1..32 (default 2)')
    parser.add_argument('--cpu-max-weight-bytes', type=int, help='Optional experimental CPU checkpoint disk-byte ceiling; not a RAM limit')
    parser.add_argument('--cpu-load-timeout-seconds', type=float, help='Experimental CPU load deadline, >0 and <=3600 seconds (default 180); expiration ends this runtime process')
    parser.add_argument('--parent-pid', type=int)
    args = parser.parse_args()
    if args.backend == 'cpu' and not args.experimental_cpu:
        parser.error('--backend cpu requires --experimental-cpu; real-host inference remains unverified')
    if args.experimental_cpu and args.backend != 'cpu':
        parser.error('--experimental-cpu requires --backend cpu; no automatic fallback')
    if args.cpu_threads is not None and (args.backend != 'cpu' or not 1 <= args.cpu_threads <= 32):
        parser.error('--cpu-threads requires --backend cpu and a value between 1 and 32')
    if args.cpu_max_weight_bytes is not None and (args.backend != 'cpu' or args.cpu_max_weight_bytes <= 0):
        parser.error('--cpu-max-weight-bytes requires --backend cpu and a positive integer')
    if args.cpu_load_timeout_seconds is not None and (args.backend != 'cpu' or not math.isfinite(args.cpu_load_timeout_seconds) or not 0 < args.cpu_load_timeout_seconds <= 3600):
        parser.error('--cpu-load-timeout-seconds requires --backend cpu and a finite value >0 and <=3600')
    if args.cpu_load_timeout_seconds is not None and args.capabilities:
        parser.error('--cpu-load-timeout-seconds cannot combine with capabilities')
    if args.inspect_cpu_checkpoint:
        if args.backend != 'cpu' or args.model is None:
            parser.error('--inspect-cpu-checkpoint requires --backend cpu --experimental-cpu --model')
        if args.capabilities or args.probe_devices or args.parent_pid is not None or args.cpu_threads is not None or args.cpu_load_timeout_seconds is not None:
            parser.error('--inspect-cpu-checkpoint cannot combine with capabilities, device probes, parent monitoring, thread configuration or load deadlines')
        try:
            report = inspect_cpu_checkpoint(args.model, args.cpu_max_weight_bytes)
        except (ValueError, RuntimeError):
            parser.error('CPU checkpoint inspection failed: require an accessible compatible unquantized Qwen3.5 checkpoint with contained bounded metadata and nonempty safetensors within the configured byte ceiling; no model was loaded')
        print(json.dumps(report, sort_keys=True))
        return
    if args.capabilities:
        print(json.dumps(discover_capabilities(probe_devices=args.probe_devices, experimental_cpu=args.experimental_cpu), sort_keys=True))
        return
    if args.probe_devices:
        parser.error('--probe-devices requires --capabilities')
    if args.model is None:
        parser.error('--model is required unless --capabilities is used')
    try:
        folder = args.model.resolve(strict=True)
    except (OSError, RuntimeError):
        if args.backend != 'cpu':
            raise
        raise CPUCheckpointError('CPU checkpoint folder is unavailable; no model was loaded') from None
    config = (validate_cpu_checkpoint(folder, max_weight_bytes=args.cpu_max_weight_bytes) if args.backend == 'cpu' else
              json.loads((folder / 'config.json').read_text()))
    if args.backend == 'cpu':
        try:
            validate_model_config('cpu', config)
        except ValueError as error:
            raise CPUCheckpointError(str(error)) from None
    if 'Qwen3_5ForConditionalGeneration' not in config.get('architectures', []):
        raise ValueError('Unsupported model architecture')
    if args.backend != 'cpu':
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
    kind = select_backend(args.backend, config, experimental_cpu=args.experimental_cpu)
    executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix='qwen-inference')
    print(f'Loading {args.model_id} using {kind}. Local weights only.', flush=True)
    deadline = cpu_load_deadline(args.cpu_load_timeout_seconds if args.cpu_load_timeout_seconds is not None else 180) if kind == 'cpu' else nullcontext()
    try:
        with deadline:
            backend = executor.submit(load_backend, folder, kind, experimental_cpu=args.experimental_cpu, cpu_threads=args.cpu_threads if args.cpu_threads is not None else 2).result()
    except BaseException as error:
        executor.shutdown(wait=False, cancel_futures=True)
        if kind != 'cpu' or not isinstance(error, Exception):
            raise
        # Optional loaders may include private paths or metadata in exceptions.
        # Do not copy their text or traceback across the CLI boundary.
        if isinstance(error, MemoryError):
            message = 'CPU loading ran out of memory; choose smaller compatible weights or free memory'
        elif isinstance(error, ImportError):
            message = 'CPU loader dependency failed; inspect the configured Python environment'
        else:
            message = 'CPU loading failed; check compatible local weights, tokenizer and installed loader APIs'
        raise CPUStartupError(message + '; no runtime was started and no fallback was attempted') from None
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
    try:
        main()
    except CPUCheckpointError as error:
        # Only allowlisted checkpoint messages cross this CLI boundary. Preserve
        # legacy failures and direct API ValueError behavior; omit tracebacks.
        sys.stderr.write(f'CPU checkpoint preflight failed: {error}\n')
        sys.exit(2)
    except CPUStartupError as error:
        sys.stderr.write(f'CPU startup failed: {error}\n')
        sys.exit(2)
