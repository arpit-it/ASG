# SPDX-License-Identifier: MPL-2.0
# Copyright 2026 Arpit Sinha
import base64
import hashlib
import json
import os
import socket
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import project_instruction_documents as documents


@unittest.skipUnless(documents.SUPPORTED_HOST, 'POSIX nofollow descriptors required')
class DocumentTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='asg-instruction-documents-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        (self.root / 'AGENTS.md').write_bytes(b'Untrusted text: never execute this.')
        (self.root / 'README.md').write_bytes(b'Readme\n')

    def observe(self, paths=('AGENTS.md',)):
        return documents.inspect_documents(str(self.root), paths)

    def test_fixed_response_and_exact_bytes_hash(self):
        value = self.observe(documents.PATHS)
        self.assertEqual(set(value), {'version', 'scope', 'status', 'reason',
                         'selected_paths', 'documents', 'source_verified'})
        self.assertEqual(value['status'], 'observed')
        self.assertIs(value['source_verified'], False)
        self.assertEqual(value['selected_paths'], list(documents.PATHS))
        for item in value['documents']:
            self.assertEqual(set(item), {'path', 'byte_length', 'sha256', 'content_base64'})
            raw = (self.root / item['path']).read_bytes()
            self.assertEqual(base64.b64decode(item['content_base64']), raw)
            self.assertEqual(item['byte_length'], len(raw))
            self.assertEqual(item['sha256'], hashlib.sha256(raw).hexdigest())

    def test_two_exact_limits_and_empty_document(self):
        for p in documents.PATHS:
            (self.root / p).write_bytes(b'x' * 32768)
        value = self.observe(documents.PATHS)
        self.assertEqual(value['status'], 'observed')
        self.assertLess(len(json.dumps(value).encode()), documents.OUTPUT_LIMIT)
        (self.root / 'AGENTS.md').write_bytes(b'')
        self.assertEqual(self.observe()['documents'][0]['byte_length'], 0)

    def test_oversized_rejected_before_read(self):
        (self.root / 'AGENTS.md').write_bytes(b'x' * 32769)
        with patch.object(documents.os, 'read', side_effect=AssertionError('No read')):
            self.assertEqual(self.observe()['reason'], 'document_too_large')

    def test_invalid_encoding_nul_discard_all_payload(self):
        for raw in [b'\xff', b'\xc0\x80', b'private\x00text']:
            (self.root / 'README.md').write_bytes(raw)
            value = self.observe(documents.PATHS)
            self.assertEqual(value['reason'], 'document_encoding')
            self.assertEqual(value['documents'], [])
            self.assertNotIn('private', json.dumps(value))

    def test_invalid_selection_never_opens(self):
        with patch.object(documents.os, 'open', side_effect=AssertionError('No open')):
            for paths in [[], ['README.md', 'AGENTS.md'], ['AGENTS.md'] * 2,
                          ['../AGENTS.md'], ['private-sentinel'], None, 'AGENTS.md']:
                value = self.observe(paths)
                self.assertEqual(value['selected_paths'], [])
                self.assertEqual(value['reason'], 'invalid_selection')

    def test_only_selected_body_is_read(self):
        real_open, real_read = os.open, os.read
        names = {}
        def opening(name, *a, **kw):
            fd = real_open(name, *a, **kw)
            names[fd] = name
            return fd
        def reading(fd, size):
            self.assertEqual(names[fd], 'README.md')
            return real_read(fd, size)
        with patch.object(documents.os, 'open', side_effect=opening), \
                patch.object(documents.os, 'read', side_effect=reading):
            self.assertEqual(self.observe(['README.md'])['status'], 'observed')

    def test_missing_and_linked_selected_entries_refuse(self):
        p = self.root / 'AGENTS.md'
        p.unlink()
        self.assertEqual(self.observe()['reason'], 'document_missing')
        p.symlink_to(self.root / 'README.md')
        self.assertEqual(self.observe()['reason'], 'unsafe_document')
        p.unlink()
        os.link(self.root / 'README.md', p)
        self.assertEqual(self.observe()['reason'], 'unsafe_document')

    def test_replacement_before_open_does_not_read_outside(self):
        real_open = os.open
        with tempfile.TemporaryDirectory(prefix='asg-instruction-outside-') as outside:
            sentinel = Path(outside) / 'sentinel'
            sentinel.write_bytes(b'outside private sentinel')
            def opening(name, *a, **kw):
                if name == 'AGENTS.md':
                    (self.root / name).rename(self.root / 'held')
                    (self.root / name).symlink_to(sentinel)
                return real_open(name, *a, **kw)
            with patch.object(documents.os, 'open', side_effect=opening), \
                    patch.object(documents.os, 'read', side_effect=AssertionError('No read')):
                self.assertEqual(self.observe()['status'], 'changed')
            self.assertEqual(sentinel.read_bytes(), b'outside private sentinel')

    def test_final_readset_change_discards_both(self):
        original = documents.Reader.validate
        def validate(reader):
            (self.root / 'AGENTS.md').write_bytes(b'changed')
            return original(reader)
        with patch.object(documents.Reader, 'validate', validate):
            value = self.observe(documents.PATHS)
            self.assertEqual(value['status'], 'changed')
            self.assertEqual(value['documents'], [])

    def test_isolated_cli_and_private_invalid_arguments(self):
        helper = str(Path(documents.__file__).resolve())
        for args, success in [(['--root', str(self.root), '--file', 'README.md'], True),
                              (['--private-sentinel'], False)]:
            result = subprocess.run([sys.executable, '-I', '-S', '-B', helper, *args],
                                    capture_output=True, timeout=5)
            self.assertEqual(result.stderr, b'')
            self.assertLessEqual(len(result.stdout), documents.OUTPUT_LIMIT)
            self.assertEqual(result.returncode, 0 if success else 2)
            value = json.loads(result.stdout)
            self.assertEqual(value['status'] == 'observed', success)
            if not success:
                self.assertNotIn(b'private-sentinel', result.stdout)

    def test_root_and_ancestor_links_refused(self):
        alias = self.root / 'alias'
        alias.symlink_to(self.root, target_is_directory=True)
        for root in [alias, alias / 'nested']:
            value = documents.inspect_documents(str(root), ['AGENTS.md'])
            self.assertEqual(value['status'], 'unsupported')
            self.assertEqual(value['documents'], [])

    def test_invalid_roots_do_not_open(self):
        with patch.object(documents.os, 'open', side_effect=AssertionError('No open')):
            for root in [None, '', '/', 'relative', str(self.root) + '/',
                         str(self.root) + '/..', '/bad\nroot', '/' + 'x/' * 129 + 'end']:
                self.assertNotEqual(documents.inspect_documents(root, ['AGENTS.md'])['status'],
                                    'observed')

    def test_fifo_and_stat_open_fifo_swap_refused_without_read(self):
        p = self.root / 'AGENTS.md'
        p.unlink()
        os.mkfifo(p)
        with patch.object(documents.os, 'read', side_effect=AssertionError('No read')):
            self.assertEqual(self.observe()['reason'], 'unsafe_document')
        p.unlink()
        p.write_bytes(b'original')
        real_open = os.open
        def opening(name, *a, **kw):
            if name == 'AGENTS.md':
                p.unlink()
                os.mkfifo(p)
            return real_open(name, *a, **kw)
        with patch.object(documents.os, 'open', side_effect=opening), \
                patch.object(documents.os, 'read', side_effect=AssertionError('No read')):
            self.assertEqual(self.observe()['status'], 'changed')

    def test_stat_open_hardlink_disappearance_and_growth(self):
        real_open = os.open
        p = self.root / 'AGENTS.md'
        for mode in ['hardlink', 'disappear', 'grow']:
            p.write_bytes(b'original')
            def opening(name, *a, **kw):
                if name == 'AGENTS.md':
                    if mode == 'hardlink':
                        os.link(p, self.root / 'held-link')
                    elif mode == 'disappear':
                        p.unlink()
                    else:
                        p.write_bytes(b'grown')
                return real_open(name, *a, **kw)
            with patch.object(documents.os, 'open', side_effect=opening), \
                    patch.object(documents.os, 'read', side_effect=AssertionError('No read')):
                self.assertEqual(self.observe()['status'], 'changed')
            alias = self.root / 'held-link'
            if alias.exists():
                alias.unlink()

    def test_midread_changes_discard_payload(self):
        real_read = os.read
        p = self.root / 'AGENTS.md'
        for replacement in [b'', b'replaced', b'x' * 32769]:
            p.write_bytes(b'original')
            changed = False
            def reading(fd, size):
                nonlocal changed
                result = real_read(fd, size)
                if not changed:
                    changed = True
                    p.write_bytes(replacement)
                return result
            with patch.object(documents.os, 'read', side_effect=reading):
                value = self.observe()
                self.assertEqual(value['status'], 'changed')
                self.assertEqual(value['documents'], [])

    def test_final_same_bytes_replacement_and_removal(self):
        original = documents.Reader.validate
        p = self.root / 'AGENTS.md'
        raw = p.read_bytes()
        for mode in ['replace', 'remove']:
            p.write_bytes(raw)
            def validate(reader):
                p.rename(self.root / 'held-document')
                if mode == 'replace':
                    p.write_bytes(raw)
                return original(reader)
            with patch.object(documents.Reader, 'validate', validate):
                self.assertEqual(self.observe()['status'], 'changed')
            (self.root / 'held-document').unlink()

    def test_final_root_and_ancestor_replacement(self):
        original = documents.Reader.validate
        for name in ['selected', 'ancestor']:
            ancestor = self.root / ('case-' + name)
            root = ancestor / 'selected'
            root.mkdir(parents=True)
            (root / 'AGENTS.md').write_bytes(b'original')
            target = root if name == 'selected' else ancestor
            def validate(reader):
                target.rename(target.with_name(target.name + '-held'))
                target.mkdir()
                return original(reader)
            with patch.object(documents.Reader, 'validate', validate):
                value = documents.inspect_documents(str(root), ['AGENTS.md'])
                self.assertEqual(value['status'], 'changed')
                self.assertEqual(value['documents'], [])

    def test_permission_read_and_final_errors_stay_private(self):
        for method in ['open', 'read']:
            with patch.object(documents.os, method, side_effect=PermissionError('private-sentinel')):
                value = self.observe()
            self.assertEqual(value['status'], 'unavailable')
            self.assertNotIn('private-sentinel', json.dumps(value))
        original = documents.Reader.validate
        def validate(reader):
            with patch.object(documents.os, 'stat', side_effect=OSError('private-sentinel')):
                return original(reader)
        with patch.object(documents.Reader, 'validate', validate):
            self.assertEqual(self.observe()['status'], 'changed')

    def test_owned_descriptors_close_on_success_and_failure(self):
        real_open, real_close, real_read = os.open, os.close, os.read
        for fail in [False, True]:
            opened, closed = [], []
            def opening(*a, **kw):
                fd = real_open(*a, **kw)
                opened.append(fd)
                return fd
            def closing(fd):
                closed.append(fd)
                return real_close(fd)
            def reading(*a):
                if fail:
                    raise OSError('private-sentinel')
                return real_read(*a)
            with patch.object(documents.os, 'open', side_effect=opening), \
                    patch.object(documents.os, 'close', side_effect=closing), \
                    patch.object(documents.os, 'read', side_effect=reading):
                value = self.observe(documents.PATHS)
            self.assertEqual(value['status'], 'unavailable' if fail else 'observed')
            self.assertCountEqual(opened, closed)
            self.assertEqual(len(closed), len(set(closed)))

    def test_no_scan_highlevel_open_network_process_or_write(self):
        with patch.object(documents.os, 'listdir', side_effect=AssertionError('No scan')), \
                patch.object(documents.os, 'scandir', side_effect=AssertionError('No scan')), \
                patch('builtins.open', side_effect=AssertionError('No high-level open')), \
                patch.object(subprocess, 'run', side_effect=AssertionError('No process')), \
                patch.object(documents.os, 'write', side_effect=AssertionError('No write')), \
                patch.object(socket, 'socket', side_effect=AssertionError('No network')):
            self.assertEqual(self.observe()['status'], 'observed')

    def test_unavailable_host_never_opens(self):
        with patch.object(documents, 'SUPPORTED_HOST', False), \
                patch.object(documents.os, 'open', side_effect=AssertionError('No open')):
            self.assertEqual(self.observe()['reason'], 'posix_nofollow_unavailable')
        with patch.object(documents.os, 'open', side_effect=NotImplementedError('private')):
            self.assertEqual(self.observe()['status'], 'unsupported')

    def test_selection_is_frozen_before_filesystem_work(self):
        paths = ['AGENTS.md']
        original = documents.Reader.root
        def root(reader, value):
            paths.append('README.md')
            return original(reader, value)
        with patch.object(documents.Reader, 'root', root):
            value = self.observe(paths)
        self.assertEqual(value['selected_paths'], ['AGENTS.md'])
        self.assertEqual([d['path'] for d in value['documents']], ['AGENTS.md'])

    def test_unicode_bom_and_line_endings_are_exact_bytes(self):
        raw = '\ufeffcafé\r\n招待\n'.encode('utf-8')
        (self.root / 'AGENTS.md').write_bytes(raw)
        item = self.observe()['documents'][0]
        self.assertEqual(base64.b64decode(item['content_base64']), raw)
        self.assertEqual(item['sha256'], hashlib.sha256(raw).hexdigest())
        self.assertEqual(item['byte_length'], len(raw))

    def test_cli_two_full_documents_and_invalid_selections(self):
        helper = str(Path(documents.__file__).resolve())
        for path in documents.PATHS:
            (self.root / path).write_bytes(b'x' * documents.DOCUMENT_LIMIT)
        for paths in [list(documents.PATHS), ['README.md', 'AGENTS.md'],
                      ['AGENTS.md', 'AGENTS.md'], ['../private-sentinel']]:
            args = ['--root', str(self.root)]
            for path in paths:
                args += ['--file', path]
            result = subprocess.run([sys.executable, '-I', '-S', '-B', helper, *args],
                                    capture_output=True, timeout=5)
            self.assertEqual(result.stderr, b'')
            self.assertLessEqual(len(result.stdout), documents.OUTPUT_LIMIT)
            value = json.loads(result.stdout)
            success = paths == list(documents.PATHS)
            self.assertEqual(result.returncode, 0 if success else 2)
            self.assertEqual(len(value['documents']), 2 if success else 0)
            if not success:
                self.assertNotIn(b'private-sentinel', result.stdout)

    def test_second_missing_or_oversized_discards_first(self):
        p = self.root / 'README.md'
        p.unlink()
        for oversized in [False, True]:
            if oversized:
                p.write_bytes(b'x' * (documents.DOCUMENT_LIMIT + 1))
            value = self.observe(documents.PATHS)
            self.assertEqual(value['status'], 'invalid')
            self.assertEqual(value['documents'], [])


if __name__ == '__main__':
    unittest.main()
