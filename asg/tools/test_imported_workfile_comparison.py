# SPDX-License-Identifier: MPL-2.0
# Copyright 2026 Arpit Sinha
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import imported_workfile_comparison as work
import test_imported_index as fixture


def blob(data):
    return hashlib.sha1(b'blob ' + str(len(data)).encode('ascii') + b'\0' + data).hexdigest()


class WorkfileTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='asg-workfile-test-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.git = self.root / '.git'
        self.git.mkdir()
        (self.root / 'lib').mkdir()
        self.file = self.root / 'lib/main.dart'
        self.data = b'void main() {}\n'
        self.file.write_bytes(self.data)
        self.file.chmod(0o600)
        self.index_path = self.git / 'index'
        self.selected = {'path': 'lib/main.dart', 'mode': '100644', 'oid': blob(self.data)}
        self.index_path.write_bytes(fixture.encoded([fixture.entry(oid=bytes.fromhex(self.selected['oid']))], extra=fixture.extension()))
        self.d = {'version': 1, 'scope': 'imported-workfile-comparison-request',
                  'root': str(self.root), 'python': str(Path(sys.executable).resolve()),
                  'comparison_id': 'a' * 32, 'index_request_sha256': 'b' * 64,
                  'index_observation_sha256': 'c' * 64,
                  'index_sha256': hashlib.sha256(self.index_path.read_bytes()).hexdigest(),
                  'index_byte_length': self.index_path.stat().st_size, 'selected_files': [self.selected]}
        work.index._stop_requested = False
        work.index._deadline = None
        self.addCleanup(setattr, work.index, '_stop_requested', False)
        self.addCleanup(setattr, work.index, '_deadline', None)

    def raw(self):
        return json.dumps(self.d, separators=(',', ':'))

    def observe(self):
        with patch('subprocess.Popen', side_effect=AssertionError('No subprocess')) as launch:
            value = work.observe(self.raw())
            launch.assert_not_called()
        self.assertFalse(value['git_state_verified'])
        self.assertFalse(value['commit_authorized'])
        self.assertFalse(value['mutation_authorized'])
        self.assertEqual(value['filters'], 'unknown')
        self.assertEqual(value['working_tree'], 'unknown')
        self.assertEqual(value['head_membership'], 'unknown')
        return value

    def refused(self, value, reason=None):
        self.assertNotEqual(value['status'], 'observed')
        self.assertEqual(value['files'], [])
        self.assertIsNone(value['index_sha256'])
        if reason:
            self.assertEqual(value['reason'], reason)

    def refresh(self):
        raw = self.index_path.read_bytes()
        self.d['index_sha256'] = hashlib.sha256(raw).hexdigest()
        self.d['index_byte_length'] = len(raw)

    def test_matching_bytes_and_modes_are_literal_preserved_and_content_free(self):
        before = {self.file: self.file.read_bytes(), self.index_path: self.index_path.read_bytes()}
        (self.git / 'config').write_text('must never run filters or trust this config')
        value = self.observe()
        self.assertEqual(value['status'], 'observed')
        self.assertEqual(value['request_sha256'], hashlib.sha256(self.raw().encode()).hexdigest())
        self.assertEqual(value['files'], [{'path': 'lib/main.dart', 'byte_length': len(self.data),
            'sha256': hashlib.sha256(self.data).hexdigest(), 'raw_blob': blob(self.data),
            'executable': False, 'raw_blob_matches': True, 'executable_matches': True}])
        self.assertEqual(before, {p: p.read_bytes() for p in before})
        self.assertNotIn('content_base64', json.dumps(value))
        self.assertNotIn(self.data.decode(), json.dumps(value))

    def test_byte_mode_crlf_empty_and_binary_comparisons_do_not_normalize(self):
        for data in (b'changed', self.data.replace(b'\n', b'\r\n'), b'', bytes(range(256))):
            self.file.write_bytes(data)
            value = self.observe()
            self.assertEqual(value['status'], 'observed')
            self.assertEqual(value['files'][0]['raw_blob'], blob(data))
            self.assertFalse(value['files'][0]['raw_blob_matches'])
            self.assertTrue(value['files'][0]['executable_matches'])
        self.file.write_bytes(self.data)
        self.file.chmod(0o700)
        value = self.observe()
        self.assertTrue(value['files'][0]['raw_blob_matches'])
        self.assertFalse(value['files'][0]['executable_matches'])

    def test_missing_unindexed_and_changed_declaration_refuse(self):
        self.file.unlink()
        self.refused(self.observe(), 'source_missing')
        self.d['selected_files'] = [{**self.selected, 'path': 'lib/other.dart'}]
        self.refused(self.observe(), 'unindexed')
        self.d['selected_files'] = [{**self.selected, 'oid': 'd' * 40}]
        self.refused(self.observe(), 'index_changed')

    def test_stale_index_length_hash_or_corrupt_unsupported_bytes_refuse(self):
        for change in ({'index_sha256': 'd' * 64}, {'index_byte_length': self.d['index_byte_length'] + 1}):
            old = dict(self.d)
            self.d.update(change)
            self.refused(self.observe(), 'index_changed')
            self.d = old
        for raw in [fixture.encoded([fixture.entry()], version=3), fixture.encoded([fixture.entry()], extra=fixture.extension(b'link')), b'x' * 112]:
            self.index_path.write_bytes(raw)
            self.refresh()
            self.refused(self.observe(), 'unsupported_index')

    def test_source_and_index_links_hardlinks_and_parent_indirection_refuse(self):
        outside = self.root / 'outside'
        outside.write_bytes(b'owner sentinel')
        for kind in ('symlink', 'hardlink'):
            self.file.unlink()
            if kind == 'symlink': self.file.symlink_to(outside)
            else: os.link(outside, self.file)
            self.refused(self.observe())
            self.assertEqual(outside.read_bytes(), b'owner sentinel')
        self.file.unlink()
        self.file.write_bytes(self.data)
        (self.root / 'lib').rename(self.root / 'actual')
        (self.root / 'lib').symlink_to(self.root / 'actual', target_is_directory=True)
        self.refused(self.observe())
        raw = self.index_path.read_bytes()
        self.index_path.unlink()
        self.index_path.symlink_to(outside)
        self.refused(self.observe())
        self.index_path.unlink()
        self.index_path.write_bytes(raw)
        os.link(self.index_path, self.git / 'index-alias')
        self.refused(self.observe())

    def test_per_file_and_aggregate_bounds_never_return_partial_files(self):
        self.file.write_bytes(b'x' * (work.FILE_LIMIT + 1))
        self.refused(self.observe(), 'bounds')
        selected = []
        entries = []
        for i in range(3):
            name = f'lib/file{i}.dart'
            data = b'x' * (24 * 1024)
            (self.root / name).write_bytes(data)
            selected.append({'path': name, 'mode': '100644', 'oid': blob(data)})
            entries.append(fixture.entry(name.encode(), oid=bytes.fromhex(blob(data))))
        self.index_path.write_bytes(fixture.encoded(entries))
        self.refresh()
        self.d['selected_files'] = selected
        self.refused(self.observe(), 'bounds')

    def test_existing_and_appearing_locks_preserve_lock_bytes(self):
        lock = self.git / 'index.lock'
        lock.write_bytes(b'owner lock')
        self.refused(self.observe(), 'changed')
        self.assertEqual(lock.read_bytes(), b'owner lock')
        lock.unlink()
        original = work.index.Reader.read
        def read(reader, parent, name, limit):
            value = original(reader, parent, name, limit)
            if name == 'main.dart': lock.write_bytes(b'appeared')
            return value
        with patch.object(work.index.Reader, 'read', read):
            self.refused(self.observe(), 'changed')
        self.assertEqual(lock.read_bytes(), b'appeared')

    def test_joint_readset_rejects_changed_source_index_inode_or_directory(self):
        original = work.index.Reader.read
        raw = self.index_path.read_bytes()
        for kind in ('source', 'index', 'inode', 'directory'):
            def read(reader, parent, name, limit):
                value = original(reader, parent, name, limit)
                if name == 'main.dart':
                    if kind == 'source': self.file.write_bytes(b'changed after read')
                    elif kind == 'index': self.index_path.write_bytes(fixture.encoded([]))
                    elif kind == 'inode':
                        self.index_path.rename(self.git / 'old-index')
                        self.index_path.write_bytes(raw)
                    else:
                        (self.root / 'lib').rename(self.root / 'old-lib')
                        (self.root / 'lib').mkdir()
                        self.file.write_bytes(self.data)
                return value
            with self.subTest(kind=kind), patch.object(work.index.Reader, 'read', read):
                self.refused(self.observe(), 'changed')
            if kind == 'directory':
                shutil.rmtree(self.root / 'lib')
                (self.root / 'old-lib').rename(self.root / 'lib')
            if (self.git / 'old-index').exists(): (self.git / 'old-index').unlink()
            self.index_path.write_bytes(raw)
            self.file.write_bytes(self.data)

    def test_invalid_requests_fail_before_root_access(self):
        invalid = [{'extra': True}, {'version': True}, {'comparison_id': '0' * 32},
                   {'root': '../outside'}, {'python': str(self.file)}, {'index_sha256': 'X' * 64},
                   {'selected_files': [{**self.selected, 'path': 'lib/../escape.dart'}]},
                   {'selected_files': [self.selected, self.selected]}, {'index_byte_length': 32},
                   {'selected_files': [{**self.selected, 'extra': True}]}]
        with patch.object(work.index.Reader, 'root', side_effect=AssertionError('No root access')):
            for update in invalid:
                with self.subTest(update=update), self.assertRaises((ValueError, UnicodeError)):
                    work.observe(json.dumps({**self.d, **update}))
            with self.assertRaises(ValueError): work.request('{"version":1,' + self.raw()[1:])
            with self.assertRaises(ValueError): work.request(' ' * (work.REQUEST_LIMIT + 1))

    def test_foreign_python_has_no_root_read(self):
        self.d['python'] = '/missing/python'
        with patch.object(work.index.Reader, 'root', side_effect=AssertionError('No root read')):
            self.refused(self.observe(), 'unavailable')

    def test_stop_deadline_and_late_stop_never_promote_a_comparison(self):
        work.index._stop_requested = True
        with patch.object(work.index.Reader, 'root', side_effect=AssertionError('No root read')):
            self.refused(self.observe(), 'stopped')
        work.index._stop_requested = False
        with patch.object(work.time, 'monotonic', side_effect=[0, 6, 6]):
            self.refused(self.observe(), 'unavailable')
        close = work.index.Reader.close
        def stopped(reader):
            close(reader)
            work.index.stop(None, None)
        with patch.object(work.index.Reader, 'close', stopped):
            self.refused(self.observe(), 'stopped')

    def test_actual_private_cli_and_all_three_bundled_assets(self):
        payload = self.root / 'request.json'
        payload.write_text(self.raw())
        payload.chmod(0o600)
        run = lambda: subprocess.run([sys.executable, '-I', '-S', '-B', work.__file__, str(payload)], capture_output=True, text=True, timeout=10)
        result = run()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)['status'], 'observed')
        payload.write_text('private invalid request')
        result = run()
        self.assertEqual(result.returncode, 2)
        self.assertEqual(result.stdout, '')
        self.assertNotIn('private invalid request', result.stderr)
        payload.unlink()
        payload.symlink_to(self.file)
        self.assertEqual(run().returncode, 2)
        self.assertEqual(self.file.read_bytes(), self.data)


if __name__ == '__main__':
    unittest.main(verbosity=2)
