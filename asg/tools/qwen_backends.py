# SPDX-License-Identifier: MPL-2.0
# Copyright 2026 Arpit Sinha

"""Backend discovery; model loaders are imported only on load.

Default discovery reports installed modules; an explicit probe queries device APIs.
Neither establishes successful model loading or memory adequacy.
CPU execution is experimental and explicit opt-in only; CUDA is unsupported.
"""
import contextlib
import importlib
import importlib.util
import os
import platform
import time


class GenerationCancelled(Exception):
    pass


def probe_device(kind):
    """Query only the backend device API; never import model loaders or weights.

    The caller owns a bounded helper process. Suppress optional dependency output;
    neither diagnostic strings nor import exceptions belong in a public report.
    """
    try:
        with open(os.devnull, 'w') as sink, contextlib.redirect_stdout(sink), contextlib.redirect_stderr(sink):
            if kind == 'mlx':
                ready = importlib.import_module('mlx.core').metal.is_available()
            elif kind == 'torch':
                ready = importlib.import_module('torch').backends.mps.is_available()
            else:
                return None
        return ready if isinstance(ready, bool) else None
    except Exception:
        return None


def discover_capabilities(system=None, machine=None, available=None, probe_devices=False, experimental_cpu=False):
    system = platform.system() if system is None else system
    machine = platform.machine() if machine is None else machine
    available = available or (lambda name: importlib.util.find_spec(name) is not None)
    apple = system == 'Darwin' and machine.lower() in ('arm64', 'aarch64')
    entries = []
    for kind, device, dependencies, host_supported in (
        ('mlx', 'metal', ('mlx_lm', 'mlx'), apple),
        ('torch', 'mps', ('torch', 'transformers', 'accelerate'), system == 'Darwin'),
    ):
        missing = [name for name in dependencies if not available(name)]
        ready = probe_device(kind) if probe_devices and host_supported and not missing else None
        entries.append({'backend': kind, 'device': device,
                        'host_supported': host_supported,
                        'missing_dependencies': missing,
                        'device_ready': ready, 'model_compatible': None,
                        'readiness': 'unverified' if host_supported and not missing and ready is not False else 'unavailable'})
    if experimental_cpu:
        missing = [name for name in ('torch', 'transformers', 'safetensors') if not available(name)]
        supported = system in ('Darwin', 'Linux', 'Windows')
        entries.append({'backend': 'cpu', 'device': 'cpu',
                        'host_supported': supported, 'missing_dependencies': missing,
                        'device_ready': None, 'model_compatible': None,
                        'readiness': 'unverified' if supported and not missing else 'unavailable'})
    return {'schema_version': 1, 'host': {'system': system, 'machine': machine},
            'backends': entries, 'unsupported_devices': ['cuda'] if experimental_cpu else ['cpu', 'cuda'],
            'scope': ('Dependency and device discovery; no weight load or memory adequacy check.' if probe_devices else 'Dependency discovery only; no device probe, weight load or memory adequacy check.')}


def select_backend(requested, config, capabilities=None, experimental_cpu=False):
    if requested == 'cpu' and not experimental_cpu:
        raise ValueError('CPU is experimental; explicit --experimental-cpu is required')
    capabilities = discover_capabilities(experimental_cpu=experimental_cpu) if capabilities is None else capabilities
    entries = {entry['backend']: entry for entry in capabilities['backends']}
    # Preserve the legacy auto preference; never retry another backend after load.
    kind = ('mlx' if 'mlx_lm' not in entries['mlx']['missing_dependencies'] else 'torch') if requested == 'auto' else requested
    if kind not in entries:
        raise ValueError('Unsupported backend; no fallback was started')
    entry = entries[kind]
    if not entry['host_supported']:
        raise ValueError(f'{kind} is unavailable on this host; use an explicitly configured compatible runtime')
    if entry['missing_dependencies']:
        raise ValueError(f"{kind} requires installed dependencies: {', '.join(entry['missing_dependencies'])}")
    if config.get('architectures') != ['Qwen3_5ForConditionalGeneration']:
        raise ValueError('Unsupported model architecture')
    if kind in ('torch', 'cpu') and (config.get('quantization') is not None or config.get('quantization_config') is not None):
        raise ValueError('Torch requires compatible unquantized weights; MLX/other quantized folders are not supported')
    return kind


class MLXBackend:
    kind = 'mlx'
    device = 'metal'

    def __init__(self, folder):
        import mlx.core as mx
        if not mx.metal.is_available():
            raise RuntimeError('MLX Metal unavailable; no fallback was started')
        from mlx_lm import load
        self.model, self.tokenizer = load(str(folder))

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
        from mlx_lm import stream_generate
        from mlx_lm.sample_utils import make_sampler
        result = None
        for result in stream_generate(self.model, self.tokenizer, prompt=prompt, max_tokens=tokens, sampler=make_sampler(temp=0), prefill_step_size=256, prompt_progress_callback=check):
            check()
            if result.text:
                publish('token', result.text)
        return {'finish_reason': result.finish_reason if result else 'stop', 'tokens_per_second': result.generation_tps if result else 0, 'peak_memory_gb': result.peak_memory if result else 0}


