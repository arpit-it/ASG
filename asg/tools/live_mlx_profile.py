# SPDX-License-Identifier: MPL-2.0
# Copyright 2026 Arpit Sinha
"""Opt-in synthetic regression for an ALREADY RUNNING offline MLX bridge.

Never starts, downloads or changes a model. Synthetic prompts only. Reports
observations, not authenticated identity, verified context or product support.
Run alone: the disconnect check intentionally interrupts its owned request.
"""
import argparse
import http.client, json, time, hashlib, platform, importlib.metadata, sys
from urllib.parse import urlsplit
from pathlib import Path
import socket
from threading import Lock, Timer
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--origin', required=True)
parser.add_argument('--checkpoint', type=Path, required=True)
parser.add_argument('--model', required=True)
parser.add_argument('--source-revision', required=True)
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--operation-timeout', type=float, default=90)
parser.add_argument('--confirm-live', action='store_true', required=True)
args = parser.parse_args()
if not 0.1 <= args.operation_timeout <= 90:
    parser.error('Operation timeout must be between 0.1 and 90 seconds.')
try:
    origin = urlsplit(args.origin)
    origin.port
except ValueError:
    parser.error('Use a valid numeric loopback HTTP origin.')
if origin.scheme != 'http' or origin.hostname not in ('127.0.0.1', '::1') or origin.username or origin.password or origin.path or origin.query or origin.fragment:
    parser.error('Use a bare numeric loopback HTTP origin.')
if not args.model or len(args.model) > 256 or args.model.strip() != args.model or any((ord(c) < 32 or ord(c) == 127 for c in args.model)):
    parser.error('Use the exact configured model ID.')
if len(args.source_revision) != 40 or any((c not in '0123456789abcdef' for c in args.source_revision)):
    parser.error('Use the tested 40-character source commit.')
if args.output.exists():
    parser.error('Output already exists; choose a new report path.')

class DeadlineConnection(http.client.HTTPConnection):
    """Own a duplicate socket so deadline interrupts detached response reads."""
    def __init__(self):
        super().__init__(origin.hostname, origin.port or 80,
                         timeout=min(30, args.operation_timeout))
        self.deadline = time.monotonic() + args.operation_timeout
        self.guard = Lock()
        self.owned_socket = None
        self.timer = None
        self.expired = False
        self.finished = False

    def connect(self):
        super().connect()
        # HTTP/1.0 getresponse() can detach/close HTTPConnection.sock while the
        # response file retains the descriptor. Shutdown via a separately owned
        # duplicate interrupts that file's pending header/body reads as well.
        with self.guard:
            self.owned_socket = self.sock.dup()
        remaining = self.deadline - time.monotonic()
        if remaining <= 0:
            self.expire()
            raise TimeoutError('Operation deadline')
        self.timer = Timer(remaining, self.expire)
        self.timer.daemon = True
        self.timer.start()

    def expire(self):
        with self.guard:
            if self.finished:
                return
            self.expired = True
        self.interrupt()

    def interrupt(self):
        with self.guard:
            owned, self.owned_socket = self.owned_socket, None
        if owned is not None:
            try:
                owned.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            finally:
                owned.close()

    def finish(self, check=False):
        with self.guard:
            timed_out = self.expired or time.monotonic() >= self.deadline
            self.finished = True
        if self.timer is not None:
            self.timer.cancel()
        self.interrupt()
        self.close()
        if check and timed_out:
            raise TimeoutError('Operation deadline')

connections = []

def connection():
    result = DeadlineConnection()
    connections.append(result)
    return result

def call(path, body=None):
    c = connection()
    c.request('GET' if body is None else 'POST', path, body=None if body is None else json.dumps(body), headers={'Content-Type': 'application/json'})
    r = c.getresponse()
    status = r.status
    raw = r.read(65537)
    assert len(raw) <= 65536
    data = json.loads(raw)
    c.finish(check=True)
    return (status, data)

def request(text, tokens=128, stream=False):
    return {'model': args.model, 'messages': [{'role': 'user', 'content': text}], 'max_tokens': tokens, 'stream': stream}

def validate_response_identity(value):
    # Legacy events may omit identity. A present identity must never contradict
    # the selected request; matching text still cannot authenticate the weights.
    if not isinstance(value, dict):
        raise ValueError('Invalid response envelope')
    if 'model' in value and (not isinstance(value['model'], str)
                             or value['model'] != args.model):
        raise ValueError('Invalid response identity')


def safe_metrics(value, budget):
    import math
    assert value['finish_reason'] == 'stop'
    result = {'finish_reason': 'stop'}
    for key, limit in [('prompt_tokens', 4096), ('completion_tokens', budget)]:
        count = value[key]
        assert type(count) is int and 0 < count <= limit
        result[key] = count
    for key in ['tokens_per_second', 'peak_memory_gb']:
        number = value[key]
        assert type(number) in (int, float) and math.isfinite(number) and (0 < number < 1000000)
        result[key] = number
    return result

