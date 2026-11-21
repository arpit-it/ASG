# SPDX-License-Identifier: MPL-2.0
# Copyright 2026 Arpit Sinha
import hashlib
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import imported_index as index


def entry(name=b'lib/main.dart', mode=0o100644, flags=0, oid=b'a' * 20):
    value = (struct.pack('!10I', 0, 0, 0, 0, 0, 0, mode, 0, 0, 1)
             + oid + struct.pack('!H', flags | len(name)) + name + b'\0')
    return value + b'\0' * (-len(value) % 8)


def encoded(entries, version=2, extra=b'', count=None):
    value = (b'DIRC' + struct.pack('!II', version, len(entries) if count is None else count)
             + b''.join(entries) + extra)
    return value + hashlib.sha1(value).digest()


def extension(signature=b'TREE', payload=b'opaque cache, not tree evidence'):
    return signature + struct.pack('!I', len(payload)) + payload


class IndexTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='asg-index-reader-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.git = self.root / '.git'
        self.git.mkdir()
        self.path = self.git / 'index'
        self.raw = encoded([entry()], extra=extension())
        self.path.write_bytes(self.raw)
        self.payload = json.dumps({'version': 1, 'scope': 'imported-index-read-request',
                                   'root': str(self.root),
                                   'python': str(Path(sys.executable).resolve()),
                                   'read_id': 'a' * 32}, separators=(',', ':'))
        index._stop_requested = False
        index._deadline = None
        self.addCleanup(setattr, index, '_stop_requested', False)
        self.addCleanup(setattr, index, '_deadline', None)

    def observe(self):
        with patch('subprocess.Popen', side_effect=AssertionError('No reader process')) as launch:
            value = index.observe(self.payload)
            launch.assert_not_called()
        self.assertFalse(value['git_state_verified'])
        self.assertFalse(value['commit_authorized'])
        self.assertFalse(value['mutation_authorized'])
        self.assertEqual(value['working_tree'], 'unknown')
        return value

    def refused(self, value, status=None):
        self.assertNotEqual(value['status'], 'observed')
        if status:
            self.assertEqual(value['status'], status)
        self.assertEqual(value['entries'], [])
        self.assertEqual(value['optional_caches'], [])
        self.assertIsNone(value['index_sha256'])
        self.assertIsNone(value['index_byte_length'])
        self.assertIsNone(value['format'])

    def test_known_tree_and_unrelated_packed_refs_are_opaque_and_preserved(self):
        (self.git / 'packed-refs').write_text('private fixture metadata never parsed')
        before = {p: p.read_bytes() for p in self.git.iterdir()}
        value = self.observe()
        self.assertEqual(value['status'], 'observed')
        self.assertEqual(value['entries'], [{'path': 'lib/main.dart', 'mode': '100644', 'oid': '61' * 20}])
        self.assertEqual(value['optional_caches'], ['TREE'])
        self.assertEqual(value['index_sha256'], hashlib.sha256(self.raw).hexdigest())
        self.assertEqual(value['index_byte_length'], len(self.raw))
        self.assertEqual(before, {p: p.read_bytes() for p in before})
        self.assertEqual(value['request_sha256'], hashlib.sha256(self.payload.encode()).hexdigest())

    def test_cache_payload_is_not_interpreted_but_is_identity_bound(self):
        old = self.observe()
        self.path.write_bytes(encoded([entry()], extra=extension(payload=b'not a valid cache tree')))
        new = self.observe()
        self.assertEqual(new['entries'], old['entries'])
        self.assertEqual(new['status'], 'observed')
        self.assertNotEqual(new['index_sha256'], old['index_sha256'])
        self.path.write_bytes(encoded([], extra=extension(payload=b'')))
        self.assertEqual(self.observe()['entries'], [])

    def test_unknown_or_mandatory_extensions_and_bad_envelopes_refuse(self):
        for extra in [extension(b'link'), extension(b'UNTR'), extension(b'sdir'),
                      extension() + extension(), b'TRE', b'TREE' + struct.pack('!I', 100)]:
            with self.subTest(extra=extra[:8]):
                self.path.write_bytes(encoded([entry()], extra=extra))
                self.refused(self.observe())

    def test_corrupt_unsupported_unsafe_or_impossible_entries_never_leak_partial_data(self):
        padding = bytearray(entry())
        padding[-1] = 1
        length = bytearray(entry())
        length[61] -= 1
        variants = [self.raw[:-1] + b'x', encoded([entry()], version=3), encoded([entry()], version=4),
                    encoded([], count=2049), encoded([b'bad']), encoded([bytes(padding)]), encoded([bytes(length)]),
                    encoded([entry(flags=0x1000)]), encoded([entry(flags=0x8000)]), encoded([entry(flags=0x4000)]),
                    encoded([entry(mode=0o120000)]), encoded([entry(mode=0o160000)]), encoded([entry(oid=b'\0' * 20)]),
                    encoded([entry(b'../outside')]), encoded([entry(b'.git/config')]), encoded([entry(b'/absolute')]),
                    encoded([entry(b'A'), entry(b'a')]), encoded([entry(b'z'), entry(b'a')]),
                    encoded([entry(b'a'), entry(b'a')]), encoded([entry('café'.encode())])]
        for data in variants:
            with self.subTest(sha=hashlib.sha256(data).hexdigest()):
                self.path.write_bytes(data)
                self.refused(self.observe())
                self.assertEqual(self.path.read_bytes(), data)
        self.path.write_bytes(b'x' * (index.INDEX_LIMIT + 1))
        self.refused(self.observe(), 'invalid')

    def test_links_hardlinks_and_shared_metadata_do_not_open_outside_data(self):
        outside = self.root / 'outside'
        outside.write_bytes(b'owner sentinel')
        self.path.unlink()
        self.path.symlink_to(outside)
        self.refused(self.observe(), 'unsupported')
        self.assertEqual(outside.read_bytes(), b'owner sentinel')
        self.path.unlink()
        self.path.write_bytes(self.raw)
        hard = self.git / 'hard'
        os.link(self.path, hard)
        self.refused(self.observe(), 'unsupported')
        hard.unlink()
        for marker in ('commondir', 'gitdir', 'reftable'):
            p = self.git / marker
            p.write_text('../outside')
            self.refused(self.observe(), 'unsupported')
            p.unlink()
        self.assertEqual(self.path.read_bytes(), self.raw)

    def test_existing_or_appearing_index_lock_refuses_without_touching_it(self):
        lock = self.git / 'index.lock'
        lock.write_text('owned lock')
        self.refused(self.observe(), 'changed')
        self.assertEqual(lock.read_text(), 'owned lock')
        lock.unlink()
        original = index.Reader.read
        def read(reader, *args):
            value = original(reader, *args)
            lock.write_text('appeared')
            return value
        with patch.object(index.Reader, 'read', read):
            self.refused(self.observe(), 'changed')
        self.assertEqual(lock.read_text(), 'appeared')
        self.assertEqual(self.path.read_bytes(), self.raw)

    def test_changed_or_replaced_held_index_and_retargeted_directory_refuse(self):
        original = index.Reader.read
        for mode in ('bytes', 'inode', 'directory'):
            with self.subTest(mode=mode):
                def read(reader, *args):
                    value = original(reader, *args)
                    if mode == 'bytes':
                        self.path.write_bytes(encoded([]))
                    elif mode == 'inode':
                        self.path.rename(self.git / 'old-index')
                        self.path.write_bytes(self.raw)
                    else:
                        self.git.rename(self.root / 'old-git')
                        self.git.mkdir()
                        self.path.write_bytes(self.raw)
                    return value
                with patch.object(index.Reader, 'read', read):
                    self.refused(self.observe(), 'changed')
                if mode == 'directory':
                    shutil.rmtree(self.git)
                    (self.root / 'old-git').rename(self.git)
                if (self.git / 'old-index').exists():
                    (self.git / 'old-index').unlink()
                self.path.write_bytes(self.raw)

    def test_missing_index_or_linked_git_layout_has_no_partial_observation(self):
        self.path.unlink()
        self.refused(self.observe(), 'invalid')
        self.git.rmdir()
        self.git.write_text('gitdir: ../outside')
        self.refused(self.observe(), 'unsupported')
        self.assertEqual(self.git.read_text(), 'gitdir: ../outside')

    def test_foreign_interpreter_and_malformed_request_have_no_index_read(self):
        data = json.loads(self.payload)
        foreign = self.root / 'foreign-python'
        foreign.write_text('must not execute')
        foreign.chmod(0o700)
        with patch.object(index.Reader, 'root', side_effect=AssertionError('No root read')):
            self.payload = json.dumps({**data, 'python': '/missing/foreign-python'})
            self.refused(self.observe(), 'unavailable')
        for update in [{'extra': True}, {'version': True}, {'read_id': '0' * 32},
                       {'root': '../outside'}, {'python': str(foreign)}]:
            with self.assertRaises((ValueError, UnicodeError)):
                index.observe(json.dumps({**data, **update}))
        with self.assertRaises(ValueError):
            index.request('{"version":1,' + json.dumps(data)[1:])

    def test_stop_before_read_and_during_final_close_cannot_report_observed(self):
        index._stop_requested = True
        with patch.object(index.Reader, 'root', side_effect=AssertionError('No root read')):
            self.refused(self.observe(), 'stopped')
        index._stop_requested = False
        original = index.Reader.close
        def close(reader):
            original(reader)
            index.stop(None, None)
        with patch.object(index.Reader, 'close', close):
            self.refused(self.observe(), 'stopped')
        self.assertEqual(self.path.read_bytes(), self.raw)

    def test_deadline_before_io_is_a_bounded_non_observation(self):
        with patch.object(index.time, 'monotonic', side_effect=[0, 6, 6]):
            self.refused(self.observe(), 'unavailable')
        self.assertEqual(self.path.read_bytes(), self.raw)

    def test_cli_uses_only_private_request_and_bundled_reader(self):
        payload = self.root / 'request.json'
        payload.write_text(self.payload)
        payload.chmod(0o600)
        result = subprocess.run([sys.executable, '-I', '-S', '-B', index.__file__, str(payload)],
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)['status'], 'observed')
        self.assertEqual(self.path.read_bytes(), self.raw)
        payload.write_text('private invalid request')
        failed = subprocess.run([sys.executable, '-I', '-S', '-B', index.__file__, str(payload)],
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(failed.returncode, 2)
        self.assertEqual(failed.stdout, '')
        self.assertNotIn('private invalid request', failed.stderr)
        payload.unlink()
        payload.symlink_to(self.path)
        refused = subprocess.run([sys.executable, '-I', '-S', '-B', index.__file__, str(payload)],
                                 capture_output=True, text=True, timeout=10)
        self.assertEqual(refused.returncode, 2)
        self.assertEqual(refused.stdout, '')


if __name__ == '__main__':
    unittest.main(verbosity=2)
