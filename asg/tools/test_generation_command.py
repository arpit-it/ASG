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

    def test_named_target_requires_confined_test_and_complete_selectors(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp).resolve()
            (root / 'test').mkdir()
            (root / 'test/a_test.dart').touch()
            base = ['runner', '--sdk', str(root), '--directory', str(root)]
            selectors = ['--test-file', 'test/a_test.dart', '--test-name', 'group literal .* [中文]']
            for operation, extra in [('test', selectors), ('build', ['--confined', *selectors]),
                                     ('test', ['--confined', *selectors[:2]]),
                                     ('test', ['--confined', *selectors[2:]])]:
                with self.subTest(operation=operation, extra=extra), mock.patch.object(sys, 'argv', base + ['--operation', operation, *extra]), mock.patch.object(module, 'run') as run, mock.patch.object(module, 'confined_operation') as confined, contextlib.redirect_stderr(io.StringIO()):
                    with self.assertRaises(SystemExit):
                        module.main()
                    run.assert_not_called(); confined.assert_not_called()
            with mock.patch.object(sys, 'argv', base + ['--operation', 'test', '--confined', *selectors]), mock.patch.object(module, 'confined_operation', return_value={'exitCode': 0}) as confined, contextlib.redirect_stdout(io.StringIO()):
                module.main()
                confined.assert_called_once_with(root, str(root), 'test', 180, os.getppid(),
                                                 test_file='test/a_test.dart', test_name='group literal .* [中文]')

    def test_named_target_literal_argv_and_path_policy(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp).resolve()
            (root / 'test').mkdir()
            (root / 'test/a_test.dart').touch()
            name = ' group literal .* [中文] $;`command` '
            arguments = module.named_test_arguments(root, 'test/a_test.dart', name)
            self.assertEqual(arguments[:5], ['test', '--no-pub', '--reporter', 'json', '--name'])
            self.assertEqual(arguments[-1], 'test/a_test.dart')
            self.assertIsNotNone(module.re.fullmatch(arguments[-2], name))
            for different in (name + 'suffix', 'prefix' + name, name.strip()):
                self.assertIsNone(module.re.fullmatch(arguments[-2], different))
            for file in ('../a_test.dart', '/test/a_test.dart', 'test/../a_test.dart',
                         'test/a.dart', 'test/a_test.dart --help', 'test/a_test.dart\n',
                         'test//a_test.dart', 'test/-a_test.dart', 'test/missing_test.dart'):
                with self.subTest(file=file), self.assertRaises(ValueError):
                    module.named_test_arguments(root, file, name)
            for bad_name in ('', ' ', 'a' * 201, 'a\nb', 'a\x00b'):
                with self.assertRaises(ValueError):
                    module.named_test_arguments(root, 'test/a_test.dart', bad_name)
            (root / 'test/linked_test.dart').symlink_to(root / 'test/a_test.dart')
            (root / 'test/linked').symlink_to(root / 'test', target_is_directory=True)
            for file in ('test/linked_test.dart', 'test/linked/a_test.dart'):
                with self.assertRaisesRegex(ValueError, 'Linked'):
                    module.named_test_arguments(root, file, name)
            with mock.patch.object(module, 'run') as run:
                with self.assertRaises(ValueError):
                    module.confined_operation(root, str(root), 'build', 180, os.getppid(), 'test/a_test.dart', name)
                run.assert_not_called()

    def test_named_json_result_requires_one_completed_unskipped_exact_test(self):
        name = 'group literal .* [中文]'
        events = [
            {'type': 'start', 'protocolVersion': '0.1.1'},
            {'type': 'testStart', 'test': {'id': 1, 'name': 'loading'}},
            {'type': 'testDone', 'testID': 1, 'result': 'success', 'skipped': False, 'hidden': True},
            {'type': 'testStart', 'test': {'id': 2, 'name': name}},
            {'type': 'print', 'message': 'PRIVATE_TEXT'},
            {'type': 'testDone', 'testID': 2, 'result': 'success', 'skipped': False, 'hidden': False},
            {'type': 'done', 'success': True},
        ]
        def result(values=events, **overrides):
            return module.named_test_result({'exitCode': 0, 'cancelled': False,
                'timedOut': False, 'outputLimitExceeded': False,
                'output': '\n'.join(json.dumps(v) for v in values), **overrides}, 'test/a_test.dart', name)
        good = result()
        self.assertEqual(good['exitCode'], 0)
        self.assertEqual(good['targetedTest']['status'], 'passed')
        self.assertNotIn('PRIVATE_TEXT', json.dumps(good))
        variants = [events[:-1], events + [events[-1]], events[1:],
                    events[:3] + events[-1:],
                    events[:5] + events[-1:],
                    events[:5] + [events[5], events[5], events[-1]],
                    events[:5] + [dict(events[5], skipped=True), events[-1]],
                    events[:5] + [dict(events[5], result='failure'), events[-1]],
                    events[:5] + [dict(events[5], testID=99), events[-1]],
                    events[:5] + [dict(events[5], hidden=True), events[-1]],
                    events[:5] + [dict(events[5], hidden=0), events[-1]],
                    events[:3] + [dict(events[3], test={'id': 2, 'name': name + ' suffix'})] + events[4:],
                    events[:3] + [events[3], events[3]] + events[4:],
                    events[:-1] + [dict(events[3], test={'id': 3, 'name': name}), dict(events[5], testID=3), events[-1]],
                    events[:-1] + [{'type': 'error'}, events[-1]],
                    events[:-1] + [dict(events[-1], success=False)],
                    events[:-1] + [dict(events[-1], success=1)],
                    events[:-1] + [None, events[-1]],
                    [dict(events[0], protocolVersion='future')] + events[1:]]
        for values in variants:
            with self.subTest(values=values):
                failed = result(values)
                self.assertNotEqual(failed['exitCode'], 0)
                self.assertEqual(failed['targetedTest']['status'], 'notPassed')
                self.assertNotIn('PRIVATE_TEXT', json.dumps(failed))
        for overrides in ({'exitCode': 7}, {'cancelled': True}, {'timedOut': True},
                          {'outputLimitExceeded': True}, {'output': 'not json'}):
            with self.subTest(overrides=overrides):
                self.assertNotEqual(result(**overrides)['exitCode'], 0)

    @unittest.skipUnless(sys.platform == 'darwin' and os.environ.get('ASG_REAL_NAMED_TEST_SDK'),
                         'opt-in initialized macOS Flutter SDK required')
    def test_real_confined_named_test_pass_skip_missing_and_failure(self):
        sdk = os.environ['ASG_REAL_NAMED_TEST_SDK']
        with tempfile.TemporaryDirectory(prefix='asg-named-test-') as temp:
            root = Path(temp).resolve()
            (root / 'test').mkdir()
            (root / 'pubspec.yaml').write_text(
                'name: named_fixture\nenvironment:\n  sdk: ">=3.9.0 <4.0.0"\n'
                'dependencies:\n  flutter:\n    sdk: flutter\n'
                'dev_dependencies:\n  flutter_test:\n    sdk: flutter\n')
            (root / 'test/named_test.dart').write_text(
                "import 'package:flutter_test/flutter_test.dart';\n"
                "void main() { test('literal [x].*', () => expect(2 + 2, 4)); "
                "test('literal [x].* suffix', () => fail('PRIVATE_FAILURE')); "
                "test('skipped', () {}, skip: true); }\n")
            resolved = module.confined_operation(root, sdk, 'resolve', 180, os.getppid())
            self.assertEqual(resolved['exitCode'], 0, resolved['output'])
            for name, passed in [('literal [x].*', True), ('literal [x].* suffix', False),
                                 ('skipped', False), ('missing', False)]:
                with self.subTest(name=name):
                    result = module.confined_operation(root, sdk, 'test', 180, os.getppid(),
                                                       'test/named_test.dart', name)
                    self.assertEqual(result['exitCode'] == 0, passed, result)
                    self.assertEqual(result['targetedTest']['status'], 'passed' if passed else 'notPassed')
                    self.assertNotIn('PRIVATE_FAILURE', json.dumps(result))
                    self.assertNotIn(str(root), json.dumps(result))

    def test_operations_are_fixed_and_no_remote_package_install(self):
        self.assertEqual(set(module.OPERATIONS), {'resolve', 'analyze', 'test', 'build'})
        self.assertIn('--offline', module.OPERATIONS['resolve'])
        self.assertIn('--no-pub', module.OPERATIONS['build'])

if __name__ == '__main__':
    unittest.main()