class TorchMPSBackend:
    kind = 'torch'
    device = 'mps'

    def __init__(self, folder):
        import torch
        if not torch.backends.mps.is_available():
            raise RuntimeError('Apple Metal MPS unavailable; no fallback was started')
        from transformers import AutoTokenizer, Qwen3_5ForConditionalGeneration
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
        import torch
        from transformers import TextStreamer, StoppingCriteria, StoppingCriteriaList
        class TokenStreamer(TextStreamer):
            def on_finalized_text(self, text, stream_end=False):
                check()
                if text:
                    publish('token', text)
        class Stop(StoppingCriteria):
            def __call__(self, *_args, **_kwargs):
                return cancelled.is_set() or time.monotonic() > deadline
        inputs = self.tokenizer(prompt, return_tensors='pt').to(self.device)
        check()
        with torch.inference_mode():
            output = self.model.generate(**inputs, max_new_tokens=tokens, do_sample=False, streamer=TokenStreamer(self.tokenizer, skip_prompt=True, skip_special_tokens=True), stopping_criteria=StoppingCriteriaList([Stop()]))
        check()
        reason = 'length' if output.shape[-1] - inputs.input_ids.shape[-1] >= tokens else 'stop'
        return {'finish_reason': reason}



class TorchCPUBackend(TorchMPSBackend):
    """Experimental local-only float32 CPU loader; no accelerator imports/fallback.

    Stop/deadline checks surround preprocessing and each streamed output/token.
    A running native kernel/prefill cannot be preempted by Python cancellation.
    The owning runtime process remains the hard-stop boundary.
    """
    device = 'cpu'

    def __init__(self, folder, cpu_threads=2):
        if type(cpu_threads) is not int or not 1 <= cpu_threads <= 32:
            raise ValueError('CPU thread limit must be between 1 and 32')
        import torch
        torch.set_num_threads(cpu_threads)
        from transformers import AutoTokenizer, Qwen3_5ForConditionalGeneration
        self.tokenizer = AutoTokenizer.from_pretrained(folder, local_files_only=True, trust_remote_code=False)
        with torch.device('cpu'):
            self.model = Qwen3_5ForConditionalGeneration.from_pretrained(
                folder, local_files_only=True, trust_remote_code=False,
                use_safetensors=True, dtype=torch.float32, device_map=None,
                attn_implementation='eager').to('cpu').eval()


def load_backend(folder, kind, experimental_cpu=False, cpu_threads=2):
    if kind == 'mlx':
        return MLXBackend(folder)
    if kind == 'torch':
        return TorchMPSBackend(folder)
    if kind == 'cpu':
        if not experimental_cpu:
            raise ValueError('CPU is experimental; explicit --experimental-cpu is required')
        return TorchCPUBackend(folder, cpu_threads)
    raise ValueError('Unsupported backend')


def prepare_backend(requested, helper_target=None, experimental_cpu=False):
    """Check the exact requested environment; never load weights or fall back.

    Auto retains the historical module preference. Only legacy Torch prepares
    its pinned helper in the app-owned target; installed packages stay intact.
    Explicit experimental CPU checks existing loader APIs without installation.
    """
    if requested not in ('auto', 'mlx', 'torch', 'cpu'):
        raise ValueError('Unsupported preparation backend')
    if (requested == 'cpu') != bool(experimental_cpu):
        raise ValueError('CPU preparation requires --prepare cpu --experimental-cpu together')
    if requested == 'cpu':
        # Import the installed loader APIs only. Never construct a model, probe
        # accelerators, change thread defaults or install into the environment.
        import torch
        from transformers import AutoTokenizer, Qwen3_5ForConditionalGeneration
        from safetensors.torch import load_file
        if not all(callable(api) for api in (
                torch.set_num_threads, torch.device, AutoTokenizer.from_pretrained,
                Qwen3_5ForConditionalGeneration.from_pretrained, load_file)):
            raise RuntimeError('CPU loader APIs unavailable; no fallback was started')
        return 'cpu'
    if not helper_target:
        raise ValueError('Legacy preparation requires --helper-target')
    kind = ('mlx' if importlib.util.find_spec('mlx_lm') else 'torch') if requested == 'auto' else requested
    if kind == 'mlx':
        import mlx.core as mx
        if not mx.metal.is_available():
            raise RuntimeError('MLX Metal unavailable; no fallback was started')
        from mlx_lm import load, stream_generate
    else:
        import torch
        from transformers import Qwen3_5ForConditionalGeneration
        if not torch.backends.mps.is_available():
            raise RuntimeError('Apple Metal MPS unavailable; no fallback was started')
        import subprocess
        import sys
        subprocess.run([sys.executable, '-m', 'pip', 'install', '--no-deps',
                        '--target', helper_target, 'accelerate==1.15.0'], check=True)
    return kind


if __name__ == '__main__':
    import argparse
    parser = argparse.ArgumentParser(description='Prepare the explicitly selected runtime environment; no weights loaded.')
    parser.add_argument('--prepare', choices=('auto', 'mlx', 'torch', 'cpu'), required=True)
    parser.add_argument('--helper-target')
    parser.add_argument('--experimental-cpu', action='store_true', help='Check existing CPU loader APIs only; CPU inference remains unverified')
    args = parser.parse_args()
    if (args.prepare == 'cpu') != args.experimental_cpu:
        parser.error('CPU preparation requires --prepare cpu --experimental-cpu together')
    if args.prepare != 'cpu' and not args.helper_target:
        parser.error('--helper-target is required for legacy preparation')
    prepared = prepare_backend(args.prepare, args.helper_target, experimental_cpu=args.experimental_cpu)
    print(f'{prepared} runtime dependencies checked; model loading and memory adequacy remain unverified.')
