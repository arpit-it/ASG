# SPDX-License-Identifier: MPL-2.0
# Copyright 2026 Arpit Sinha
"""Dependency-free contract/discovery regressions; no inference claims."""
import json
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
        for name in ('cpu', 'cuda', 'other'):
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
        for cls in (backends.MLXBackend, backends.TorchMPSBackend):
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


if __name__ == '__main__':
    unittest.main()
