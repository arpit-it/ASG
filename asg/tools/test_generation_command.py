import importlib.util
import os
from pathlib import Path
import sys
import tempfile
import time
import unittest
from unittest import mock

spec = importlib.util.spec_from_file_location('generation_command', Path(__file__).with_name('generation_command.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

@unittest.skipUnless(os.name == "posix", "POSIX process groups required")
class CommandTests(unittest.TestCase):
    def test_success_failure_and_bounded_output(self):
        with tempfile.TemporaryDirectory() as directory:
            result = module.run(sys.executable, ['-c', 'print("x" * 100000)'], directory, 5)
            self.assertEqual(result['exitCode'], 0)
            self.assertEqual(len(result['output']), 65536)
            self.assertFalse(result['timedOut'])
            result = module.run(sys.executable, ['-c', 'raise SystemExit(7)'], directory, 5)
            self.assertEqual(result['exitCode'], 7)
    def test_timeout_kills_owned_descendant_before_it_writes(self):
        with tempfile.TemporaryDirectory() as directory:
            marker = str(Path(directory) / 'unexpected')
            child = 'import time; from pathlib import Path; time.sleep(1); Path(' + repr(marker) + ').write_text("bad")'
            parent = 'import subprocess,sys,time; subprocess.Popen([sys.executable,"-c",' + repr(child) + ']); time.sleep(5)'
            result = module.run(sys.executable, ['-c', parent], directory, 0.15)
            self.assertTrue(result['timedOut'])
            time.sleep(1.1)
            self.assertFalse(Path(marker).exists())
    def test_permission_error_for_exited_group_does_not_mask_success(self):
        with tempfile.TemporaryDirectory() as directory:
            with mock.patch.object(module.os, 'killpg', side_effect=PermissionError('empty group')):
                result = module.run(sys.executable, ['-c', 'print("finished")'], directory, 5)
            self.assertEqual(result['exitCode'], 0)
            self.assertIn('finished', result['output'])
    def test_operations_are_fixed_and_no_remote_package_install(self):
        self.assertEqual(set(module.OPERATIONS), {'resolve', 'analyze', 'test', 'build'})
        self.assertIn('--offline', module.OPERATIONS['resolve'])
        self.assertIn('--no-pub', module.OPERATIONS['build'])

if __name__ == '__main__':
    unittest.main()
