"""Candidate sandbox boundary probes; native execution is macOS-only."""
import json
import os
from pathlib import Path
import platform
import subprocess
import tempfile
import sys
import errno
import threading
import signal
import time

from generation_command import run
import unittest
from unittest.mock import patch

from generation_command import candidate_profile, confined_operation


def native_python():
    # Framework bin/python is a posix_spawn launcher on macOS. Launch the real
    # interpreter so probes exercise candidate code, not a denied launcher shim.
    executable = Path(sys.base_prefix) / 'Resources/Python.app/Contents/MacOS/Python'
    return str(executable if executable.is_file() else Path(sys.executable).resolve())


class PolicyTests(unittest.TestCase):
    def test_profile_quotes_paths_and_denies_by_default(self):
        profile = candidate_profile('/tmp/candidate"(allow default)', '/sdk', '/cache', '/temp')
        self.assertIn('(deny default)', profile)
        self.assertNotIn('(allow default)', profile.splitlines()[1])
        self.assertIn(json.dumps('/tmp/candidate"(allow default)'), profile)
        self.assertNotIn('(allow network*)', profile)
        self.assertIn('(target same-sandbox)', profile)

    def test_unsupported_platform_fails_closed(self):
        with patch('generation_command.platform.system', return_value='Linux'):
            with self.assertRaisesRegex(RuntimeError, 'macOS'):
                confined_operation(Path('/candidate'), '/sdk', 'test', 1, os.getpid())

    @unittest.skipUnless(platform.system() == 'Darwin', 'native Seatbelt requires macOS')
    def test_inherited_confinement_boundaries(self):
        with tempfile.TemporaryDirectory(prefix='asg-policy-test-') as temp:
            root = Path(temp).resolve()
            candidate, scratch, sdk, cache = [root / name for name in ('candidate', 'scratch', 'sdk', 'cache')]
            for folder in (candidate, scratch, sdk, cache):
                folder.mkdir()
            private = root / 'private'; private.write_text('PRIVATE_SENTINEL')
            shared = sdk / 'shared'; shared.write_text('READ_ONLY')
            (candidate / 'escape').symlink_to(private)
            profile = root / 'candidate.sb'
            profile.write_text(candidate_profile(candidate, sdk, cache, scratch))
            def probe(arguments):
                return subprocess.run(['/usr/bin/sandbox-exec', '-f', str(profile), *arguments],
                                      capture_output=True, text=True, timeout=10)
            for filename in (private, candidate / 'escape'):
                result = probe(['/bin/cat', str(filename)])
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn('PRIVATE_SENTINEL', result.stdout)
            for filename in (private, shared):
                result = probe(['/bin/sh', '-c', 'echo denied > "$1"', 'probe', str(filename)])
                self.assertNotEqual(result.returncode, 0)
            self.assertEqual(probe(['/bin/cat', str(shared)]).stdout, 'READ_ONLY')
            self.assertEqual(probe(['/bin/sh', '-c', 'echo allowed > "$1"', 'probe', str(candidate / 'allowed')]).returncode, 0)
            self.assertEqual(probe(['/bin/sh', '-c', 'echo allowed > "$1"', 'probe', str(scratch / 'allowed')]).returncode, 0)
            result = probe([native_python(), '-I', '-c',
                            "import socket; s=socket.socket(); s.settimeout(1); print(s.connect_ex(('203.0.113.1',9)))"])
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(int(result.stdout.strip()), errno.EPERM)
            child = subprocess.Popen(['/bin/sleep', '10'])
            try:
                self.assertNotEqual(probe(['/bin/kill', str(child.pid)]).returncode, 0)
                self.assertIsNone(child.poll())
            finally:
                child.terminate(); child.wait(timeout=3)
            self.assertEqual(private.read_text(), 'PRIVATE_SENTINEL')
            self.assertEqual(shared.read_text(), 'READ_ONLY')

    @unittest.skipUnless(platform.system() == 'Darwin', 'native Seatbelt requires macOS')
    def test_candidate_children_cannot_escape_success_timeout_or_cancellation(self):
        with tempfile.TemporaryDirectory(prefix='asg-lifetime-test-') as temp:
            root = Path(temp).resolve()
            candidate, scratch = root / 'candidate', root / 'scratch'
            candidate.mkdir(); scratch.mkdir()
            profile = root / 'candidate.sb'
            profile.write_text(candidate_profile(candidate, '/sdk', '/cache', scratch))
            for mode in ('success', 'timeout', 'cancel'):
                for variant in ('normal_child', 'fork_setsid', 'fork_setpgid',
                                'subprocess_session', 'subprocess_group',
                                'spawn_session', 'spawn_group'):
                    with self.subTest(mode=mode, variant=variant):
                        late = candidate / (mode + '-' + variant)
                        child = "import time; from pathlib import Path; time.sleep(.35); Path(" + repr(str(late)) + ").write_text('late')"
                        argv = repr([native_python(), '-I', '-c', child])
                        if variant.startswith('fork_'):
                            action = "os.setsid()" if variant == 'fork_setsid' else "os.setpgid(0,0)"
                            launch = ("pid=os.fork()\nif pid==0:\n try:\n  " + action +
                                      "\n except PermissionError: os._exit(0)\n exec(" + repr(child) + ")\n os._exit(0)\n")
                        elif variant.startswith('spawn_'):
                            flag = 'setsid=True' if variant == 'spawn_session' else 'setpgroup=0'
                            launch = "try: os.posix_spawn(sys.executable," + argv + ",{}," + flag + ")\nexcept PermissionError: pass\n"
                        else:
                            flag = ',start_new_session=True' if variant == 'subprocess_session' else ',process_group=0' if variant == 'subprocess_group' else ''
                            launch = "try: subprocess.Popen(" + argv + ",stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL" + flag + ")\nexcept PermissionError: pass\n"
                        if variant == 'normal_child': launch += "else: print('launched',flush=True)\n"
                        code = 'import os,sys,subprocess,time\n' + launch
                        if mode != 'success': code += 'time.sleep(2)\n'
                        timer = None
                        if mode == 'cancel':
                            timer = threading.Timer(.12, lambda: os.kill(os.getpid(), signal.SIGTERM))
                            timer.start()
                        try:
                            result = run('/usr/bin/sandbox-exec', ['-f',str(profile),native_python(),'-I','-c',code],
                                         str(candidate), .12 if mode == 'timeout' else 3)
                        finally:
                            if timer: timer.cancel(); timer.join()
                        if mode == 'success': self.assertEqual(result['exitCode'],0,result['output'])
                        if variant == 'normal_child': self.assertIn('launched',result['output'])
                        if mode == 'timeout': self.assertTrue(result['timedOut'],result)
                        if mode == 'cancel': self.assertTrue(result['cancelled'],result)
                        time.sleep(.4)
                        self.assertFalse(late.exists(), 'candidate descendant escaped after ' + mode + ': ' + variant)


if __name__ == '__main__':
    unittest.main()
