# SPDX-License-Identifier: MPL-2.0
# Copyright 2026 Arpit Sinha
"""Disposable controls for the descriptor project-metadata prerequisite."""
import base64
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import project_metadata as metadata


@unittest.skipUnless(metadata.SUPPORTED_HOST, 'POSIX descriptor support required')
class ProjectMetadataTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='asg-project-metadata-')
        self.root = Path(self.temp.name).resolve()
        (self.root / 'lib').mkdir()
        (self.root / 'lib/main.dart').write_bytes(b'private source; never read')
        self.raw = b'name: controlled\n# raw manifest only\n'
        (self.root / 'pubspec.yaml').write_bytes(self.raw)

    def tearDown(self):
        self.temp.cleanup()

    def observe(self):
        result = metadata.inspect_project(str(self.root))
        self.assertFalse(result['source_verified'])
        self.assertLessEqual(len(json.dumps(result).encode()), metadata.OUTPUT_LIMIT)
        if result['status'] != 'observed':
            self.assertIsNone(result['manifest_base64'])
            self.assertIsNone(result['main_present'])
            self.assertEqual(result['included_runners'], [])
        return result

    def test_raw_manifest_and_fixed_runner_presence(self):
        (self.root / 'web').mkdir()
        (self.root / 'android').mkdir()
        before = (self.root / 'pubspec.yaml').read_bytes()
        value = self.observe()
        self.assertEqual(value['status'], 'observed')
        self.assertEqual(base64.b64decode(value['manifest_base64'], validate=True), before)
        self.assertEqual(value['included_runners'], ['android', 'web'])
        self.assertTrue(value['main_present'])
        self.assertEqual((self.root / 'pubspec.yaml').read_bytes(), before)

    def test_exact_limit_roundtrips_raw_binary_without_yaml_claim(self):
        raw = (b'\x00\xff\n' * 21846)[:65536]
        (self.root / 'pubspec.yaml').write_bytes(raw)
        value = self.observe()
        self.assertEqual(value['status'], 'observed')
        self.assertEqual(base64.b64decode(value['manifest_base64'], validate=True), raw)
        self.assertEqual(len(value['manifest_base64']), 87384)

    def test_oversized_manifest_refused_before_content_read(self):
        (self.root / 'pubspec.yaml').write_bytes(b'x' * 65537)
        with patch.object(metadata.os, 'read', side_effect=AssertionError('No read')):
            value = self.observe()
        self.assertEqual(value['reason'], 'metadata_too_large')

    def test_missing_required_entries(self):
        (self.root / 'lib/main.dart').unlink()
        self.assertEqual(self.observe()['reason'], 'source_entry_missing')
        (self.root / 'pubspec.yaml').unlink()
        self.assertEqual(self.observe()['reason'], 'manifest_missing')

    def test_hardlinked_manifest_refused_before_read(self):
        with tempfile.TemporaryDirectory(prefix='asg-metadata-outside-') as outside:
            target = Path(outside) / 'manifest'
            target.write_bytes(self.raw)
            (self.root / 'pubspec.yaml').unlink()
            os.link(target, self.root / 'pubspec.yaml')
            with patch.object(metadata.os, 'read', side_effect=AssertionError('No read')):
                self.assertEqual(self.observe()['reason'], 'unsafe_metadata')
            self.assertEqual(target.read_bytes(), self.raw)

    def test_symlink_and_fifo_are_not_read(self):
        manifest = self.root / 'pubspec.yaml'
        manifest.unlink()
        manifest.symlink_to(self.root / 'lib/main.dart')
        with patch.object(metadata.os, 'read', side_effect=AssertionError('No read')):
            self.assertEqual(self.observe()['reason'], 'unsafe_metadata')
        manifest.unlink()
        os.mkfifo(manifest)
        with patch.object(metadata.os, 'read', side_effect=AssertionError('No read')):
            self.assertEqual(self.observe()['reason'], 'unsafe_metadata')

    def test_only_manifest_body_read_and_all_descriptors_closed(self):
        real_open, real_read, real_close = os.open, os.read, os.close
        names, opened, closed = {}, [], []
        def opening(name, *args, **kwargs):
            fd = real_open(name, *args, **kwargs)
            names[fd] = name
            opened.append(fd)
            return fd
        def reading(fd, size):
            self.assertEqual(names[fd], 'pubspec.yaml')
            return real_read(fd, size)
        def closing(fd):
            closed.append(fd)
            return real_close(fd)
        with patch.object(metadata.os, 'open', side_effect=opening), \
                patch.object(metadata.os, 'read', side_effect=reading), \
                patch.object(metadata.os, 'close', side_effect=closing):
            self.assertEqual(self.observe()['status'], 'observed')
        self.assertCountEqual(opened, closed)

    def test_stat_open_symlink_replacement_is_changed_without_outside_read(self):
        real_open = os.open
        with tempfile.TemporaryDirectory(prefix='asg-metadata-replacement-') as outside:
            target = Path(outside) / 'manifest'
            target.write_bytes(b'outside sentinel')
            def opening(name, *args, **kwargs):
                if name == 'pubspec.yaml':
                    manifest = self.root / name
                    manifest.rename(self.root / 'held')
                    manifest.symlink_to(target)
                return real_open(name, *args, **kwargs)
            with patch.object(metadata.os, 'open', side_effect=opening), \
                    patch.object(metadata.os, 'read', side_effect=AssertionError('No read')):
                self.assertEqual(self.observe()['status'], 'changed')
            self.assertEqual(target.read_bytes(), b'outside sentinel')
            self.assertEqual((self.root / 'held').read_bytes(), self.raw)

    def test_missing_runner_appearing_before_final_validation_is_changed(self):
        original = metadata.Reader.validate
        def validate(reader):
            (self.root / 'web').mkdir()
            return original(reader)
        with patch.object(metadata.Reader, 'validate', validate):
            self.assertEqual(self.observe()['reason'], 'missing_metadata_appeared')

    def test_invalid_root_requests_never_open_files(self):
        values = [None, '', 'relative', '/', str(self.root) + '/',
                  str(self.root) + '/..', '/bad\nroot', '/' + 'x/' * 129 + 'end']
        with patch.object(metadata.os, 'open', side_effect=AssertionError('No open')):
            for root in values:
                with self.subTest(root=root):
                    self.assertNotEqual(metadata.inspect_project(root)['status'], 'observed')

    def test_unsupported_host_does_not_open(self):
        with patch.object(metadata, 'SUPPORTED_HOST', False), \
                patch.object(metadata.os, 'open', side_effect=AssertionError('No open')):
            self.assertEqual(self.observe()['reason'], 'posix_nofollow_unavailable')

    def test_linked_root_and_ancestor_refused(self):
        alias = self.root / 'alias'
        alias.symlink_to(self.root, target_is_directory=True)
        for root in [alias, alias / 'lib']:
            self.assertEqual(metadata.inspect_project(str(root))['status'], 'unsupported')

    def test_linked_lib_and_each_runner_refused(self):
        lib = self.root / 'lib'
        lib.rename(self.root / 'held-lib')
        lib.symlink_to(self.root / 'held-lib', target_is_directory=True)
        self.assertEqual(self.observe()['status'], 'unsupported')
        lib.unlink()
        (self.root / 'held-lib').rename(lib)
        for name in metadata.RUNNERS:
            runner = self.root / name
            runner.symlink_to(lib, target_is_directory=True)
            self.assertEqual(self.observe()['status'], 'unsupported')
            runner.unlink()

    def test_main_hardlink_and_symlink_refused_without_body_read(self):
        main = self.root / 'lib/main.dart'
        with tempfile.TemporaryDirectory(prefix='asg-main-outside-') as t:
            target = Path(t) / 'private-source'
            target.write_bytes(b'outside source sentinel')
            main.unlink()
            os.link(target, main)
            self.assertEqual(self.observe()['reason'], 'unsafe_metadata')
            main.unlink()
            main.symlink_to(target)
            self.assertEqual(self.observe()['reason'], 'unsafe_metadata')
            self.assertEqual(target.read_bytes(), b'outside source sentinel')

    def test_stat_open_disappearance_and_hardlink_change(self):
        real_open = os.open
        manifest = self.root / 'pubspec.yaml'
        for mode in ['disappear', 'hardlink', 'grow']:
            manifest.write_bytes(self.raw)
            def opening(name, *args, **kwargs):
                if name == 'pubspec.yaml':
                    if mode == 'disappear':
                        manifest.unlink()
                    elif mode == 'hardlink':
                        os.link(manifest, self.root / 'alias-manifest')
                    else:
                        manifest.write_bytes(self.raw + b'growth')
                return real_open(name, *args, **kwargs)
            with patch.object(metadata.os, 'open', side_effect=opening), \
                    patch.object(metadata.os, 'read', side_effect=AssertionError('No read')):
                self.assertEqual(self.observe()['status'], 'changed')
            alias = self.root / 'alias-manifest'
            if alias.exists():
                alias.unlink()

    def test_manifest_mutation_during_read_discards_payload(self):
        real_read = os.read
        for replacement in [b'', b'x' * len(self.raw), b'x' * 65537]:
            (self.root / 'pubspec.yaml').write_bytes(self.raw)
            changed = False
            def reading(fd, size):
                nonlocal changed
                result = real_read(fd, size)
                if not changed:
                    changed = True
                    (self.root / 'pubspec.yaml').write_bytes(replacement)
                return result
            with patch.object(metadata.os, 'read', side_effect=reading):
                self.assertEqual(self.observe()['status'], 'changed')

    def test_final_manifest_and_main_replacement_or_removal(self):
        original = metadata.Reader.validate
        for relative in ['pubspec.yaml', 'lib/main.dart']:
            target = self.root / relative
            data = target.read_bytes()
            def validate(reader):
                target.rename(self.root / 'held-entry')
                target.write_bytes(data)
                return original(reader)
            with patch.object(metadata.Reader, 'validate', validate):
                self.assertEqual(self.observe()['status'], 'changed')
            (self.root / 'held-entry').unlink()
        def removing(reader):
            (self.root / 'lib/main.dart').unlink()
            return original(reader)
        with patch.object(metadata.Reader, 'validate', removing):
            self.assertEqual(self.observe()['status'], 'changed')

    def test_root_lib_and_runner_directory_replacement(self):
        initial = self.root
        original = metadata.Reader.validate
        for name in ['selected', 'lib', 'web']:
            self.root = initial / ('case-' + name)
            self.root.mkdir()
            (self.root / 'lib').mkdir()
            (self.root / 'lib/main.dart').write_bytes(b'not read')
            (self.root / 'pubspec.yaml').write_bytes(self.raw)
            (self.root / 'web').mkdir()
            target = self.root if name == 'selected' else self.root / name
            def validate(reader):
                target.rename(target.with_name(target.name + '-held'))
                target.mkdir()
                return original(reader)
            with patch.object(metadata.Reader, 'validate', validate):
                self.assertEqual(self.observe()['status'], 'changed')

    def test_permission_errors_not_reported_as_absent_and_stay_private(self):
        real_open = os.open
        def opening(name, *args, **kwargs):
            if name == 'web':
                raise PermissionError('private-sentinel')
            return real_open(name, *args, **kwargs)
        with patch.object(metadata.os, 'open', side_effect=opening):
            value = self.observe()
        self.assertEqual(value['status'], 'unavailable')
        self.assertNotIn('private-sentinel', json.dumps(value))

    def test_final_stat_error_is_changed_and_private(self):
        original = metadata.Reader.validate
        def validate(reader):
            with patch.object(metadata.os, 'stat', side_effect=PermissionError('private-sentinel')):
                return original(reader)
        with patch.object(metadata.Reader, 'validate', validate):
            value = self.observe()
        self.assertEqual(value['status'], 'changed')
        self.assertNotIn('private-sentinel', json.dumps(value))

    def test_all_descriptors_close_after_read_error(self):
        real_open, real_close = os.open, os.close
        opened, closed = [], []
        def opening(*args, **kwargs):
            fd = real_open(*args, **kwargs)
            opened.append(fd)
            return fd
        def closing(fd):
            closed.append(fd)
            return real_close(fd)
        with patch.object(metadata.os, 'open', side_effect=opening), \
                patch.object(metadata.os, 'close', side_effect=closing), \
                patch.object(metadata.os, 'read', side_effect=OSError('private-sentinel')):
            self.assertEqual(self.observe()['status'], 'unavailable')
        self.assertCountEqual(opened, closed)
        self.assertGreater(len(opened), 2)

    def test_no_directory_scan_high_level_open_or_process_calls(self):
        with patch.object(metadata.os, 'listdir', side_effect=AssertionError('No scan')), \
                patch.object(metadata.os, 'scandir', side_effect=AssertionError('No scan')), \
                patch('builtins.open', side_effect=AssertionError('No high-level open')), \
                patch.object(subprocess, 'run', side_effect=AssertionError('No process')):
            self.assertEqual(self.observe()['status'], 'observed')

    def test_all_fixed_runners_reported_without_inspecting_contents(self):
        for name in metadata.RUNNERS:
            (self.root / name).mkdir()
            (self.root / name / 'private').write_bytes(b'not read')
        self.assertEqual(self.observe()['included_runners'], list(metadata.RUNNERS))

    def test_invalid_cli_request_never_echoes_arguments(self):
        result = subprocess.run([sys.executable, '-I', '-S', '-B',
                                 str(Path(metadata.__file__).resolve()), '--private-sentinel'],
                                capture_output=True, timeout=5)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(result.stderr, b'')
        self.assertNotIn(b'private-sentinel', result.stdout)
        self.assertEqual(json.loads(result.stdout)['reason'], 'invalid_request')

    def test_stat_open_fifo_replacement_is_nonblocking_and_changed(self):
        real_open = os.open
        def opening(name, *args, **kwargs):
            if name == 'pubspec.yaml':
                (self.root / name).unlink()
                os.mkfifo(self.root / name)
            return real_open(name, *args, **kwargs)
        with patch.object(metadata.os, 'open', side_effect=opening), \
                patch.object(metadata.os, 'read', side_effect=AssertionError('No read')):
            self.assertEqual(self.observe()['status'], 'changed')

    def test_unreadable_main_is_unavailable_not_missing_or_verified(self):
        real_open = os.open
        def opening(name, *args, **kwargs):
            if name == 'main.dart':
                raise PermissionError('private-sentinel')
            return real_open(name, *args, **kwargs)
        with patch.object(metadata.os, 'open', side_effect=opening):
            self.assertEqual(self.observe()['status'], 'unavailable')

    def test_unsupported_syscall_is_explicit(self):
        with patch.object(metadata.os, 'open', side_effect=NotImplementedError('private-sentinel')):
            self.assertEqual(self.observe()['reason'], 'posix_nofollow_unavailable')

    def test_all_descriptors_close_on_representative_refusals(self):
        real_open, real_close = os.open, os.close
        for mode in ['missing', 'oversize', 'symlink', 'hardlink', 'changed']:
            manifest = self.root / 'pubspec.yaml'
            if manifest.exists() or manifest.is_symlink():
                manifest.unlink()
            manifest.write_bytes(self.raw)
            if mode == 'missing':
                manifest.unlink()
            elif mode == 'oversize':
                manifest.write_bytes(b'x' * 65537)
            elif mode == 'symlink':
                manifest.unlink()
                manifest.symlink_to(self.root / 'lib/main.dart')
            elif mode == 'hardlink':
                os.link(manifest, self.root / 'held-alias')
            opened, closed = [], []
            def opening(name, *args, **kwargs):
                if mode == 'changed' and name == 'pubspec.yaml':
                    manifest.unlink()
                fd = real_open(name, *args, **kwargs)
                opened.append(fd)
                return fd
            def closing(fd):
                closed.append(fd)
                return real_close(fd)
            with patch.object(metadata.os, 'open', side_effect=opening), \
                    patch.object(metadata.os, 'close', side_effect=closing):
                self.assertNotEqual(self.observe()['status'], 'observed')
            self.assertCountEqual(opened, closed)
            alias = self.root / 'held-alias'
            if alias.exists():
                alias.unlink()

    def test_actual_isolated_cli_has_fixed_bounded_json(self):
        result = subprocess.run([sys.executable, '-I', '-S', '-B',
                                 str(Path(metadata.__file__).resolve()), '--root', str(self.root)],
                                capture_output=True, timeout=5)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stderr, b'')
        value = json.loads(result.stdout)
        self.assertEqual(value['status'], 'observed')
        self.assertEqual(set(value), {'version', 'scope', 'status', 'reason',
                         'manifest_base64', 'included_runners', 'main_present', 'source_verified'})


if __name__ == '__main__':
    unittest.main()
