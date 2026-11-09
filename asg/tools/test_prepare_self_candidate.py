# SPDX-License-Identifier: MPL-2.0
# Copyright 2026 Arpit Sinha

from pathlib import Path
import json
import os
import subprocess
import hashlib
import os
import stat
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

    def test_staging_substitution_is_refused_and_fresh_retry_succeeds(self):
        (self.source / 'entry').write_bytes(b'original')
        commit = self.commit()
        write = candidate.write_blob

        def substitute(root_fd, parts, mode, data):
            write(root_fd, parts, mode, data)
            staging, = self.parent.glob('*/incomplete')
            staging.rename(staging.with_name('retained-original'))
            staging.mkdir()
            (staging / 'unexpected.txt').write_bytes(b'unexpected')

        with patch.object(candidate, 'write_blob', side_effect=substitute):
            with self.assertRaisesRegex(ValueError, 'Inspect the candidate run'):
                candidate.prepare(self.source, commit, self.parent)
        failed, = self.parent.glob('asg-self-candidate-*')
        self.assertFalse((failed / f'source-{commit}').exists())
        self.assertEqual((failed / 'retained-original/entry').read_bytes(), b'original')
        self.assertEqual((failed / 'incomplete/unexpected.txt').read_bytes(), b'unexpected')
        ready = candidate.prepare(self.source, commit, self.parent)
        self.assertNotEqual(ready.parent, failed)
        self.assertEqual((ready / 'entry').read_bytes(), b'original')

    def test_existing_publication_target_is_preserved(self):
        (self.source / 'entry').write_bytes(b'original')
        commit = self.commit()
        write = candidate.write_blob
        existing = []

        def occupy(root_fd, parts, mode, data):
            write(root_fd, parts, mode, data)
            staging, = self.parent.glob('*/incomplete')
            target = staging.with_name(f'source-{commit}')
            target.mkdir()
            existing.append((target, target.stat().st_ino))

        with patch.object(candidate, 'write_blob', side_effect=occupy):
            with self.assertRaisesRegex(ValueError, 'Inspect the candidate run'):
                candidate.prepare(self.source, commit, self.parent)
        (target, inode), = existing
        self.assertEqual(target.stat().st_ino, inode)
        self.assertEqual(list(target.iterdir()), [])
        self.assertEqual((target.parent / 'incomplete/entry').read_bytes(), b'original')

    def test_changed_staged_mode_and_extra_directory_are_refused(self):
        (self.source / 'entry').write_bytes(b'original')
        commit = self.commit()
        write = candidate.write_blob

        for mutation in ('mode', 'empty-directory'):
            with self.subTest(mutation=mutation):
                destination = self.parent / mutation
                destination.mkdir()

                def change(root_fd, parts, mode, data):
                    write(root_fd, parts, mode, data)
                    staging, = destination.glob('*/incomplete')
                    if mutation == 'mode':
                        (staging / 'entry').chmod(0o700)
                    else:
                        (staging / 'extra').mkdir()

                with patch.object(candidate, 'write_blob', side_effect=change):
                    with self.assertRaisesRegex(ValueError, 'Inspect the candidate run'):
                        candidate.prepare(self.source, commit, destination)
                self.assertEqual(list(destination.glob('*/source-*')), [])

    def test_changed_bytes_at_publication_are_refused(self):
        (self.source / 'entry').write_bytes(b'original')
        commit = self.commit()
        publish = candidate.exclusive_rename

        def change(run_fd, source, target):
            publish(run_fd, source, target)
            ready, = self.parent.glob(f'*/source-{commit}')
            (ready / 'entry').write_bytes(b'changed!')

        with patch.object(candidate, 'exclusive_rename', side_effect=change):
            with self.assertRaisesRegex(ValueError, 'Inspect the candidate run'):
                candidate.prepare(self.source, commit, self.parent)
        ready, = self.parent.glob(f'*/source-{commit}')
        self.assertEqual((ready / 'entry').read_bytes(), b'changed!')
        self.assertEqual((self.source / 'entry').read_bytes(), b'original')

    def test_replaced_destination_is_refused_before_run_creation(self):
        (self.source / 'entry').write_bytes(b'original')
        commit = self.commit()
        destination = self.parent / 'destination'
        destination.mkdir()
        moved = self.parent / 'moved-destination'
        read = candidate.read_git

        def replace_after_tree(source, args, limit, deadline):
            result = read(source, args, limit, deadline)
            if args[0] == 'ls-tree':
                destination.rename(moved)
                destination.mkdir()
            return result

        with patch.object(candidate, 'read_git', side_effect=replace_after_tree):
            with self.assertRaisesRegex(ValueError, 'identity changed'):
                candidate.prepare(self.source, commit, destination)
        self.assertEqual(list(destination.iterdir()), [])
        self.assertEqual(list(moved.iterdir()), [])

    def test_prepare_refuses_checkout_identity_in_destination_ancestry(self):
        (self.source / 'entry').write_bytes(b'original')
        commit = self.commit()
        inside = self.source / 'inside'
        inside.mkdir()
        (inside / 'sentinel').write_bytes(b'preserved')
        alias = self.parent / 'different-name'
        alias.mkdir()
        (alias / 'inside').mkdir()
        original_open = os.open

        def open_with_alias(name, *args, **kwargs):
            if name == alias.name and kwargs.get('dir_fd') is not None:
                name = self.source.name
            return original_open(name, *args, **kwargs)

        with patch.object(candidate.os, 'open', side_effect=open_with_alias):
            with self.assertRaisesRegex(ValueError, 'outside the source repository'):
                candidate.prepare(self.source, commit, alias / 'inside')
        self.assertEqual(list(inside.iterdir()), [inside / 'sentinel'])
        self.assertEqual((inside / 'sentinel').read_bytes(), b'preserved')
        self.assertEqual(list((alias / 'inside').iterdir()), [])

    def test_prepare_refuses_real_checkout_case_alias(self):
        alternate = self.source.with_name(self.source.name.upper())
        if not alternate.is_dir() or alternate.resolve() == self.source:
            self.skipTest('Case-preserving checkout alias unavailable on this filesystem.')
        (self.source / 'entry').write_bytes(b'original')
        commit = self.commit()
        inside = self.source / 'inside'
        inside.mkdir()

        with self.assertRaisesRegex(ValueError, 'outside the source repository'):
            candidate.prepare(self.source, commit, alternate / 'inside')
        self.assertEqual(list(inside.iterdir()), [])
        self.assertEqual((self.source / 'entry').read_bytes(), b'original')

    def test_prepare_refuses_bundle_destinations_and_can_retry_outside(self):
        (self.source / 'entry').write_bytes(b'original')
        commit = self.commit()
        inside = self.parent / 'StableFixture.ApP' / 'Contents'
        inside.mkdir(parents=True)
        sentinel = inside / 'sentinel'
        sentinel.write_bytes(b'preserved')
        alias = self.parent / 'selected-folder'
        alias.symlink_to(inside, target_is_directory=True)

        for target in (inside, alias):
            with self.subTest(target=target):
                with self.assertRaisesRegex(ValueError, 'outside application bundles'):
                    candidate.prepare(self.source, commit, target)
        self.assertEqual(list(inside.iterdir()), [sentinel])
        self.assertEqual(sentinel.read_bytes(), b'preserved')

        external = self.parent / 'external'
        external.mkdir()
        alias.unlink()
        alias.symlink_to(external, target_is_directory=True)
        ready = candidate.prepare(self.source, commit, alias)
        self.assertEqual(ready.parent.parent, external)
        self.assertEqual((ready / 'entry').read_bytes(), b'original')
        self.assertEqual((self.source / 'entry').read_bytes(), b'original')

    def test_stop_after_stage_verification_leaves_incomplete_snapshot(self):
        (self.source / 'entry').write_bytes(b'original')
        commit = self.commit()
        scan = candidate.scan_candidate

        def stop_after_scan(path, **kwargs):
            verified = scan(path, **kwargs)
            candidate.request_stop(None, None)
            return verified

        with patch.object(candidate, '_stop_requested', False):
            with patch.object(candidate, 'scan_candidate', side_effect=stop_after_scan):
                with self.assertRaisesRegex(ValueError, 'Inspect the candidate run'):
                    candidate.prepare(self.source, commit, self.parent)
        run, = self.parent.glob('asg-self-candidate-*')
        self.assertEqual((run / 'incomplete/entry').read_bytes(), b'original')
        self.assertFalse((run / f'source-{commit}').exists())

    def test_nested_committed_tree_keeps_preparation_file_limit(self):
        path = self.source / 'a/b/c/entry'
        path.parent.mkdir(parents=True)
        path.write_bytes(b'nested committed bytes')
        commit = self.commit()
        with patch.object(candidate, 'MAX_FILES', 1):
            ready = candidate.prepare(self.source, commit, self.parent)
        self.assertEqual((ready / 'a/b/c/entry').read_bytes(), b'nested committed bytes')

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

    def test_file_review_complete_modified_added_removed_and_empty_sides(self):
        snapshot, commit = self.prepared()
        (self.source / 'edit').write_text('dirty stays')
        (snapshot / 'edit').write_text('after\n')
        (snapshot / 'remove').unlink()
        (snapshot / 'empty').write_bytes(b'')
        digest = candidate.fingerprint(snapshot)
        result = candidate.review_file(snapshot, self.source, commit, digest, 'edit')
        self.assertEqual(result['before'], {'state': 'text', 'text': 'baseline'})
        self.assertEqual(result['after'], {'state': 'text', 'text': 'after\n'})
        self.assertEqual(result['digest'], digest)
        removed = candidate.review_file(snapshot, self.source, commit, digest, 'remove')
        self.assertEqual(removed['after'], {'state': 'absent', 'text': None})
        added = candidate.review_file(snapshot, self.source, commit, digest, 'empty')
        self.assertEqual(added['before'], {'state': 'absent', 'text': None})
        self.assertEqual(added['after'], {'state': 'text', 'text': ''})
        self.assertEqual((self.source / 'edit').read_text(), 'dirty stays')
        with self.assertRaises(ValueError):
            candidate.review_file(snapshot, self.source, commit, digest, 'same')
        (snapshot / 'edit').write_text('changed again')
        with self.assertRaises(ValueError):
            candidate.review_file(snapshot, self.source, commit, digest, 'edit')

    def test_file_review_limits_encoding_and_mode_only(self):
        snapshot, commit = self.prepared()
        (snapshot / 'mode').chmod(0o700)
        digest = candidate.fingerprint(snapshot)
        mode = candidate.review_file(snapshot, self.source, commit, digest, 'mode')
        self.assertEqual(mode['before'], mode['after'])
        for data, state in [(b'\0bad', 'unsupported'), (b'\xff', 'unsupported'),
                            ('é'.encode() * 8192, 'text'),
                            ('é'.encode() * 8193, 'byteLimit'),
                            (b'x\r\n' * 500, 'text'), (b'x\r' * 501, 'lineLimit'),
                            ('x\u2028'.encode() * 501, 'lineLimit')]:
            (snapshot / 'edit').write_bytes(data)
            value = candidate.review_file(snapshot, self.source, commit,
                                          candidate.fingerprint(snapshot), 'edit')
            self.assertEqual(value['after']['state'], state)
            self.assertEqual(value['after']['text'], data.decode() if state == 'text' else None)

    def test_file_review_selected_map_handles_file_directory_replacement(self):
        snapshot, commit = self.prepared()
        (snapshot / 'remove').unlink()
        (snapshot / 'remove').mkdir()
        (snapshot / 'remove/child').write_text('new')
        digest = candidate.fingerprint(snapshot)
        removed = candidate.review_file(snapshot, self.source, commit, digest, 'remove')
        self.assertEqual(removed['after']['state'], 'absent')
        added = candidate.review_file(snapshot, self.source, commit, digest, 'remove/child')
        self.assertEqual(added['before']['state'], 'absent')

    def test_file_review_missing_blob_mutation_and_invalid_paths_refused(self):
        snapshot, commit = self.prepared()
        (snapshot / 'edit').write_text('after')
        digest = candidate.fingerprint(snapshot)
        with patch.object(candidate, 'read_git') as read:
            with self.assertRaises(ValueError):
                candidate.review_file(snapshot, self.source, commit, digest, '../edit')
            read.assert_not_called()
        with patch.object(candidate, '_stop_requested', True):
            with self.assertRaises(ValueError):
                candidate.review_file(snapshot, self.source, commit, digest, 'edit')
        original = candidate.read_git
        def mutate(source, args, limit, deadline):
            value = original(source, args, limit, deadline)
            if args[:2] == ['cat-file', 'blob']:
                (snapshot / 'edit').write_text('later')
            return value
        with patch.object(candidate, 'read_git', side_effect=mutate):
            with self.assertRaises(ValueError):
                candidate.review_file(snapshot, self.source, commit, digest, 'edit')
        oid = self.git('rev-parse', commit + ':edit').decode().strip()
        (self.source / '.git/objects' / oid[:2] / oid[2:]).unlink()
        with self.assertRaises(ValueError):
            candidate.review_file(snapshot, self.source, commit, candidate.fingerprint(snapshot), 'edit')