def run():
    if not __debug__:
        raise RuntimeError('Assertions must be enabled')
    report = {'schema_version': 1, 'scope': 'Observed isolated selected-checkpoint MLX regression only; no verified total context, model identity authentication, app/manual acceptance, larger model or other platform support.', 'source_revision': args.source_revision, 'host': platform.mac_ver()[0], 'architecture': platform.machine(), 'dependencies': {n: importlib.metadata.version(n) for n in ['mlx', 'mlx-lm', 'transformers', 'tokenizers']}, 'checks': {}}
    status, h = call('/health')
    assert status == 200 and h['backend'] == 'mlx' and (h['device'] == 'metal') and (h['phase'] == 'idle')
    status, inv = call('/v1/models')
    assert status == 200
    assert inv['data'][0]['id'] == args.model
    require_limits = inv['data'][0]['asg_request_limits']
    assert require_limits == {'schema_version': 1, 'max_input_tokens': 4096, 'max_output_tokens': 4096, 'checkpoint_context_tokens': require_limits['checkpoint_context_tokens']}
    assert all(type(require_limits[k]) is int for k in ('schema_version', 'max_input_tokens', 'max_output_tokens'))
    context = require_limits['checkpoint_context_tokens']
    assert context is None or (type(context) is int and 0 < context <= 9007199254740991)
    report['advertised_limits'] = require_limits
    folder = args.checkpoint
    assert folder.is_dir() and (not folder.is_symlink())
    assert h['model'] == args.model
    report['response_identity_scope'] = 'Every observed present completion model ID must match the request. Missing legacy IDs remain unverified; matching IDs are server assertions, not weight authentication.'
    report['provenance'] = 'Operator-selected source revision and local checkpoint metadata; weights counted but not hashed; HTTP backend/device/model remain server assertions, not authentication.'
    report['metadata_sha256'] = {n: hashlib.sha256((folder / n).read_bytes()).hexdigest() for n in ['config.json', 'tokenizer_config.json', 'model.safetensors.index.json'] if (folder / n).is_file() and (not (folder / n).is_symlink()) and ((folder / n).stat().st_size <= 1048576)}
    assert len(report['metadata_sha256']) == 3
    weights = list(folder.glob('*.safetensors'))
    assert weights and all(p.is_file() and not p.is_symlink() for p in weights)
    report['weights'] = {'file_count': len(list(folder.glob('*.safetensors'))), 'disk_bytes': sum((p.stat().st_size for p in folder.glob('*.safetensors')))}
    start = time.monotonic()
    status, result = call('/v1/chat/completions', request('Reply with exactly the single word READY.', 32))
    validate_response_identity(result)
    assert status == 200 and result['choices'][0]['finish_reason'] == 'stop'
    assert result['choices'][0]['message']['content'].strip() == 'READY'
    metrics = safe_metrics(result['metrics'], 32)
    assert type(metrics['prompt_tokens']) is int and metrics['prompt_tokens'] > 0 and (0 < metrics['completion_tokens'] <= 32)
    report['checks']['json'] = {'seconds': round(time.monotonic() - start, 3), 'metrics': metrics}
    c = connection()
    c.request('POST', '/v1/chat/completions', json.dumps(request('Return only this exact JSON object, without markdown: {"status":"ready","count":3}', 128, True)), {'Content-Type': 'application/json'})
    r = c.getresponse()
    assert r.status == 200
    parts = []
    final = None
    done = False
    start = time.monotonic()
    total = 0
    for line in iter(lambda: r.readline(65537), b''):
        total += len(line)
        assert total <= 65536
        assert len(line) <= 65536 and time.monotonic() - start < 90
        if not line.startswith(b'data: '):
            continue
        data = line[6:].strip()
        if data == b'[DONE]':
            done = True
            break
        value = json.loads(data)
        validate_response_identity(value)
        if 'error' in value:
            raise AssertionError('Stream error')
        for choice in value.get('choices', []):
            if choice.get('delta', {}).get('content'):
                parts.append(choice['delta']['content'])
        if 'metrics' in value:
            final = safe_metrics(value['metrics'], 128)
    c.finish(check=True)
    assert done and final['finish_reason'] == 'stop' and (len(parts) > 1)
    assert json.loads(''.join(parts).strip()) == {'status': 'ready', 'count': 3}
    report['checks']['structured_sse'] = {'seconds': round(time.monotonic() - start, 3), 'content_chunks': len(parts), 'metrics': final}
    start = time.monotonic()
    observed = False
    c = connection()
    c.request('POST', '/v1/chat/completions', json.dumps(request('List the integers from 1 through 1000, one integer per line.', 4096, True)), {'Content-Type': 'application/json'})
    r = c.getresponse()
    assert r.status == 200
    total = 0
    for line in iter(lambda: r.readline(65537), b''):
        total += len(line)
        assert total <= 65536
        assert len(line) <= 65536 and time.monotonic() - start < 90
        if line.startswith(b'data: '):
            v = json.loads(line[6:])
            validate_response_identity(v)
            if any((x.get('delta', {}).get('content') for x in v.get('choices', []))):
                observed = True
                break
    r.close()
    c.finish(check=True)
    assert observed
    start = time.monotonic()
    while time.monotonic() - start < 15:
        status, h = call('/health')
        if h['phase'] == 'idle':
            break
        time.sleep(0.1)
    assert h['phase'] == 'idle' and time.monotonic() - start < 15
    report['checks']['disconnect'] = {'idle_seconds': round(time.monotonic() - start, 3), 'scope': 'Client disconnect observed; not a native-kernel preemption or process-tree guarantee.'}
    status, result = call('/v1/chat/completions', request('Reply with exactly the single word READY.', 32))
    validate_response_identity(result)
    assert status == 200 and result['choices'][0]['message']['content'].strip() == 'READY'
    report['checks']['retry'] = {'metrics': safe_metrics(result['metrics'], 32)}
    report['recorded_at'] = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())
    with args.output.open('x') as output:
        output.write(json.dumps(report, indent=2, allow_nan=False) + '\n')
    print('MLX synthetic regression passed; sanitized observations saved.')
if __name__ == '__main__':
    try:
        run()
    except Exception:
        print('Live regression failed; no passing report written. Check the owned runtime and retry with a new output path.', file=sys.stderr)
        sys.exit(1)
    finally:
        for connection in connections:
            connection.finish()
