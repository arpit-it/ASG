# SPDX-License-Identifier: MPL-2.0
# Copyright 2026 Arpit Sinha

from pathlib import Path
import json
import os
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

    def prepared(self):
        for name in ['same', 'edit', 'remove', 'mode', 'both']:
            (self.source / name).write_text('baseline')
        commit = self.commit()
        return candidate.prepare(self.source, commit, self.parent), commit

    def test_comparison_explicit_baseline_modes_and_dirty_preservation(self):
        snapshot, commit = self.prepared()
        unchanged = candidate.compare_candidate(snapshot, self.source, commit)
        self.assertEqual(unchanged['changes'], [])
        self.assertFalse(unchanged['truncated'])
        (self.source / 'same').write_text('dirty source stays')
        (self.source / 'untracked').write_text('untouched')
        (snapshot / 'edit').write_text('changed')
        (snapshot / 'remove').unlink()
        (snapshot / 'new').write_text('new')
        (snapshot / 'mode').chmod(0o700)
        (snapshot / 'both').write_text('changed too')
        (snapshot / 'both').chmod(0o700)
        renamed = snapshot.with_name('source-' + 'b' * 40)
        snapshot.rename(renamed)
        result = candidate.compare_candidate(renamed, self.source, commit)
        self.assertEqual(result['commit'], commit)
        self.assertEqual(result['digest'], candidate.fingerprint(renamed))
        self.assertEqual(result['counts'], {'added': 1, 'modified': 3, 'removed': 1, 'executableChanged': 2})
        self.assertEqual([c['path'] for c in result['changes']], ['both', 'edit', 'mode', 'new', 'remove'])
        self.assertTrue(result['changes'][0]['executableChanged'])
        self.assertEqual((self.source / 'same').read_text(), 'dirty source stays')
        self.assertEqual((self.source / 'untracked').read_text(), 'untouched')
        with self.assertRaises(ValueError):
            candidate.compare_candidate(renamed, self.source, 'c' * 40)
        with self.assertRaises(ValueError):
            candidate.compare_candidate(renamed, renamed, commit)
        nested = renamed / 'nested'
        nested.mkdir()
        with self.assertRaises(ValueError):
            candidate.compare_candidate(renamed, nested, commit)

    def test_case_only_rename_is_added_and_removed_not_an_origin_claim(self):
        snapshot, commit = self.prepared()
        (snapshot / 'same').rename(snapshot / 'Same')
        result = candidate.compare_candidate(snapshot, self.source, commit)
        self.assertEqual(result['counts']['added'], 1)
        self.assertEqual(result['counts']['removed'], 1)
        self.assertEqual([c['path'] for c in result['changes']], ['Same', 'same'])

    def test_comparison_ignores_git_replacements_and_filters(self):
        snapshot, original = self.prepared()
        (self.source / 'same').write_text('replacement')
        replacement = self.commit()
        self.git('replace', original, replacement)
        marker = self.parent / 'driver-ran'
        self.git('config', 'diff.external', str(marker))
        self.git('config', 'filter.fixture.smudge', f'touch "{marker}"')
        result = candidate.compare_candidate(snapshot, self.source, original)
        self.assertEqual(result['changes'], [])
        self.assertFalse(marker.exists())

    def test_candidate_links_special_files_and_limits_refused(self):
        snapshot, commit = self.prepared()
        extra = snapshot / 'extra'
        for kind in ['symlink', 'hardlink', 'fifo']:
            if kind == 'symlink': extra.symlink_to(self.source / 'same')
            elif kind == 'hardlink': os.link(self.source / 'same', extra)
            else: os.mkfifo(extra)
            with self.assertRaises((OSError, ValueError)):
                candidate.compare_candidate(snapshot, self.source, commit)
            extra.unlink()
        with patch.object(candidate, 'MAX_FILES', 1):
            with self.assertRaises(ValueError): candidate.compare_candidate(snapshot, self.source, commit)
        with patch.object(candidate, 'MAX_FILE_BYTES', 1):
            with self.assertRaises(ValueError): candidate.compare_candidate(snapshot, self.source, commit)
        with patch.object(candidate, '_stop_requested', True):
            with self.assertRaises(ValueError): candidate.compare_candidate(snapshot, self.source, commit)
        for child in snapshot.iterdir(): child.unlink()
        with self.assertRaisesRegex(ValueError, 'empty'):
            candidate.compare_candidate(snapshot, self.source, commit)

    def test_candidate_mutation_and_swapped_ancestor_fail(self):
        snapshot, commit = self.prepared()
        original = candidate.hashlib.sha1
        def mutate(data):
            (snapshot / 'same').write_text('mutated while hashing')
            return original(data)
        with patch.object(candidate.hashlib, 'sha1', side_effect=mutate):
            with self.assertRaisesRegex(ValueError, 'changed'):
                candidate.compare_candidate(snapshot, self.source, commit)
        original_open = candidate.open_directory_no_links
        run = snapshot.parent
        moved = run.with_name(run.name + '-moved')
        def swap(directory):
            run.rename(moved)
            run.symlink_to(moved, target_is_directory=True)
            return original_open(directory)
        with patch.object(candidate, 'open_directory_no_links', side_effect=swap):
            with self.assertRaises(OSError): candidate.compare_candidate(snapshot, self.source, commit)

    def test_comparison_display_is_bounded_and_includes_generated_files(self):
        snapshot, commit = self.prepared()
        for number in range(110):
            p = snapshot / (('a' * 90) + str(number)) / ('b' * 90) / 'output'
            p.parent.mkdir(parents=True)
            p.write_text('new')
        generated = snapshot / '.dart_tool'
        generated.mkdir()
        (generated / 'output').write_text('generated')
        result = candidate.compare_candidate(snapshot, self.source, commit)
        self.assertEqual(result['counts']['added'], 111)
        self.assertTrue(result['truncated'])
        self.assertLessEqual(len(result['changes']), 100)
        self.assertLessEqual(sum(len(c['path']) for c in result['changes']), 16384)
        self.assertLess(len(json.dumps(result)), 32768)
        self.assertEqual(result['changes'][0]['path'], '.dart_tool/output')


if __name__ == '__main__':
    unittest.main()
