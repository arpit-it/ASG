import importlib.util
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('download_model', Path(__file__).with_name('download_model.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

class DownloadTests(unittest.TestCase):
    def test_download_filters_artifacts_and_passes_revision(self):
        with tempfile.TemporaryDirectory() as root:
            destination = str(Path(root) / 'new-model')
            calls = []
            hub = types.SimpleNamespace(snapshot_download=lambda **kwargs: calls.append(kwargs))
            with patch.dict(sys.modules, {'huggingface_hub': hub}), patch.object(sys, 'argv', ['download_model', '--repository', 'Qwen/model', '--revision', 'abc123', '--destination', destination]):
                module.main()
            self.assertEqual(calls[0]['revision'], 'abc123')
            self.assertEqual(calls[0]['local_dir'], destination)
            self.assertIn('*.safetensors', calls[0]['allow_patterns'])
            self.assertIn('*.py', calls[0]['ignore_patterns'])

    def test_never_overwrites_existing_directory(self):
        with tempfile.TemporaryDirectory() as root:
            with patch.object(sys, 'argv', ['download_model', '--repository', 'Qwen/model', '--revision', 'main', '--destination', root]):
                with self.assertRaisesRegex(RuntimeError, 'refusing to overwrite'):
                    module.main()

if __name__ == '__main__':
    unittest.main()
