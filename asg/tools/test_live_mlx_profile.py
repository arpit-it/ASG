# SPDX-License-Identifier: MPL-2.0
# Copyright 2026 Arpit Sinha
"""CLI refusal regressions only; these tests never claim live inference."""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).with_name('live_mlx_profile.py')


class ProbeRefusalTest(unittest.TestCase):
    def invoke(self, folder, *extra, optimized=False):
        output = Path(folder) / 'report.json'
        args = [sys.executable, '-B'] + (['-O'] if optimized else [])
        return subprocess.run(args + [str(SCRIPT), '--origin', 'http://127.0.0.1:1',
            '--model', 'synthetic', '--checkpoint', str(Path(folder) / 'PRIVATE-CHECKPOINT'),
            '--source-revision', 'a' * 40, '--output', str(output), *extra],
            capture_output=True, timeout=5), output

    def test_explicit_live_consent_required(self):
        with tempfile.TemporaryDirectory() as folder:
            result, output = self.invoke(folder)
            self.assertEqual(result.returncode, 2)
            self.assertFalse(output.exists())

    def test_existing_report_preserved_before_any_request(self):
        with tempfile.TemporaryDirectory() as folder:
            output = Path(folder) / 'report.json'
            output.write_text('retained evidence')
            result, _ = self.invoke(folder, '--confirm-live')
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(output.read_text(), 'retained evidence')

    def test_nonlocal_or_credentialed_origins_rejected(self):
        for origin in ('https://127.0.0.1:1', 'http://example.com',
                       'http://user:secret@127.0.0.1', 'http://127.0.0.1/private',
                       'http://127.0.0.1?private=1'):
            with self.subTest(origin=origin), tempfile.TemporaryDirectory() as folder:
                result, output = self.invoke(folder, '--confirm-live', '--origin', origin)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(output.exists())
                self.assertNotIn(b'secret', result.stderr)

    def test_failure_has_no_private_diagnostics(self):
        with tempfile.TemporaryDirectory() as folder:
            result, output = self.invoke(folder, '--confirm-live')
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(output.exists())
            self.assertNotIn(folder.encode(), result.stderr)
            self.assertNotIn(b'Traceback', result.stderr)
            self.assertNotIn(b'PRIVATE-CHECKPOINT', result.stderr)

    def test_optimized_python_cannot_disable_acceptance_checks(self):
        with tempfile.TemporaryDirectory() as folder:
            result, output = self.invoke(folder, '--confirm-live', optimized=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(output.exists())


if __name__ == '__main__':
    unittest.main()
