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
