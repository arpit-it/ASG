# SPDX-License-Identifier: MPL-2.0
# Copyright 2026 Arpit Sinha

import contextlib
import io
import importlib.util
import os
import json
import subprocess
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
    def test_success_failure_and_exact_output_boundary(self):
        with tempfile.TemporaryDirectory() as directory:
            result = module.run(sys.executable, ['-c', 'import sys; sys.stdout.write("x" * 65536)'], directory, 5)
            self.assertEqual(result['exitCode'], 0)
            self.assertEqual(len(result['output']), 65536)
            self.assertFalse(result['timedOut'])
            self.assertFalse(result['outputLimitExceeded'])
            self.assertFalse(result['cancelled'])
            result = module.run(sys.executable, ['-c', 'raise SystemExit(7)'], directory, 5)
            self.assertEqual(result['exitCode'], 7)
    def test_output_exhaustion_kills_descendants_and_stops_before_deadline(self):
        with tempfile.TemporaryDirectory() as directory:
            marker = str(Path(directory) / 'unexpected')
            child = 'import time; from pathlib import Path; time.sleep(1); Path(' + repr(marker) + ').write_text("bad")'
            parent = 'import subprocess,sys,time; subprocess.Popen([sys.executable,"-c",' + repr(child) + ']); sys.stdout.write("x" * 65537); sys.stdout.flush(); time.sleep(10)'
            started = time.monotonic()
            result = module.run(sys.executable, ['-c', parent], directory, 5)
            self.assertLess(time.monotonic() - started, 4)
            self.assertTrue(result['outputLimitExceeded'])
            self.assertFalse(result['timedOut'])
            self.assertNotEqual(result['exitCode'], 0)
            self.assertEqual(len(result['output']), 65536)
            time.sleep(1.1)
            self.assertFalse(Path(marker).exists())

    def test_exited_zero_command_over_limit_is_still_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            for stream in ('stdout', 'stderr'):
                result = module.run(sys.executable, ['-c', 'import sys; sys.' + stream + '.write("x" * 65537)'], directory, 5)
                self.assertTrue(result['outputLimitExceeded'])
                self.assertNotEqual(result['exitCode'], 0)
                self.assertFalse(result['timedOut'])

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
    def test_signal_cancellation_is_explicit_and_kills_descendants(self):
        with tempfile.TemporaryDirectory() as directory:
            marker = str(Path(directory) / 'unexpected')
            descendant = 'import time; from pathlib import Path; time.sleep(1); Path(' + repr(marker) + ').write_text("bad")'
            child = 'import subprocess,sys,os,signal,time; subprocess.Popen([sys.executable,"-c",' + repr(descendant) + ']); print("started",flush=True); os.kill(os.getppid(),signal.SIGTERM); time.sleep(10)'
            runner = 'import sys; sys.path.insert(0,' + repr(str(Path(__file__).parent)) + '); import generation_command as g; import json; print(json.dumps(g.run(sys.executable,["-c",' + repr(child) + '],' + repr(directory) + ',5)))'
            completed = subprocess.run([sys.executable, '-c', runner], capture_output=True, text=True, timeout=8)
            self.assertEqual(completed.returncode, 0, completed.stderr)
            result = json.loads(completed.stdout)
            self.assertTrue(result['cancelled'])
            self.assertFalse(result['timedOut'])
            self.assertNotEqual(result['exitCode'], 0)
            self.assertIn('started', result['output'])
            time.sleep(1.1)
            self.assertFalse(Path(marker).exists())

    def test_parent_loss_is_cancellation_even_when_child_exits_zero(self):
        with tempfile.TemporaryDirectory() as directory:
            ready = Path(directory) / 'ready'
            child = 'import signal,time,sys; from pathlib import Path; signal.signal(signal.SIGTERM,lambda *_: (print("stopped",flush=True),sys.exit(0))); Path(' + repr(str(ready)) + ').touch(); time.sleep(10)'
            with mock.patch.object(module.os, 'getppid', side_effect=lambda: 999 if ready.exists() else 123):
                result = module.run(sys.executable, ['-c', child], directory, 5, parent_pid=123)
            self.assertTrue(result['cancelled'])
            self.assertFalse(result['timedOut'])
            self.assertNotEqual(result['exitCode'], 0)
            self.assertIn('stopped', result['output'])

    def test_cli_rejects_policy_output_expansion_before_execution(self):
        with tempfile.TemporaryDirectory() as directory:
            for limit in ('0', '65535', '65537', '999999999'):
                result = subprocess.run(
                    [sys.executable, '-B', str(Path(__file__).with_name('generation_command.py')),
                     '--operation', 'resolve', '--sdk', directory, '--directory', directory,
                     '--output-limit', limit], capture_output=True, text=True, timeout=5)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('invalid choice', result.stderr)

    def test_cli_deadline_matches_saved_policy_before_dispatch(self):
        with tempfile.TemporaryDirectory() as directory:
            directory = str(Path(directory).resolve())
            arguments = ['generation_command.py', '--operation', 'resolve',
                         '--sdk', directory, '--directory', directory]
            for value in ('0', '1', '179', '181', '300', '301', '999999999', '1.5', 'invalid'):
                with self.subTest(timeout=value), mock.patch.object(sys, 'argv', arguments + ['--timeout', value]), mock.patch.object(module, 'run') as run, contextlib.redirect_stderr(io.StringIO()):
                    with self.assertRaises(SystemExit) as error:
                        module.main()
                    self.assertEqual(error.exception.code, 2)
                    run.assert_not_called()
            for explicit in ([], ['--timeout', '180']):
                with self.subTest(arguments=explicit), mock.patch.object(sys, 'argv', arguments + explicit), mock.patch.object(module, 'run', return_value={'exitCode': 0}) as run, contextlib.redirect_stdout(io.StringIO()):
                    module.main()
                    run.assert_called_once_with(str(Path(directory) / 'bin/flutter'),
                                                ['--no-version-check', *module.OPERATIONS['resolve']],
                                                directory, 180, os.getppid())

    def test_operations_are_fixed_and_no_remote_package_install(self):
        self.assertEqual(set(module.OPERATIONS), {'resolve', 'analyze', 'test', 'build'})
        self.assertIn('--offline', module.OPERATIONS['resolve'])
        self.assertIn('--no-pub', module.OPERATIONS['build'])

if __name__ == '__main__':
    unittest.main()
