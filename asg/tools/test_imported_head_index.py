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
import zlib

import imported_head_index as head
import test_imported_index as fixture


def oid(kind, data):
    return hashlib.sha1(kind.encode() + b' ' + str(len(data)).encode() + b'\0' + data).hexdigest()


def repository(root, files=None, tree_files=None, index_files=None, symbolic=False):
    files = files if files is not None else {'lib/main.dart': (b'void main() {}\n', '100644')}
    tree_files = files if tree_files is None else tree_files
    index_files = files if index_files is None else index_files
    git = root / '.git'
    git.mkdir()
    objects = {}
    def store(kind, data):
        label = oid(kind, data)
        path = git / 'objects' / label[:2] / label[2:]
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(zlib.compress(kind.encode() + b' ' + str(len(data)).encode() + b'\0' + data))
        objects[(kind, label)] = path
        return label
    nodes = {}
    for name, value in tree_files.items():
        parent = nodes
        parts = name.split('/')
        for part in parts[:-1]: parent = parent.setdefault(part, {})
        parent[parts[-1]] = value
    def tree(node):
        raw = b''
        for name, value in sorted(node.items(), key=lambda e: e[0] + ('/' if isinstance(e[1], dict) else '')):
            if isinstance(value, dict): mode, label = '40000', tree(value)
            else: mode, label = value[1], store('blob', value[0])
            raw += mode.encode() + b' ' + name.encode() + b'\0' + bytes.fromhex(label)
        return store('tree', raw)
    tree_oid = tree(nodes)
    commit_oid = store('commit', b'tree ' + tree_oid.encode() + b'\nauthor Fixture\ncommitter Fixture\n\nowned\n')
    if symbolic:
        (git / 'refs/heads').mkdir(parents=True)
        (git / 'refs/heads/main').write_text(commit_oid + '\n')
        (git / 'HEAD').write_text('ref: refs/heads/main\n')
    else: (git / 'HEAD').write_text(commit_oid + '\n')
    for name, (data, mode) in files.items():
        path = root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        path.chmod(0o700 if mode == '100755' else 0o600)
    raw = fixture.encoded([fixture.entry(name.encode(), mode=int(mode, 8), oid=bytes.fromhex(oid('blob', data)))
                           for name, (data, mode) in sorted(index_files.items())], extra=fixture.extension())
    (git / 'index').write_bytes(raw)
    request = {'version': 1, 'scope': 'imported-head-index-read-request', 'root': str(root),
               'python': str(Path(sys.executable).resolve()), 'read_id': 'a' * 32,
               'workfile_request_sha256': 'b' * 64, 'workfile_observation_sha256': 'c' * 64,
               'index_sha256': hashlib.sha256(raw).hexdigest(), 'index_byte_length': len(raw),
               'selected_files': [{'path': name, 'index_mode': index_files[name][1], 'index_oid': oid('blob', index_files[name][0]),
                  'working_sha256': hashlib.sha256(data).hexdigest(), 'working_byte_length': len(data),
                  'working_raw_blob': oid('blob', data), 'working_executable': mode == '100755'}
                  for name, (data, mode) in sorted(files.items())]}
    return request, objects, commit_oid, tree_oid


class HeadIndexTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='asg-head-index-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.d, self.objects, self.commit, self.tree = repository(self.root)
        self.git = self.root / '.git'
        head.index._stop_requested = False
        head.index._deadline = None
        self.addCleanup(setattr, head.index, '_stop_requested', False)
        self.addCleanup(setattr, head.index, '_deadline', None)

    def raw(self): return json.dumps(self.d, separators=(',', ':'))

    def observe(self):
        with patch('subprocess.Popen', side_effect=AssertionError('No process')) as launch:
            value = head.observe(self.raw())
            launch.assert_not_called()
        for key in ('git_state_verified', 'repository_authenticated', 'commit_authorized', 'mutation_authorized'):
            self.assertFalse(value[key])
        for key in ('working_tree', 'head_membership', 'filters', 'untracked'):
            self.assertEqual(value[key], 'unknown')
        return value

    def refused(self, value, reason=None):
        self.assertNotEqual(value['status'], 'observed')
        self.assertEqual(value['files'], [])
        self.assertEqual(value['object_count'], 0)
        self.assertEqual(value['object_bytes'], 0)
        for key in ('acquisition', 'head_form', 'declared_ref', 'head_oid', 'tree_oid', 'index_sha256'):
            self.assertIsNone(value[key])
        if reason: self.assertEqual(value['reason'], reason)

    def test_direct_and_symbolic_reads_verify_objects_without_content_or_authority(self):
        before = {p: p.read_bytes() for p in self.root.rglob('*') if p.is_file()}
        value = self.observe()
        self.assertEqual(value['status'], 'observed')
        self.assertEqual(value['head_oid'], self.commit)
        self.assertEqual(value['tree_oid'], self.tree)
        self.assertEqual(value['object_count'], 4)
        self.assertTrue(value['files'][0]['index_matches_tree'])
        self.assertTrue(value['files'][0]['working_bytes_match_tree'])
        self.assertTrue(value['files'][0]['working_executable_matches_tree'])
        self.assertNotIn('content_base64', json.dumps(value))
        self.assertEqual(value['request_sha256'], hashlib.sha256(self.raw().encode()).hexdigest())
        self.assertEqual(before, {p: p.read_bytes() for p in before})
        (self.git / 'refs/heads').mkdir(parents=True)
        (self.git / 'refs/heads/main').write_text(self.commit + '\n')
        (self.git / 'HEAD').write_text('ref: refs/heads/main\n')
        symbolic = self.observe()
        self.assertEqual(symbolic['head_form'], 'symbolic')
        self.assertEqual(symbolic['declared_ref'], 'refs/heads/main')

    def test_general_nested_selection_and_shared_tree_cache_are_bounded(self):
        shutil.rmtree(self.git)
        files = {'lib/nested/main.dart': (b'one', '100644'), 'lib/nested/peer.dart': (b'two', '100755'),
                 'test/one.dart': (b'one', '100644'), 'test/two.dart': (b'two', '100755')}
        self.d, self.objects, self.commit, self.tree = repository(self.root, files=files)
        value = self.observe()
        self.assertEqual(value['status'], 'observed')
        self.assertEqual(len(value['files']), 4)
        self.assertEqual(value['object_count'], 7)  # commit, four trees, two shared blobs.
        self.assertTrue(all(f['index_matches_tree'] for f in value['files']))

    def test_staged_unstaged_modes_missing_paths_and_binary_bytes_stay_independent(self):
        for mode in ('staged', 'unstaged', 'mode', 'missing', 'binary'):
            shutil.rmtree(self.git)
            original = {'lib/main.dart': (b'original\r\n', '100644')}
            working = {'lib/main.dart': (b'changed', '100755' if mode == 'mode' else '100644')}
            if mode == 'binary': working = {'lib/main.dart': (b'\0\xff\x07', '100644')}
            tree_files = {} if mode == 'missing' else original
            index_files = original if mode == 'unstaged' else working
            self.d, self.objects, self.commit, self.tree = repository(self.root, files=working, tree_files=tree_files, index_files=index_files)
            value = self.observe()
            self.assertEqual(value['status'], 'observed')
            f = value['files'][0]
            self.assertEqual(f['index_matches_tree'], mode == 'unstaged')
            self.assertFalse(f['working_bytes_match_tree'])
            self.assertEqual(f['working_executable_matches_tree'], mode not in ('mode', 'missing'))
            if mode == 'missing': self.assertIsNone(f['tree_oid'])

    def test_layout_redirection_replacement_alternates_and_packed_refs_refuse(self):
        for marker in ('commondir', 'gitdir', 'reftable', 'shallow', 'config.worktree', 'packed-refs'):
            p = self.git / marker
            p.write_text('owned marker')
            self.refused(self.observe())
            self.assertEqual(p.read_text(), 'owned marker')
            p.unlink()
        (self.git / 'refs/replace').mkdir(parents=True)
        self.refused(self.observe(), 'unsupported_layout')
        (self.git / 'refs/replace').rmdir()
        (self.git / 'objects/info').mkdir()
        for name in ('alternates', 'http-alternates'):
            p = self.git / 'objects/info' / name
            p.write_text('../outside')
            self.refused(self.observe(), 'unsupported_layout')
            p.unlink()

    def test_missing_loose_object_has_no_packed_or_process_fallback(self):
        path = self.objects[('commit', self.commit)]
        path.unlink()
        (self.git / 'objects/pack').mkdir()
        (self.git / 'objects/pack/ignored.pack').write_text('never read as fallback')
        self.refused(self.observe(), 'missing_loose_object')

    def test_links_hardlinks_and_directory_indirection_refuse(self):
        outside = self.root / 'outside'
        outside.write_bytes(b'owner sentinel')
        original = self.objects[('commit', self.commit)]
        data = original.read_bytes()
        for kind in ('symlink', 'hardlink'):
            original.unlink()
            if kind == 'symlink': original.symlink_to(outside)
            else:
                original.write_bytes(data)
                os.link(original, self.root / 'object-alias')
            self.refused(self.observe())
            self.assertEqual(outside.read_bytes(), b'owner sentinel')
            if (self.root / 'object-alias').exists(): (self.root / 'object-alias').unlink()
        original.unlink()
        original.write_bytes(data)
        source = self.root / 'lib/main.dart'
        source.unlink()
        source.symlink_to(outside)
        self.refused(self.observe())
        source.unlink()
        source.write_bytes(b'void main() {}\n')
        (self.root / 'lib').rename(self.root / 'actual-lib')
        (self.root / 'lib').symlink_to(self.root / 'actual-lib', target_is_directory=True)
        self.refused(self.observe())

    def test_corrupt_headers_ids_streams_inflation_and_stored_bounds_refuse(self):
        path = self.objects[('commit', self.commit)]
        original = path.read_bytes()
        for raw in (b'not zlib', zlib.compress(b'commit 4\0evil'), original + b'trailing', original[:-1],
                    zlib.compress(b'commit 10000000\0' + b'x' * 10000000), b'x' * 131073):
            path.write_bytes(raw)
            self.refused(self.observe())
            self.assertEqual(path.read_bytes(), raw)
        path.write_bytes(original)
        with patch.object(head, 'OBJECT_LIMIT', 1): self.refused(self.observe(), 'bounds')
        with patch.object(head, 'OBJECT_COUNT', 1): self.refused(self.observe(), 'bounds')

    def test_expected_index_and_working_fingerprints_are_checked_before_publication(self):
        for key, value in [('index_sha256', 'd' * 64), ('index_byte_length', self.d['index_byte_length'] + 1)]:
            old = self.d[key]
            self.d[key] = value
            self.refused(self.observe(), 'index_changed')
            self.d[key] = old
        f = self.d['selected_files'][0]
        for key, value in [('index_oid', 'd' * 40), ('working_sha256', 'd' * 64), ('working_raw_blob', 'd' * 40),
                           ('working_byte_length', f['working_byte_length'] + 1), ('working_executable', True)]:
            old = f[key]
            f[key] = value
            self.refused(self.observe(), 'index_changed' if key == 'index_oid' else 'working_file_changed')
            f[key] = old

    def test_joint_held_head_ref_index_object_and_source_changes_refuse(self):
        original = head.Reader.read
        for kind in ('HEAD', 'ref', 'index', 'object', 'source', 'replacement'):
            if kind == 'ref':
                (self.git / 'refs/heads').mkdir(parents=True, exist_ok=True)
                (self.git / 'refs/heads/main').write_text(self.commit + '\n')
                (self.git / 'HEAD').write_text('ref: refs/heads/main\n')
            snapshots = {p: p.read_bytes() for p in self.root.rglob('*') if p.is_file()}
            def read(reader, parent, name, limit):
                value = original(reader, parent, name, limit)
                if name == 'main.dart':
                    if kind == 'HEAD': (self.git / 'HEAD').write_text('d' * 40 + '\n')
                    elif kind == 'ref': (self.git / 'refs/heads/main').write_text('d' * 40 + '\n')
                    elif kind == 'index': (self.git / 'index').write_bytes(fixture.encoded([]))
                    elif kind == 'object': self.objects[('commit', self.commit)].write_bytes(b'changed')
                    elif kind == 'source': (self.root / 'lib/main.dart').write_bytes(b'changed')
                    else:
                        p = self.git / 'index'
                        p.rename(self.git / 'old-index')
                        p.write_bytes(snapshots[p])
                return value
            with self.subTest(kind=kind), patch.object(head.Reader, 'read', read):
                self.refused(self.observe(), 'changed')
            if (self.git / 'old-index').exists(): (self.git / 'old-index').unlink()
            for p, data in snapshots.items(): p.write_bytes(data)

    def test_existing_and_appearing_index_head_and_ref_locks_refuse_untouched(self):
        for name in ('index.lock', 'HEAD.lock'):
            lock = self.git / name
            lock.write_bytes(b'owned lock')
            self.refused(self.observe(), 'changed')
            self.assertEqual(lock.read_bytes(), b'owned lock')
            lock.unlink()
        (self.git / 'refs/heads').mkdir(parents=True)
        (self.git / 'refs/heads/main').write_text(self.commit + '\n')
        (self.git / 'HEAD').write_text('ref: refs/heads/main\n')
        lock = self.git / 'refs/heads/main.lock'
        lock.write_text('owned ref lock')
        self.refused(self.observe(), 'changed')
        lock.unlink()
        read = head.Reader.read
        def locked(reader, parent, name, limit):
            value = read(reader, parent, name, limit)
            if name == 'main.dart': lock.write_text('appeared')
            return value
        with patch.object(head.Reader, 'read', locked): self.refused(self.observe(), 'changed')
        self.assertEqual(lock.read_text(), 'appeared')

    def test_invalid_requests_or_foreign_python_never_open_root(self):
        f = self.d['selected_files'][0]
        for update in [{'extra': True}, {'version': True}, {'read_id': '0' * 32}, {'python': str(self.root / 'python')},
                       {'selected_files': [f, f]}, {'selected_files': [{**f, 'path': 'lib/../escape.dart'}]},
                       {'selected_files': [{**f, 'working_executable': 1}]}, {'index_byte_length': 32}]:
            with patch.object(head.Reader, 'root', side_effect=AssertionError('No root read')), self.assertRaises(ValueError):
                head.observe(json.dumps({**self.d, **update}))
        with self.assertRaises(ValueError): head.request('{"version":1,' + self.raw()[1:])
        with self.assertRaises(ValueError): head.request(' ' * 16385)
        self.d['python'] = '/missing/python'
        with patch.object(head.Reader, 'root', side_effect=AssertionError('No root read')):
            self.refused(self.observe(), 'unavailable')

    def test_head_ref_and_shared_file_namespaces_cannot_escape(self):
        original = (self.git / 'HEAD').read_bytes()
        for value in ('ref: refs/heads/../escape\n', 'ref: refs/tags/main\n', 'a' * 64 + '\n', 'ref: refs/heads/missing\n'):
            (self.git / 'HEAD').write_text(value)
            self.refused(self.observe())
        outside = self.root / 'outside-ref'
        outside.write_text(self.commit + '\n')
        (self.git / 'refs/heads').mkdir(parents=True, exist_ok=True)
        branch = self.git / 'refs/heads/main'
        branch.symlink_to(outside)
        (self.git / 'HEAD').write_text('ref: refs/heads/main\n')
        self.refused(self.observe())
        branch.unlink()
        (self.git / 'HEAD').write_bytes(original)
        for target in (self.root / 'lib/main.dart', self.git / 'index'):
            alias = self.root / 'shared-alias'
            os.link(target, alias)
            self.refused(self.observe())
            alias.unlink()
        (self.git / 'objects').rename(self.root / 'outside-objects')
        (self.git / 'objects').symlink_to(self.root / 'outside-objects', target_is_directory=True)
        self.refused(self.observe())
        self.assertEqual(outside.read_text(), self.commit + '\n')

    def test_stop_deadline_and_late_stop_cannot_promote_partial_objects(self):
        head.index._stop_requested = True
        with patch.object(head.Reader, 'root', side_effect=AssertionError('No root read')):
            self.refused(self.observe(), 'stopped')
        head.index._stop_requested = False
        with patch.object(head.time, 'monotonic', side_effect=[0, 6, 6]):
            self.refused(self.observe(), 'unavailable')
        close = head.Reader.close
        def stopped(reader):
            close(reader)
            head.index.stop(None, None)
        with patch.object(head.Reader, 'close', stopped): self.refused(self.observe(), 'stopped')

    def test_actual_private_cli_uses_only_four_bundled_assets(self):
        payload = self.root / 'request.json'
        payload.write_text(self.raw())
        payload.chmod(0o600)
        def run(): return subprocess.run([sys.executable, '-I', '-S', '-B', head.__file__, str(payload)], capture_output=True, text=True, timeout=10)
        result = run()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)['status'], 'observed')
        payload.write_text('private invalid payload')
        result = run()
        self.assertEqual(result.returncode, 2)
        self.assertEqual(result.stdout, '')
        self.assertNotIn('private invalid payload', result.stderr)
        payload.unlink()
        payload.symlink_to(self.git / 'index')
        self.assertEqual(run().returncode, 2)


if __name__ == '__main__':
    unittest.main(verbosity=2)