class ProposalTests(unittest.TestCase):
    setUp = CandidateTests.setUp
    git = CandidateTests.git
    commit = CandidateTests.commit
    HEADER = '// SPDX-License-Identifier: MPL-2.0\n// Copyright 2026 Arpit Sinha\n\n'

    def proposal_fixture(self):
        (self.source / 'asg/lib').mkdir(parents=True)
        source = self.source / 'asg/lib/main.dart'
        source.write_text(self.HEADER + 'void main() {}\n')
        ready = candidate.prepare(self.source, self.commit(), self.parent)
        (ready / 'empty-directory').mkdir()
        loaded = candidate.proposal_read(ready, 'asg/lib/main.dart')
        destination = self.parent / 'outputs'
        destination.mkdir()
        after = self.HEADER + 'void main() { print("proposal"); }\n'
        payload = {'snapshot': str(ready), 'path': loaded['path'], 'expectedDigest': loaded['digest'],
                   'beforeHash': loaded['beforeHash'], 'afterHash': hashlib.sha256(after.encode()).hexdigest(),
                   'replacement': after, 'destination': str(destination), 'trustedSource': str(self.source),
                   'runName': 'asg-self-candidate-1234abcd'}
        return ready, destination, payload

    def test_new_copy_preserves_original_and_normalizes_executable_modes(self):
        ready, destination, payload = self.proposal_fixture()
        original = (ready / payload['path']).read_bytes()
        (ready / payload['path']).chmod(0o4777)
        payload['expectedDigest'] = candidate.fingerprint(ready)
        receipt = candidate.apply_proposal(payload)
        output = Path(receipt['path'])
        self.assertEqual((ready / payload['path']).read_bytes(), original)
        self.assertEqual((self.source / payload['path']).read_bytes(), original)
        self.assertEqual((output / payload['path']).read_text(), payload['replacement'])
        self.assertTrue((output / 'empty-directory').is_dir())
        self.assertEqual(stat.S_IMODE((output / payload['path']).stat().st_mode), 0o700)
        self.assertEqual(stat.S_IMODE((output / 'empty-directory').stat().st_mode), 0o700)
        self.assertEqual(receipt['sourceDigest'], payload['expectedDigest'])
        self.assertEqual(receipt['digest'], candidate.fingerprint(output))
        self.assertNotEqual(receipt['digest'], receipt['sourceDigest'])
        self.assertFalse((output.parent / 'incomplete').exists())
        with self.assertRaises(ValueError):
            candidate.apply_proposal(payload)
        self.assertEqual(len(list(destination.iterdir())), 1)

    def test_stale_noop_header_and_text_limits_refuse(self):
        ready, destination, payload = self.proposal_fixture()
        before = (ready / payload['path']).read_text()
        for replacement in (before, 'void main() {}', 'x' * 16385, self.HEADER + 'x\n' * 501, '\x00'):
            attempt = dict(payload, replacement=replacement,
                           afterHash=hashlib.sha256(replacement.encode()).hexdigest())
            with self.subTest(replacement=replacement[:30]), self.assertRaises(ValueError):
                candidate.apply_proposal(attempt)
            payload['runName'] = 'asg-self-candidate-' + os.urandom(4).hex()
        with self.assertRaises(ValueError):
            candidate.apply_proposal(dict(payload, expectedDigest='a' * 64))
        self.assertEqual((ready / payload['path']).read_text(), before)
        self.assertFalse(list(destination.glob('*/source-*')))

    def test_path_destination_and_links_refused(self):
        ready, destination, payload = self.proposal_fixture()
        for name in ('../outside', 'asg/tools/run.dart', 'asg/lib/../main.dart', 'asg/lib/missing.dart'):
            with self.subTest(name=name), self.assertRaises(ValueError):
                candidate.apply_proposal(dict(payload, path=name))
        inside = ready / 'inside'
        inside.mkdir()
        for target in (inside, self.source):
            with self.assertRaises(ValueError):
                candidate.apply_proposal(dict(payload, destination=str(target)))
        linked = self.parent / 'linked-output'
        linked.symlink_to(destination, target_is_directory=True)
        with self.assertRaises(ValueError):
            candidate.apply_proposal(dict(payload, destination=str(linked)))
        source = ready / payload['path']
        data = source.read_bytes()
        source.unlink()
        outside = self.parent / 'outside.dart'
        outside.write_bytes(data)
        source.symlink_to(outside)
        with self.assertRaises(ValueError):
            candidate.apply_proposal(payload)
        self.assertEqual(outside.read_bytes(), data)

    def test_empty_target_exclusive_publish_and_write_failure_retain_staging(self):
        ready, destination, payload = self.proposal_fixture()
        publish = candidate.exclusive_rename
        def occupied(fd, source, target):
            os.mkdir(target, 0o700, dir_fd=fd)
            original = os.stat(target, dir_fd=fd).st_ino
            try:
                publish(fd, source, target)
            finally:
                self.assertEqual(os.stat(target, dir_fd=fd).st_ino, original)
        with patch.object(candidate, 'exclusive_rename', side_effect=occupied):
            with self.assertRaises(ValueError):
                candidate.apply_proposal(payload)
        self.assertTrue(list(destination.glob('*/incomplete')))
        payload['runName'] = 'asg-self-candidate-2234abcd'
        with patch.object(candidate, 'write_blob', side_effect=OSError('fixed write failure')):
            with self.assertRaises(ValueError):
                candidate.apply_proposal(payload)
        self.assertEqual(len(list(destination.glob('*/incomplete'))), 2)

    def test_corrupt_output_stop_and_collision_refuse_without_replay(self):
        ready, destination, payload = self.proposal_fixture()
        write = candidate.write_blob
        def corrupt(fd, parts, mode, data):
            return write(fd, parts, mode, data + b'corrupt')
        with patch.object(candidate, 'write_blob', side_effect=corrupt), self.assertRaises(ValueError):
            candidate.apply_proposal(payload)
        payload['runName'] = 'asg-self-candidate-3234abcd'
        with patch.object(candidate, '_stop_requested', True), self.assertRaises(ValueError):
            candidate.apply_proposal(payload)
        occupied = destination / 'asg-self-candidate-aaaaaaaa'
        occupied.mkdir()
        (occupied / 'sentinel').write_text('preserved')
        with self.assertRaises(ValueError):
            candidate.apply_proposal(dict(payload, runName='asg-self-candidate-aaaaaaaa'))
        self.assertEqual((occupied / 'sentinel').read_text(), 'preserved')
        self.assertFalse(list(destination.glob('*/source-*')))

    def test_application_bundle_destination_refused(self):
        _, _, payload = self.proposal_fixture()
        destination = self.parent / 'Sentinel.ApP' / 'Contents'
        destination.mkdir(parents=True)
        payload['destination'] = str(destination)
        with self.assertRaises(ValueError):
            candidate.apply_proposal(payload)
        self.assertEqual(list(destination.iterdir()), [])

    def test_bom_legal_header_is_explicitly_refused(self):
        ready, destination, payload = self.proposal_fixture()
        file = ready / payload['path']
        file.write_text('\ufeff' + self.HEADER + 'void main() {}\n')
        loaded = candidate.proposal_read(ready, payload['path'])
        payload.update(expectedDigest=loaded['digest'], beforeHash=loaded['beforeHash'])
        with self.assertRaises(ValueError):
            candidate.apply_proposal(payload)


if __name__ == '__main__':
    unittest.main()
