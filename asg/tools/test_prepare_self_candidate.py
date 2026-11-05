# SPDX-License-Identifier: MPL-2.0
# Copyright 2026 Arpit Sinha

from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import prepare_self_candidate as candidate


class CandidateTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.parent = Path(temporary.name).resolve()
        self.source = self.parent / 'source'
        self.source.mkdir()
        self.git('init', '-q')

    def git(self, *args):
        return subprocess.check_output(['/usr/bin/git', '-C', str(self.source), *args])

    def commit(self):
        self.git('add', '.')
        self.git('-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
                 '-c', 'commit.gpgsign=false', 'commit', '-qm', 'fixture')
        return self.git('rev-parse', 'HEAD').decode().strip()

    def test_exact_bytes_and_dirty_source_with_replacement_and_filter(self):
        file = self.source / 'Example @1x'
        file.write_bytes(b'original\n')
        file.chmod(0o755)
        (self.source / '.gitattributes').write_text('* filter=fixture\n')
        original = self.commit()
        file.write_bytes(b'substitute\n')
        self.git('replace', original, self.commit())
        marker = self.parent / 'filter-ran'
        self.git('config', 'filter.fixture.smudge', f'touch "{marker}"; cat')
        file.write_bytes(b'dirty\n')
        (self.source / 'untracked').touch()
        result = candidate.prepare(self.source, original, self.parent)
        self.assertEqual((result / file.name).read_bytes(), b'original\n')
        self.assertTrue((result / file.name).stat().st_mode & 0o100)
        self.assertEqual(file.read_bytes(), b'dirty\n')
        self.assertFalse((result / 'untracked').exists())
        self.assertFalse(marker.exists())

    def test_symlink_and_oversized_file_fail_before_writing(self):
        file = self.source / 'entry'
        file.symlink_to(self.parent / 'outside')
        with self.assertRaisesRegex(ValueError, 'Unsupported source entry'):
            candidate.prepare(self.source, self.commit(), self.parent)
        file.unlink()
        file.write_bytes(b'ab')
        oversized = self.commit()
        with patch.object(candidate, 'MAX_FILE_BYTES', 1):
            with self.assertRaisesRegex(ValueError, 'size limits'):
                candidate.prepare(self.source, oversized, self.parent)
        self.assertEqual(list(self.parent.glob('asg-self-candidate-*')), [])

    def test_failed_write_preserves_source_and_allows_new_attempt(self):
        (self.source / 'entry').write_bytes(b'original')
        commit = self.commit()
        with patch.object(candidate, 'write_blob', side_effect=OSError('fixture')):
            with self.assertRaisesRegex(ValueError, 'Inspect the candidate run'):
                candidate.prepare(self.source, commit, self.parent)
        partial, = self.parent.glob('asg-self-candidate-*')
        self.assertEqual([p.name for p in partial.iterdir()], ['incomplete'])
        result = candidate.prepare(self.source, commit, self.parent)
        self.assertNotEqual(partial, result.parent)
        self.assertEqual(result.name, f'source-{commit}')
        self.assertFalse((result.parent / 'incomplete').exists())
        self.assertEqual((result / 'entry').read_bytes(), b'original')
        self.assertEqual((self.source / 'entry').read_bytes(), b'original')

    def test_case_collision_refused(self):
        oid = b'0' * 40
        header = b'100644 blob ' + oid + b' 0\t'
        with self.assertRaisesRegex(ValueError, 'Conflicting source paths'):
            candidate.parse_tree(header + b'A/one\0' + header + b'a/two\0')


if __name__ == '__main__':
    unittest.main()
