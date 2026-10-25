"""Candidate sandbox boundary probes; native execution is macOS-only."""
import json
import os
from pathlib import Path
import platform
import subprocess
import tempfile
import sys
import errno
import unittest
from unittest.mock import patch

from generation_command import candidate_profile, confined_operation


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
            result = probe([sys.executable, '-I', '-c',
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


if __name__ == '__main__':
    unittest.main()
