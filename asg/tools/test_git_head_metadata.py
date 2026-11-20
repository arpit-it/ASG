# SPDX-License-Identifier: MPL-2.0
# Copyright 2026 Arpit Sinha
"""Disposable literal-metadata fixtures; no Git executable or owner repositories."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import git_head_metadata as metadata


@unittest.skipUnless(os.name == 'posix', 'POSIX descriptor fixtures only')
class HeadMetadataTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='asg-head-metadata-')
        self.root = Path(self.temp.name).resolve()
        self.git = self.root / '.git'
        (self.git / 'refs/heads').mkdir(parents=True)
        (self.git / 'HEAD').write_text('ref: refs/heads/main\n')
        (self.git / 'refs/heads/main').write_text('1' * 40 + '\n')
        self.addCleanup(self.temp.cleanup)

    def observe(self):
        value = metadata.inspect_head(str(self.root))
        self.assertIs(value['git_state_verified'], False)
        for key in ('working_tree', 'ahead_behind', 'conflict'):
            self.assertEqual(value[key], 'unknown')
        self.assertNotIn(str(self.root), json.dumps(value))
        return value

    def test_symbolic_loose_declaration(self):
        value = self.observe()
        self.assertEqual(value['status'], 'observed')
        self.assertEqual(value['declared_ref'], 'refs/heads/main')
        self.assertEqual(value['declared_oid'], '1' * 40)
        self.assertEqual(value['oid_source'], 'loose_ref')

    def test_direct_oid_is_not_verified_commit(self):
        for width in (40, 64):
            (self.git / 'HEAD').write_text('a' * width)
            value = self.observe()
            self.assertEqual(value['status'], 'observed')
            self.assertEqual(value['head_form'], 'direct_oid')
            self.assertEqual(value['declared_oid'], 'a' * width)

    def test_missing_ref_is_unresolved_not_unborn(self):
        (self.git / 'refs/heads/main').unlink()
        value = self.observe()
        self.assertEqual(value['status'], 'unresolved')
        self.assertEqual(value['declared_ref'], 'refs/heads/main')
        self.assertIsNone(value['declared_oid'])

    def test_no_direct_git_directory_is_not_git_discovery(self):
        empty = self.root / 'nested'; empty.mkdir()
        value = metadata.inspect_head(str(empty))
        self.assertEqual(value['status'], 'not_present')
        self.assertEqual(value['reason'], 'no_direct_git_directory')

    def test_packed_presence_is_refused_without_read(self):
        (self.git / 'packed-refs').write_bytes(b'private-invalid')
        with patch.object(metadata.os, 'read', side_effect=AssertionError('No read')):
            value = self.observe()
        self.assertEqual(value['status'], 'unsupported')
        self.assertEqual(value['reason'], 'packed_refs_present')

    def test_head_symlink_is_not_read(self):
        outside = self.root / 'private-sentinel'; outside.write_text('a' * 40)
        (self.git / 'HEAD').unlink(); (self.git / 'HEAD').symlink_to(outside)
        with patch.object(metadata.os, 'read', side_effect=AssertionError('No read')):
            value = self.observe()
        self.assertEqual(value['status'], 'unsupported')
        self.assertIsNone(value['declared_oid'])

    def test_traversal_rejected_before_ref_read(self):
        (self.git / 'HEAD').write_text('ref: refs/heads/../private\n')
        value = self.observe()
        self.assertEqual(value['status'], 'invalid')
        self.assertIsNone(value['declared_ref'])

    def test_fifo_refused_promptly(self):
        (self.git / 'HEAD').unlink(); os.mkfifo(self.git / 'HEAD')
        with patch.object(metadata.os, 'read', side_effect=AssertionError('No read')):
            value = self.observe()
        self.assertEqual(value['status'], 'unsupported')

    def test_hardlink_refused_without_read(self):
        outside = self.root / 'private-sentinel'; outside.write_text('a' * 40)
        (self.git / 'HEAD').unlink(); os.link(outside, self.git / 'HEAD')
        with patch.object(metadata.os, 'read', side_effect=AssertionError('No read')):
            value = self.observe()
        self.assertEqual(value['status'], 'unsupported')
        self.assertIsNone(value['declared_oid'])

    def test_forbidden_inputs_and_processes_unused(self):
        real = metadata.os.open
        forbidden = {'config', 'index', 'objects', 'hooks', 'filters', 'packed-refs'}
        def guarded(name, *args, **kwargs):
            self.assertNotIn(name, forbidden)
            return real(name, *args, **kwargs)
        with patch.object(metadata.os, 'open', side_effect=guarded), \
                patch.object(subprocess, 'run', side_effect=AssertionError('No process')), \
                patch.object(metadata.os, 'system', side_effect=AssertionError('No shell')):
            self.assertEqual(self.observe()['status'], 'observed')

    def test_bytes_unchanged(self):
        before = {p.relative_to(self.root): p.read_bytes() for p in self.root.rglob('*') if p.is_file()}
        self.assertEqual(self.observe()['status'], 'observed')
        after = {p.relative_to(self.root): p.read_bytes() for p in self.root.rglob('*') if p.is_file()}
        self.assertEqual(before, after)

    def test_missing_head_and_gitfile_are_distinct(self):
        (self.git / 'HEAD').unlink()
        self.assertEqual(self.observe()['reason'], 'head_missing')
        other = self.root / 'gitfile-root'; other.mkdir()
        (other / '.git').write_text('gitdir: /private-sentinel')
        value = metadata.inspect_head(str(other))
        self.assertEqual(value['status'], 'unsupported')
        self.assertIsNone(value['declared_oid'])

    def test_marker_types_are_not_followed_or_read(self):
        for name in metadata.MARKERS:
            path = self.git / name
            path.symlink_to(self.root / 'missing-private-sentinel')
            with patch.object(metadata.os, 'read', side_effect=AssertionError('No read')):
                value = self.observe()
            self.assertEqual(value['status'], 'unsupported')
            path.unlink()

    def test_ref_directory_and_leaf_links_refused(self):
        leaf = self.git / 'refs/heads/main'
        leaf.unlink(); leaf.symlink_to(self.root / 'missing-private-sentinel')
        self.assertEqual(self.observe()['status'], 'unsupported')
        leaf.unlink(); (self.git / 'refs/heads').rmdir()
        (self.git / 'refs/heads').symlink_to(self.root, target_is_directory=True)
        self.assertEqual(self.observe()['status'], 'unsupported')

    def test_ancestor_link_and_relative_root_refused(self):
        alias = self.root / 'alias'; alias.symlink_to(self.git, target_is_directory=True)
        value = metadata.inspect_head(str(alias))
        self.assertEqual(value['status'], 'unsupported')
        self.assertEqual(metadata.inspect_head('relative')['status'], 'unavailable')

    def test_malformed_head_and_ref_subset(self):
        for raw in [b'', b'\xff', b'0' * 40, b'A' * 40, b'a' * 40 + b'\r\n',
                    b'a' * 40 + b'\nextra', b'ref: refs/heads/a..b',
                    b'ref: refs/heads/a.lock', b'ref: refs/heads//b',
                    b'ref: refs/heads/a@{b', b'ref: refs/heads/a\x00b']:
            (self.git / 'HEAD').write_bytes(raw)
            value = self.observe()
            self.assertEqual(value['status'], 'invalid', repr(raw))
            self.assertIsNone(value['declared_ref'])
        (self.git / 'HEAD').write_text('ref: refs/heads/main')
        for raw in [b'ref: refs/heads/main', b'private-sentinel', b'a' * 39, b'a' * 40 + b'\n\n']:
            (self.git / 'refs/heads/main').write_bytes(raw)
            self.assertEqual(self.observe()['status'], 'invalid')

    def test_nested_branch_and_exact_bounds(self):
        (self.git / 'refs/heads/feature').mkdir()
        (self.git / 'refs/heads/feature/one').write_text('b' * 64 + '\n')
        (self.git / 'HEAD').write_text('ref: refs/heads/feature/one\n')
        self.assertEqual(self.observe()['declared_ref'], 'refs/heads/feature/one')
        (self.git / 'HEAD').write_bytes(b'x' * (metadata.HEAD_LIMIT + 1))
        self.assertEqual(self.observe()['reason'], 'metadata_too_large')
        (self.git / 'HEAD').write_text('ref: refs/heads/main')
        (self.git / 'refs/heads/main').write_bytes(b'x' * (metadata.REF_LIMIT + 1))
        self.assertEqual(self.observe()['reason'], 'metadata_too_large')

    def test_stat_to_open_disappearance_is_changed(self):
        for target in ['HEAD', 'main']:
            real = metadata.os.open
            fired = []
            def disappearing(name, *args, **kwargs):
                if name == target and not fired:
                    fired.append(name)
                    (self.git / ('HEAD' if target == 'HEAD' else 'refs/heads/main')).unlink()
                return real(name, *args, **kwargs)
            with patch.object(metadata.os, 'open', side_effect=disappearing):
                value = self.observe()
            self.assertEqual(fired, [target])
            self.assertEqual(value['status'], 'changed')
            self.assertIsNone(value['declared_ref'])
            (self.git / 'HEAD').write_text('ref: refs/heads/main')
            (self.git / 'refs/heads/main').write_text('1' * 40)

    def test_stat_to_open_link_swap_never_reads_outside(self):
        real = metadata.os.open
        fired = []
        def swapping(name, *args, **kwargs):
            if name == 'HEAD' and not fired:
                fired.append(name)
                (self.git / 'HEAD').unlink()
                (self.git / 'HEAD').symlink_to(self.root / 'private-sentinel')
            return real(name, *args, **kwargs)
        with patch.object(metadata.os, 'open', side_effect=swapping), \
                patch.object(metadata.os, 'read', side_effect=AssertionError('No content read')):
            value = self.observe()
        self.assertEqual(fired, ['HEAD'])
        self.assertEqual(value['status'], 'changed')

    def test_during_read_mutation_refused_without_retry(self):
        real = metadata.os.read
        fired = []
        def mutating(fd, size):
            data = real(fd, size)
            if data and not fired:
                fired.append(fd)
                (self.git / 'HEAD').write_text('a' * 64)
            return data
        with patch.object(metadata.os, 'read', side_effect=mutating):
            value = self.observe()
        self.assertEqual(len(fired), 1)
        self.assertEqual(value['status'], 'changed')
        self.assertIsNone(value['declared_oid'])

    def test_final_readset_disappearance_and_marker_change(self):
        original = metadata.Reader.validate
        for marker in [False, True]:
            def changed(reader):
                if marker:
                    (self.git / 'commondir').write_text('private-sentinel')
                else:
                    (self.git / 'refs/heads/main').unlink()
                return original(reader)
            with patch.object(metadata.Reader, 'validate', changed):
                value = self.observe()
            self.assertEqual(value['status'], 'changed')
            self.assertIsNone(value['declared_ref'])
            if marker:
                (self.git / 'commondir').unlink()
            else:
                (self.git / 'refs/heads/main').write_text('1' * 40)

    def test_directory_swap_detected(self):
        original = metadata.Reader.validate
        def changed(reader):
            heads = self.git / 'refs/heads'
            heads.rename(self.git / 'refs/old-heads')
            heads.mkdir(); (heads / 'main').write_text('2' * 40)
            return original(reader)
        with patch.object(metadata.Reader, 'validate', changed):
            value = self.observe()
        self.assertEqual(value['status'], 'changed')
        self.assertIsNone(value['declared_oid'])

    def test_missing_target_appearing_is_changed(self):
        target = self.git / 'refs/heads/main'; target.unlink()
        original = metadata.Reader.validate
        def appeared(reader):
            target.write_text('2' * 40)
            return original(reader)
        with patch.object(metadata.Reader, 'validate', appeared):
            value = self.observe()
        self.assertEqual(value['status'], 'changed')
        self.assertIsNone(value['declared_ref'])

    def test_marker_created_during_final_file_check_is_changed(self):
        real = metadata.os.stat
        original = metadata.Reader.validate
        validating, fired = [], []
        def begin(reader):
            validating.append(True)
            return original(reader)
        def changing(name, *args, **kwargs):
            value = real(name, *args, **kwargs)
            if validating and name == 'HEAD' and not fired:
                fired.append(name)
                (self.git / 'commondir').write_text('private-sentinel')
            return value
        with patch.object(metadata.Reader, 'validate', begin), \
                patch.object(metadata.os, 'stat', side_effect=changing):
            value = self.observe()
        self.assertEqual(fired, ['HEAD'])
        self.assertEqual(value['status'], 'changed')
        self.assertIsNone(value['declared_oid'])

    def test_root_and_git_directory_replacement_is_changed(self):
        original = metadata.Reader.validate
        for target in [self.git, self.root]:
            backup = target.with_name(target.name + '-held')
            def swapping(reader):
                target.rename(backup)
                target.mkdir()
                return original(reader)
            try:
                with patch.object(metadata.Reader, 'validate', swapping):
                    value = self.observe()
                self.assertEqual(value['status'], 'changed')
                self.assertIsNone(value['declared_ref'])
            finally:
                if backup.exists():
                    target.rmdir(); backup.rename(target)

    def test_regular_file_directory_and_oversize_reads_never_start(self):
        (self.git / 'HEAD').unlink(); (self.git / 'HEAD').mkdir()
        with patch.object(metadata.os, 'read', side_effect=AssertionError('No read')):
            self.assertEqual(self.observe()['status'], 'unsupported')
        (self.git / 'HEAD').rmdir()
        (self.git / 'HEAD').write_bytes(b'x' * (metadata.HEAD_LIMIT + 1))
        with patch.object(metadata.os, 'read', side_effect=AssertionError('No read')):
            self.assertEqual(self.observe()['reason'], 'metadata_too_large')

    def test_head_and_ref_truncate_or_grow_during_read(self):
        for target in ['HEAD', 'main']:
            for replacement in ['', 'x' * (metadata.HEAD_LIMIT + 100)]:
                (self.git / 'HEAD').write_text('ref: refs/heads/main')
                (self.git / 'refs/heads/main').write_text('1' * 40)
                real_open, real_read = metadata.os.open, metadata.os.read
                chosen, fired = [], []
                def opening(name, *args, **kwargs):
                    fd = real_open(name, *args, **kwargs)
                    if name == target:
                        chosen.append(fd)
                    return fd
                def mutating(fd, size):
                    if fd in chosen and not fired:
                        fired.append(fd)
                        path = self.git / ('HEAD' if target == 'HEAD' else 'refs/heads/main')
                        path.write_text(replacement)
                    return real_read(fd, size)
                with patch.object(metadata.os, 'open', side_effect=opening), \
                        patch.object(metadata.os, 'read', side_effect=mutating):
                    value = self.observe()
                self.assertEqual(len(fired), 1)
                self.assertEqual(value['status'], 'changed')
                self.assertIsNone(value['declared_oid'])

    def test_bad_cli_request_has_fixed_json_no_echo(self):
        result = subprocess.run([sys.executable, '-I', '-S', '-B', str(Path(metadata.__file__).resolve()),
                                 '--private-sentinel'], capture_output=True, timeout=5)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(result.stderr, b'')
        value = json.loads(result.stdout)
        self.assertEqual(value['reason'], 'invalid_request')
        self.assertNotIn('private-sentinel', result.stdout.decode())

    def test_descriptor_cleanup_after_failure(self):
        real_open, real_close = metadata.os.open, metadata.os.close
        opened, closed = [], []
        def opening(*args, **kwargs):
            fd = real_open(*args, **kwargs); opened.append(fd); return fd
        def closing(fd):
            closed.append(fd); return real_close(fd)
        with patch.object(metadata.os, 'open', side_effect=opening), \
                patch.object(metadata.os, 'close', side_effect=closing), \
                patch.object(metadata.os, 'read', side_effect=PermissionError('private-sentinel')):
            value = self.observe()
        self.assertEqual(value['status'], 'unavailable')
        self.assertGreater(len(opened), 2)
        self.assertCountEqual(opened, closed)
        self.assertNotIn('private-sentinel', json.dumps(value))

    def test_host_capabilities_and_unimplemented_syscall_fail_closed(self):
        with patch.object(metadata, 'SUPPORTED_HOST', False):
            self.assertEqual(self.observe()['status'], 'unsupported')
        with patch.object(metadata.os, 'stat', side_effect=NotImplementedError('private-sentinel')):
            value = self.observe()
        self.assertEqual(value['status'], 'unsupported')
        self.assertNotIn('private-sentinel', json.dumps(value))

    def test_links_to_outside_authorized_root_are_not_read(self):
        with tempfile.TemporaryDirectory(prefix='asg-head-outside-') as outside:
            sentinel = Path(outside).resolve() / 'private-sentinel'
            sentinel.write_text('b' * 40)
            head = self.git / 'HEAD'; head.unlink(); head.symlink_to(sentinel)
            with patch.object(metadata.os, 'read', side_effect=AssertionError('No content read')):
                value = self.observe()
            self.assertEqual(value['status'], 'unsupported')
            head.unlink(); os.link(sentinel, head)
            with patch.object(metadata.os, 'read', side_effect=AssertionError('No content read')):
                value = self.observe()
            self.assertEqual(value['status'], 'unsupported')
            self.assertEqual(sentinel.read_text(), 'b' * 40)

    def test_descriptor_cleanup_on_success_and_final_change(self):
        original = metadata.Reader.validate
        for mutate in [False, True]:
            opened, closed = [], []
            real_open, real_close = metadata.os.open, metadata.os.close
            def opening(*args, **kwargs):
                fd = real_open(*args, **kwargs); opened.append(fd); return fd
            def closing(fd):
                closed.append(fd); return real_close(fd)
            def validate(reader):
                if mutate:
                    (self.git / 'HEAD').write_text('c' * 40)
                return original(reader)
            with patch.object(metadata.os, 'open', side_effect=opening), \
                    patch.object(metadata.os, 'close', side_effect=closing), \
                    patch.object(metadata.Reader, 'validate', validate):
                value = self.observe()
            self.assertEqual(value['status'], 'changed' if mutate else 'observed')
            self.assertGreater(len(opened), 2)
            self.assertCountEqual(opened, closed)

    def test_cli_fixed_json_without_site_or_repo_imports(self):
        result = subprocess.run([sys.executable, '-I', '-S', '-B', str(Path(metadata.__file__).resolve()),
                                 '--root', str(self.root)], capture_output=True, timeout=5)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stderr, b'')
        self.assertLess(len(result.stdout), 4096)
        self.assertEqual(json.loads(result.stdout)['status'], 'observed')


if __name__ == '__main__':
    unittest.main()
