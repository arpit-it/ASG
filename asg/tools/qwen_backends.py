# SPDX-License-Identifier: MPL-2.0
# Copyright 2026 Arpit Sinha

"""Dependency-light backend discovery; inference imports occur only on load.

Discovery reports installed modules, never successful device/model readiness.
CPU/CUDA execution remains unsupported until independently delivered.
"""
import importlib.util
import platform
import time


class GenerationCancelled(Exception):
    pass


def discover_capabilities(system=None, machine=None, available=None):
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
        entries.append({'backend': kind, 'device': device,
                        'host_supported': host_supported,
                        'missing_dependencies': missing,
                        'device_ready': None, 'model_compatible': None,
                        'readiness': 'unverified' if host_supported and not missing else 'unavailable'})
    return {'schema_version': 1, 'host': {'system': system, 'machine': machine},
            'backends': entries, 'unsupported_devices': ['cpu', 'cuda'],
            'scope': 'Dependency discovery only; no device probe, weight load or memory adequacy check.'}


def select_backend(requested, config, capabilities=None):
    capabilities = discover_capabilities() if capabilities is None else capabilities
    entries = {entry['backend']: entry for entry in capabilities['backends']}
    # Preserve the legacy auto preference; never retry another backend after load.
    kind = ('mlx' if 'mlx_lm' not in entries['mlx']['missing_dependencies'] else 'torch') if requested == 'auto' else requested
    if kind not in entries:
        raise ValueError('Unsupported backend; CPU/CUDA execution is not available')
    entry = entries[kind]
    if not entry['host_supported']:
        raise ValueError(f'{kind} is unavailable on this host; use an explicitly configured compatible runtime')
    if entry['missing_dependencies']:
        raise ValueError(f"{kind} requires installed dependencies: {', '.join(entry['missing_dependencies'])}")
    if config.get('architectures') != ['Qwen3_5ForConditionalGeneration']:
        raise ValueError('Unsupported model architecture')
    if kind == 'torch' and (config.get('quantization') is not None or config.get('quantization_config') is not None):
        raise ValueError('Torch/MPS requires compatible unquantized weights; MLX/other quantized folders are not supported')
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



def load_backend(folder, kind):
    if kind == 'mlx':
        return MLXBackend(folder)
    if kind == 'torch':
        return TorchMPSBackend(folder)
    raise ValueError('Unsupported backend')
