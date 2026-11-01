# SPDX-License-Identifier: MPL-2.0
# Copyright 2026 Arpit Sinha
"""Dependency-free contract/discovery regressions; no inference claims."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import shutil
import sys
from threading import Event
import time
import unittest
from unittest.mock import patch

import qwen_backends as backends

CONFIG = {'architectures': ['Qwen3_5ForConditionalGeneration']}


class BackendTests(unittest.TestCase):
    def capabilities(self, system='Darwin', machine='arm64', missing=()):
        return backends.discover_capabilities(system, machine, lambda name: name not in missing)

    def test_discovery_never_imports_optional_dependencies(self):
        with patch('builtins.__import__', side_effect=AssertionError('import during discovery')):
            result = self.capabilities()
        self.assertEqual(result['unsupported_devices'], ['cpu', 'cuda'])
        for entry in result['backends']:
            self.assertIsNone(entry['device_ready'])
            self.assertIsNone(entry['model_compatible'])
            self.assertEqual(entry['readiness'], 'unverified')

    def test_host_and_missing_dependencies_are_distinct_from_device_readiness(self):
        for system, machine in [('Linux', 'x86_64'), ('Windows', 'AMD64')]:
            for entry in self.capabilities(system, machine)['backends']:
                self.assertFalse(entry['host_supported'])
                self.assertEqual(entry['readiness'], 'unavailable')
        entries = self.capabilities(machine='x86_64')['backends']
        self.assertFalse(entries[0]['host_supported'])
        self.assertTrue(entries[1]['host_supported'])
        missing = self.capabilities(missing=('mlx_lm',))['backends'][0]
        self.assertEqual(missing['missing_dependencies'], ['mlx_lm'])
        self.assertIsNone(missing['device_ready'])

    def test_opt_in_device_probe_skips_unsupported_and_missing_dependencies(self):
        with patch.object(backends, 'probe_device', side_effect=AssertionError('probe')):
            self.capabilities()
            backends.discover_capabilities('Linux', 'x86_64', lambda _: True, True)
            backends.discover_capabilities('Darwin', 'arm64', lambda _: False, True)

    def test_device_probe_distinguishes_available_unavailable_and_error(self):
        for ready in (True, False, None):
            with self.subTest(ready=ready), patch.object(backends, 'probe_device', return_value=ready) as probe:
                result = backends.discover_capabilities('Darwin', 'arm64', lambda _: True, True)
                self.assertEqual(probe.call_count, 2)
                for entry in result['backends']:
                    self.assertIs(entry['device_ready'], ready)
                    self.assertIsNone(entry['model_compatible'])
                    self.assertEqual(entry['readiness'], 'unavailable' if ready is False else 'unverified')

    def test_device_api_imports_never_load_models_and_suppress_private_output(self):
        from types import SimpleNamespace
        from contextlib import redirect_stdout, redirect_stderr
        from io import StringIO
        def status():
            print('PRIVATE /secret')
            print('PRIVATE token', file=sys.stderr)
            return True
        for kind, module in [('mlx', SimpleNamespace(metal=SimpleNamespace(is_available=status))),
                             ('torch', SimpleNamespace(backends=SimpleNamespace(mps=SimpleNamespace(is_available=status))))]:
            output, error = StringIO(), StringIO()
            with patch.object(backends.importlib, 'import_module', return_value=module) as imported, redirect_stdout(output), redirect_stderr(error):
                self.assertTrue(backends.probe_device(kind))
            imported.assert_called_once_with('mlx.core' if kind == 'mlx' else 'torch')
            self.assertEqual(output.getvalue(), '')
            self.assertEqual(error.getvalue(), '')
        for failure in (ImportError('PRIVATE /secret'), RuntimeError('PRIVATE token')):
            with patch.object(backends.importlib, 'import_module', side_effect=failure):
                self.assertIsNone(backends.probe_device('mlx'))
        with patch.object(backends.importlib, 'import_module', return_value=SimpleNamespace(metal=SimpleNamespace(is_available=lambda: 'PRIVATE'))):
            self.assertIsNone(backends.probe_device('mlx'))

    def test_real_cli_device_probe_is_opt_in_and_needs_no_weights(self):
        command = [sys.executable, '-B', str(Path(__file__).with_name('qwen_server.py'))]
        result = subprocess.run([*command, '--capabilities', '--probe-devices'], capture_output=True, text=True, timeout=10, check=True)
        data = json.loads(result.stdout)
        self.assertEqual(data['schema_version'], 1)
        self.assertEqual(result.stderr, '')
        self.assertTrue(all(entry['model_compatible'] is None for entry in data['backends']))
        invalid = subprocess.run([*command, '--probe-devices'], capture_output=True, text=True, timeout=10)
        self.assertNotEqual(invalid.returncode, 0)
        self.assertIn('--probe-devices requires --capabilities', invalid.stderr)

    def test_explicit_selection_and_auto_do_not_load_or_retry(self):
        caps = self.capabilities()
        with patch.object(backends, 'load_backend', side_effect=AssertionError('load')):
            self.assertEqual(backends.select_backend('auto', CONFIG, caps), 'mlx')
            self.assertEqual(backends.select_backend('torch', CONFIG, caps), 'torch')
        for name in ('cuda', 'other'):
            with self.assertRaisesRegex(ValueError, 'Unsupported backend'):
                backends.select_backend(name, CONFIG, caps)
        with self.assertRaisesRegex(ValueError, 'unavailable on this host'):
            backends.select_backend('mlx', CONFIG, self.capabilities(system='Linux'))
        with self.assertRaisesRegex(ValueError, 'requires installed dependencies'):
            backends.select_backend('mlx', CONFIG, self.capabilities(missing=('mlx',)))

    def test_torch_rejects_quantized_folders_before_load(self):
        for field in ('quantization', 'quantization_config'):
            for quantization in ({'bits': 4}, {}, 'unknown'):
                with self.assertRaisesRegex(ValueError, 'unquantized weights'):
                    backends.select_backend('torch', {**CONFIG, field: quantization}, self.capabilities())
        with self.assertRaisesRegex(ValueError, 'Unsupported model architecture'):
            backends.select_backend('mlx', {'architectures': ['Other']}, self.capabilities())

    def test_unavailable_devices_fail_before_model_import(self):
        from types import SimpleNamespace
        for kind, cls, modules in (
            ('mlx', backends.MLXBackend, {'mlx': SimpleNamespace(core=SimpleNamespace(metal=SimpleNamespace(is_available=lambda: False))), 'mlx.core': SimpleNamespace(metal=SimpleNamespace(is_available=lambda: False))}),
            ('torch', backends.TorchMPSBackend, {'torch': SimpleNamespace(backends=SimpleNamespace(mps=SimpleNamespace(is_available=lambda: False)))})
        ):
            with self.subTest(kind=kind), patch.dict(sys.modules, modules):
                with self.assertRaisesRegex(RuntimeError, 'unavailable; no fallback'):
                    cls(Path('/nonexistent'))

    def test_both_backends_preserve_early_stop_and_deadline(self):
        for cls in (backends.MLXBackend, backends.TorchMPSBackend, backends.TorchCPUBackend):
            instance = object.__new__(cls)
            cancelled = Event()
            cancelled.set()
            with self.assertRaises(backends.GenerationCancelled):
                instance.generate([], 1, None, cancelled, time.monotonic() + 10)
            with self.assertRaises(TimeoutError):
                instance.generate([], 1, None, Event(), time.monotonic() - 1)

    def test_extracted_sibling_assets_work_in_paths_with_spaces(self):
        with tempfile.TemporaryDirectory(prefix='asg runtime assets ') as temporary:
            root = Path(temporary)
            for name in ('qwen_server.py', 'qwen_backends.py'):
                shutil.copyfile(Path(__file__).with_name(name), root / name)
            result = subprocess.run([sys.executable, '-B', str(root / 'qwen_server.py'), '--capabilities'],
                                    cwd='/', capture_output=True, text=True, timeout=10, check=True)
            self.assertEqual(json.loads(result.stdout)['schema_version'], 1)

    def test_preparation_honors_explicit_backend_and_auto_without_model_load(self):
        from types import SimpleNamespace, ModuleType
        mlx = ModuleType('mlx')
        mlx.__path__ = []
        core = ModuleType('mlx.core')
        core.metal = SimpleNamespace(is_available=lambda: True)
        mlx.core = core
        modules = {'mlx': mlx, 'mlx.core': core,
                   'mlx_lm': SimpleNamespace(load=lambda: self.fail('weight load'), stream_generate=None),
                   'torch': SimpleNamespace(backends=SimpleNamespace(mps=SimpleNamespace(is_available=lambda: True))),
                   'transformers': SimpleNamespace(Qwen3_5ForConditionalGeneration=None)}
        for requested, installed, expected in [('mlx', False, 'mlx'), ('torch', True, 'torch'),
                                                ('auto', True, 'mlx'), ('auto', False, 'torch')]:
            with self.subTest(requested=requested, installed=installed), patch.dict(sys.modules, modules), patch.object(backends.importlib.util, 'find_spec', return_value=installed), patch('subprocess.run') as run:
                self.assertEqual(backends.prepare_backend(requested, '/target with spaces'), expected)
                if expected == 'mlx':
                    run.assert_not_called()
                else:
                    run.assert_called_once_with([sys.executable, '-m', 'pip', 'install', '--no-deps', '--target', '/target with spaces', 'accelerate==1.15.0'], check=True)

    def test_missing_or_unavailable_explicit_backend_never_falls_back_or_installs(self):
        from types import SimpleNamespace
        for requested in ('mlx', 'torch'):
            modules = {'mlx': None, 'mlx.core': None, 'mlx_lm': None} if requested == 'mlx' else {'torch': None}
            with self.subTest(requested=requested), patch.dict(sys.modules, modules), patch('subprocess.run') as run:
                with self.assertRaises(ImportError):
                    backends.prepare_backend(requested, '/target')
                run.assert_not_called()
        with patch.dict(sys.modules, {'torch': SimpleNamespace(backends=SimpleNamespace(mps=SimpleNamespace(is_available=lambda: False))), 'transformers': SimpleNamespace(Qwen3_5ForConditionalGeneration=None)}), patch('subprocess.run') as run:
            with self.assertRaisesRegex(RuntimeError, 'unavailable; no fallback'):
                backends.prepare_backend('torch', '/target')
            run.assert_not_called()
        with patch('subprocess.run') as run:
            with self.assertRaises(ValueError):
                backends.prepare_backend('cuda', '/target')
            run.assert_not_called()

    def test_real_cli_needs_no_model_and_outputs_only_json(self):
        command = [sys.executable, '-B', str(Path(__file__).with_name('qwen_server.py'))]
        result = subprocess.run([*command, '--capabilities'], capture_output=True, text=True, timeout=10, check=True)
        data = json.loads(result.stdout)
        self.assertEqual(data['schema_version'], 1)
        self.assertEqual(result.stderr, '')
        missing = subprocess.run(command, capture_output=True, text=True, timeout=10)
        self.assertNotEqual(missing.returncode, 0)
        self.assertIn('--model is required', missing.stderr)


class CPUBackendTests(unittest.TestCase):
    """Execute the real backend against injected tensor/model APIs, not inference."""
    def setUp(self):
        from contextlib import nullcontext
        from types import SimpleNamespace
        from unittest.mock import Mock

        class Batch(dict):
            input_ids = SimpleNamespace(shape=(1, 3))
            def to(self, device):
                self.device = device
                return self
        class Streamer:
            def __init__(self, tokenizer, **kwargs):
                self.tokenizer = tokenizer
                self.options = kwargs
        self.batch = Batch(input_ids=Batch.input_ids)
        self.tokenizer = Mock()
        self.tokenizer.apply_chat_template.return_value = 'prompt'
        self.tokenizer.encode.return_value = [1, 2, 3]
        self.tokenizer.return_value = self.batch
        self.model = Mock()
        self.model.eval.return_value = self.model
        self.model.to.return_value = self.model
        self.expected_device = 'cpu'
        self.output_length = 4
        def generate(**kwargs):
            self.assertEqual(self.batch.device, self.expected_device)
            if kwargs['stopping_criteria'][0](None, None):
                return SimpleNamespace(shape=(1, 3))
            kwargs['streamer'].on_finalized_text('Hello ')
            kwargs['streamer'].on_finalized_text('CPU', stream_end=True)
            return SimpleNamespace(shape=(1, self.output_length))
        self.model.generate.side_effect = generate
        self.torch = SimpleNamespace(float32='float32', set_num_threads=Mock(), inference_mode=nullcontext, device=Mock(side_effect=lambda _: nullcontext()))
        self.transformers = SimpleNamespace(
            AutoTokenizer=SimpleNamespace(from_pretrained=Mock(return_value=self.tokenizer)),
            Qwen3_5ForConditionalGeneration=SimpleNamespace(from_pretrained=Mock(return_value=self.model)),
            TextStreamer=Streamer, StoppingCriteria=type('StoppingCriteria', (), {}),
            StoppingCriteriaList=list)
        self.modules = patch.dict(sys.modules, {'torch': self.torch, 'transformers': self.transformers,
                                               'mlx': None, 'mlx_lm': None, 'accelerate': None})
        self.modules.start()
        self.addCleanup(self.modules.stop)
        self.backend = backends.load_backend(Path('/local model with spaces'), 'cpu', experimental_cpu=True, cpu_threads=3)

    def caps(self, system='Linux', missing=()):
        return backends.discover_capabilities(system, 'x86_64', lambda name: name not in missing, experimental_cpu=True)

    def test_cpu_discovery_is_opt_in_no_import_or_device_probe_and_unverified(self):
        with patch('builtins.__import__', side_effect=AssertionError('optional import')), patch.object(backends, 'probe_device', side_effect=AssertionError('GPU probe')):
            caps = self.caps(missing=('mlx', 'mlx_lm', 'accelerate'))
        cpu = caps['backends'][-1]
        self.assertEqual((cpu['backend'], cpu['device'], cpu['missing_dependencies']), ('cpu', 'cpu', []))
        self.assertTrue(cpu['host_supported'])
        self.assertIsNone(cpu['device_ready'])
        self.assertEqual(cpu['readiness'], 'unverified')
        self.assertEqual(caps['unsupported_devices'], ['cuda'])
        for system in ('Darwin', 'Linux', 'Windows'):
            self.assertEqual(backends.select_backend('cpu', CONFIG, self.caps(system), experimental_cpu=True), 'cpu')
        with self.assertRaisesRegex(ValueError, 'unavailable on this host'):
            backends.select_backend('cpu', CONFIG, self.caps('Other'), experimental_cpu=True)

    def test_selection_and_loading_require_opt_in_and_do_not_fall_back(self):
        with self.assertRaisesRegex(ValueError, 'experimental'):
            backends.select_backend('cpu', CONFIG, self.caps())
        with self.assertRaisesRegex(ValueError, 'experimental'):
            backends.load_backend(Path('/missing'), 'cpu')
        for name in ('torch', 'transformers'):
            with self.assertRaisesRegex(ValueError, 'requires installed dependencies'):
                backends.select_backend('cpu', CONFIG, self.caps(missing=(name,)), experimental_cpu=True)
        for field in ('quantization', 'quantization_config'):
            for value in ({}, {'bits': 4}, 'unknown'):
                with self.assertRaisesRegex(ValueError, 'unquantized weights'):
                    backends.select_backend('cpu', {**CONFIG, field: value}, self.caps(), experimental_cpu=True)
        with self.assertRaisesRegex(ValueError, 'architecture'):
            backends.select_backend('cpu', {'architectures': ['Other']}, self.caps(), experimental_cpu=True)
        # Auto never acquires CPU fallback, even if CPU dependencies are present.
        with self.assertRaisesRegex(ValueError, 'unavailable on this host'):
            backends.select_backend('auto', CONFIG, self.caps(missing=('mlx_lm',)), experimental_cpu=True)

    def test_loader_pins_cpu_float32_offline_safe_weights_and_threads(self):
        self.torch.set_num_threads.assert_called_once_with(3)
        folder = Path('/local model with spaces')
        self.transformers.AutoTokenizer.from_pretrained.assert_called_once_with(folder, local_files_only=True, trust_remote_code=False)
        self.transformers.Qwen3_5ForConditionalGeneration.from_pretrained.assert_called_once_with(
            folder, local_files_only=True, trust_remote_code=False, use_safetensors=True,
            dtype='float32', device_map=None, attn_implementation='eager')
        self.torch.device.assert_called_once_with('cpu')
        self.model.to.assert_called_once_with('cpu')
        self.assertEqual((self.backend.kind, self.backend.device), ('torch', 'cpu'))
        for threads in (0, 33, True, '2'):
            with self.assertRaisesRegex(ValueError, 'thread limit'):
                backends.load_backend(folder, 'cpu', experimental_cpu=True, cpu_threads=threads)
        self.torch.set_num_threads.assert_called_once()

    def test_streaming_and_length_are_actual_backend_results(self):
        events = []
        self.assertEqual(self.backend.generate([], 2, lambda *e: events.append(e), Event(), time.monotonic()+10), {'finish_reason': 'stop'})
        self.assertEqual(events, [('token', 'Hello '), ('token', 'CPU')])
        call = self.model.generate.call_args.kwargs
        self.assertEqual(call['max_new_tokens'], 2)
        self.assertFalse(call['do_sample'])
        self.assertEqual(call['streamer'].options, {'skip_prompt': True, 'skip_special_tokens': True})
        self.output_length = 5
        self.assertEqual(self.backend.generate([], 2, lambda *_: None, Event(), time.monotonic()+10), {'finish_reason': 'length'})

    def test_shared_torch_generation_preserves_mps_tensor_placement(self):
        self.expected_device = 'mps'
        mps = object.__new__(backends.TorchMPSBackend)
        mps.model, mps.tokenizer = self.model, self.tokenizer
        events = []
        self.assertEqual(mps.generate([], 2, lambda *e: events.append(e), Event(), time.monotonic()+10), {'finish_reason': 'stop'})
        self.assertEqual(self.batch.device, 'mps')
        self.assertEqual(events, [('token', 'Hello '), ('token', 'CPU')])

    def test_input_overflow_and_tokenizer_failures_do_not_generate(self):
        self.tokenizer.encode.return_value = [0] * 4097
        with self.assertRaisesRegex(ValueError, '4096-token'):
            self.backend.generate([], 2, None, Event(), time.monotonic()+10)
        self.model.generate.assert_not_called()
        self.tokenizer.apply_chat_template.side_effect = RuntimeError('tokenizer failure')
        with self.assertRaisesRegex(RuntimeError, 'tokenizer failure'):
            self.backend.generate([], 2, None, Event(), time.monotonic()+10)
        self.model.generate.assert_not_called()

    def test_stop_and_deadline_during_preprocessing_or_stream_do_not_finish(self):
        for stopped in (True, False):
            for stage in ('preprocessing', 'stream'):
                with self.subTest(stopped=stopped, stage=stage):
                    self.model.generate.reset_mock()
                    cancelled = Event()
                    now = [10.0]
                    def interrupt(*_args, **_kwargs):
                        if stopped:
                            cancelled.set()
                        else:
                            now[0] = 30.0
                        return 'prompt'
                    self.tokenizer.apply_chat_template.side_effect = interrupt if stage == 'preprocessing' else None
                    def generate(**kwargs):
                        interrupt()
                        self.assertTrue(kwargs['stopping_criteria'][0](None, None))
                        kwargs['streamer'].on_finalized_text('must not publish')
                    self.model.generate.side_effect = generate
                    events = []
                    with patch.object(backends.time, 'monotonic', side_effect=lambda: now[0]):
                        with self.assertRaises(backends.GenerationCancelled if stopped else TimeoutError):
                            self.backend.generate([], 2, lambda *e: events.append(e), cancelled, 20.0)
                    self.assertEqual(events, [])
                    if stage == 'preprocessing':
                        self.model.generate.assert_not_called()

    def test_missing_cpu_packages_or_load_failure_never_selects_other_loader(self):
        from unittest.mock import Mock
        for name in ('torch', 'transformers'):
            with patch.dict(sys.modules, {name: None}), patch.object(backends, 'MLXBackend') as mlx, patch.object(backends, 'TorchMPSBackend') as mps:
                with self.assertRaises(ImportError):
                    backends.load_backend(Path('/local'), 'cpu', experimental_cpu=True)
                mlx.assert_not_called()
                mps.assert_not_called()
        self.transformers.Qwen3_5ForConditionalGeneration.from_pretrained.side_effect = RuntimeError('load failure')
        with patch.object(backends, 'MLXBackend') as mlx:
            with self.assertRaisesRegex(RuntimeError, 'load failure'):
                backends.load_backend(Path('/local'), 'cpu', experimental_cpu=True)
            mlx.assert_not_called()

    def test_cli_start_forwards_cpu_opt_in_and_thread_limit_with_spaced_paths(self):
        import qwen_server
        from contextlib import redirect_stdout
        from io import StringIO
        from unittest.mock import Mock
        with tempfile.TemporaryDirectory(prefix='cpu model with spaces ') as temporary:
            folder = Path(temporary)
            (folder / 'config.json').write_text(json.dumps(CONFIG))
            (folder / 'model.safetensors').write_bytes(b'fixture only')
            server = Mock()
            server.serve_forever.side_effect = KeyboardInterrupt()
            caps = self.caps(missing=('mlx', 'mlx_lm', 'accelerate'))
            with patch.object(backends, 'discover_capabilities', return_value=caps), patch.object(qwen_server, 'ThreadingHTTPServer', return_value=server) as http, patch.object(sys, 'argv', ['qwen_server.py', '--backend', 'cpu', '--experimental-cpu', '--cpu-threads', '4', '--model', str(folder), '--port', '18765']), redirect_stdout(StringIO()):
                qwen_server.main()
            self.assertEqual(http.call_args.args[0], ('127.0.0.1', 18765))
            self.torch.set_num_threads.assert_called_with(4)
            self.assertEqual(self.transformers.Qwen3_5ForConditionalGeneration.from_pretrained.call_args.args, (folder.resolve(),))
            server.server_close.assert_called_once()

    def test_cli_opt_in_validation_precedes_weights_and_preserves_default_schema(self):
        command = [sys.executable, '-B', str(Path(__file__).with_name('qwen_server.py'))]
        for arguments in (['--backend', 'cpu'], ['--experimental-cpu'],
                          ['--backend', 'cpu', '--experimental-cpu', '--cpu-threads', '0'],
                          ['--backend', 'cpu', '--experimental-cpu', '--cpu-threads', '33'],
                          ['--cpu-threads', '2']):
            result = subprocess.run([*command, *arguments, '--model', '/not a model'], capture_output=True, text=True, timeout=10)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('error:', result.stderr)
            self.assertNotIn('Traceback', result.stderr)
        for arguments, count in (([], 2), (['--backend', 'cpu', '--experimental-cpu'], 3)):
            result = subprocess.run([*command, *arguments, '--capabilities'], capture_output=True, text=True, timeout=10, check=True)
            self.assertEqual(len(json.loads(result.stdout)['backends']), count)
            self.assertEqual(result.stderr, '')


@unittest.skipUnless(os.environ.get('ASG_CPU_API_FIXTURE') == '1', 'Opt-in tiny random CPU API fixture; not pretrained/non-Apple acceptance')
class CPUAPIFixtureTests(unittest.TestCase):
    def test_tiny_random_local_safetensors_load_and_generate_on_cpu(self):
        """53,792 random parameters, no downloads or pretrained-model claim."""
        import torch
        from transformers import Qwen3_5Config, Qwen3_5ForConditionalGeneration, PreTrainedTokenizerFast
        from tokenizers import Tokenizer, models, pre_tokenizers
        torch.set_num_threads(2)
        torch.manual_seed(0)
        config=Qwen3_5Config(text_config=dict(vocab_size=32,hidden_size=32,intermediate_size=64,num_hidden_layers=2,num_attention_heads=4,num_key_value_heads=2,head_dim=8,layer_types=['linear_attention','full_attention'],linear_key_head_dim=8,linear_value_head_dim=8,linear_num_key_heads=2,linear_num_value_heads=4,linear_conv_kernel_dim=4,rope_parameters={'rope_type':'default','rope_theta':10000.,'partial_rotary_factor':1.,'mrope_section':[1,1,2]},pad_token_id=0,eos_token_id=31),vision_config=dict(depth=1,hidden_size=32,intermediate_size=64,num_heads=4,out_hidden_size=32,num_position_embeddings=16,patch_size=2,spatial_merge_size=2,temporal_patch_size=2),image_token_id=29,video_token_id=30)
        with tempfile.TemporaryDirectory(prefix='asg tiny cpu API ') as temporary:
         folder=Path(temporary)
         with torch.device('cpu'):
          model=Qwen3_5ForConditionalGeneration(config).float().eval()
         params=sum(p.numel() for p in model.parameters())
         self.assertLess(params,100000)
         model.save_pretrained(folder,safe_serialization=True)
         del model
         vocab={'[PAD]':0,'[UNK]':1,**{f'word{i}':i for i in range(2,32)}}
         tok=Tokenizer(models.WordLevel(vocab,unk_token='[UNK]'));tok.pre_tokenizer=pre_tokenizers.Whitespace()
         tokenizer=PreTrainedTokenizerFast(tokenizer_object=tok,unk_token='[UNK]',pad_token='[PAD]')
         tokenizer.chat_template="{% for message in messages %}{{ message['content'] }} {% endfor %}word3"
         tokenizer.save_pretrained(folder)
         kind=backends.select_backend('cpu',json.loads((folder/'config.json').read_text()),experimental_cpu=True)
         t=time.monotonic();backend=backends.load_backend(folder,kind,experimental_cpu=True,cpu_threads=2)
         self.assertTrue(all(p.device.type=='cpu' and p.dtype==torch.float32 for p in backend.model.parameters()))
         events=[];metrics=backend.generate([{'role':'user','content':'word2'}],2,lambda *e:events.append(e),Event(),time.monotonic()+20)
         self.assertIn(metrics['finish_reason'], ('stop','length'))
         self.assertTrue(events)
         print(json.dumps({'scope':'synthetic tiny random model API fixture; not pretrained CPU acceptance','host':backends.platform.system()+' '+backends.platform.machine(),'torch':torch.__version__,'transformers':__import__('transformers').__version__,'parameters':params,'seconds':round(time.monotonic()-t,3),'events':len(events),'result':metrics,'all_parameters':'cpu/float32'}))


if __name__ == '__main__':
    unittest.main()
