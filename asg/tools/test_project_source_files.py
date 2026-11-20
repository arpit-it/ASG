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

import project_source_files as sources


@unittest.skipUnless(sources.SUPPORTED_HOST, 'POSIX nofollow descriptors required')
class SourceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='asg-source-files-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        (self.root / 'lib/models').mkdir(parents=True)
        (self.root / 'test').mkdir()
        (self.root / 'lib/main.dart').write_bytes(b'void main() {}\r\n')
        (self.root / 'lib/models/value.dart').write_bytes(b'\xef\xbb\xbf// caf\xc3\xa9\n')
        (self.root / 'test/value_test.dart').write_bytes(b'// synthetic test source\n')

    def observe(self, paths=('lib/main.dart',)):
        return sources.inspect_sources(str(self.root), paths)

    def test_exact_nested_selection_hash_bytes_and_fixed_schema(self):
        paths = ['test/value_test.dart', 'lib/models/value.dart', 'lib/main.dart']
        result = self.observe(paths)
        self.assertEqual(result['status'], 'observed')
        self.assertEqual(result['scope'], 'project-source-files')
        self.assertIs(result['source_verified'], False)
        self.assertEqual(result['selected_paths'], paths)
        self.assertEqual(set(result), {'version','scope','status','reason','selected_paths','files','source_verified'})
        for item in result['files']:
            raw = (self.root / item['path']).read_bytes()
            self.assertEqual(set(item), {'path','byte_length','sha256','content_base64'})
            self.assertEqual(base64.b64decode(item['content_base64']), raw)
            self.assertEqual(item['byte_length'], len(raw))
            self.assertEqual(item['sha256'], hashlib.sha256(raw).hexdigest())

    def test_invalid_selection_never_opens_any_file(self):
        invalid = [None, 'lib/main.dart', [], ['lib/main.dart']*2,
                   ['lib/main.dart','lib/Main.dart'], ['lib/a.dart']*5,
                   ['/lib/main.dart'], ['lib/../outside.dart'], ['lib/./main.dart'],
                   ['lib//main.dart'], ['lib/main.dart/'], ['lib\\main.dart'],
                   ['lib/.hidden/main.dart'], ['.git/config.dart'], ['assets/key.dart'],
                   ['lib/main.DART'], ['lib/*.dart'], ['lib/main.dart\n'],
                   ['lib/a\x00.dart'], ['lib/caf\u00e9.dart'], ['lib/a b.dart'],
                   ['lib/\ud800.dart'], [12], ['lib/'+('a'*129)+'.dart'],
                   ['lib/'+('/'.join(['x']*15))+'/main.dart'],
                   ['lib/'+('/'.join(['x'*127]*4))+'/main.dart']]
        with patch.object(sources.os, 'open', side_effect=AssertionError('No open')):
            for paths in invalid:
                with self.subTest(paths=repr(paths)):
                    result = self.observe(paths)
                    self.assertEqual(result['reason'], 'invalid_selection')
                    self.assertEqual(result['files'], [])
                    self.assertEqual(result['selected_paths'], [])

    def test_only_single_validated_components_reach_descriptor_operations(self):
        directory, regular = sources.Reader.directory, sources.Reader.regular
        def opening(reader, parent, component):
            self.assertNotIn('/', component)
            self.assertNotIn(component, ('.','..'))
            return directory(reader, parent, component)
        def reading(reader, parent, basename, limit):
            self.assertNotIn('/', basename)
            return regular(reader, parent, basename, limit)
        with patch.object(sources.Reader,'directory',opening), patch.object(sources.Reader,'regular',reading):
            self.assertEqual(self.observe(['lib/models/value.dart'])['status'],'observed')

    def test_selected_symlink_directory_file_hardlink_and_missing_refuse(self):
        (self.root/'lib/link').symlink_to(self.root/'test',target_is_directory=True)
        (self.root/'lib/file.dart').symlink_to(self.root/'lib/main.dart')
        (self.root/'lib/target.dart').write_bytes(b'// data')
        os.link(self.root/'lib/target.dart',self.root/'lib/hard.dart')
        for path, reason in [('lib/link/value_test.dart','directory_indirection'),
                             ('lib/file.dart','unsafe_source'),('lib/hard.dart','unsafe_source'),
                             ('lib/missing.dart','source_missing')]:
            with self.subTest(path=path):
                result=self.observe([path]);self.assertEqual(result['reason'],reason);self.assertEqual(result['files'],[])

    def test_source_limits_and_invalid_encoding_discard_entire_capture(self):
        (self.root/'lib/main.dart').write_bytes(b'x'*sources.FILE_LIMIT)
        (self.root/'test/value_test.dart').write_bytes(b'y'*sources.FILE_LIMIT)
        result=self.observe(['lib/main.dart','test/value_test.dart'])
        self.assertEqual(result['status'],'observed')
        self.assertLess(len(json.dumps(result).encode()),sources.OUTPUT_LIMIT)
        (self.root/'lib/models/value.dart').write_bytes(b'z')
        self.assertEqual(self.observe(['lib/main.dart','test/value_test.dart','lib/models/value.dart'])['reason'],'sources_too_large')
        (self.root/'lib/main.dart').write_bytes(b'x'*(sources.FILE_LIMIT+1))
        with patch.object(sources.os,'read',side_effect=AssertionError('No read')):
            self.assertEqual(self.observe()['reason'],'source_too_large')
        for raw in [b'\xff',b'private\x00data']:
            (self.root/'lib/main.dart').write_bytes(raw)
            result=self.observe();self.assertEqual(result['reason'],'source_encoding');self.assertEqual(result['files'],[])
            self.assertNotIn('private',json.dumps(result))

    def test_replaced_source_refuses_final_readset_validation(self):
        regular=sources.Reader.regular
        def change(reader,parent,name,limit):
            data=regular(reader,parent,name,limit)
            replacement=self.root/'lib/replacement.dart';replacement.write_bytes(b'changed')
            os.replace(replacement,self.root/'lib/main.dart')
            return data
        with patch.object(sources.Reader,'regular',change):
            result=self.observe();self.assertEqual(result['status'],'changed');self.assertEqual(result['reason'],'source_changed');self.assertEqual(result['files'],[])

    def test_isolated_cli_has_private_bounded_protocol_and_no_project_import(self):
        (self.root/'sitecustomize.py').write_text("raise AssertionError('project import')")
        helper=Path(sources.__file__).resolve()
        run=subprocess.run([sys.executable,'-I','-S','-B',str(helper),'--root',str(self.root),'--file','lib/main.dart'],cwd=self.root,capture_output=True,timeout=5)
        self.assertEqual(run.returncode,0);self.assertEqual(run.stderr,b'')
        self.assertEqual(json.loads(run.stdout)['status'],'observed')
        refused=subprocess.run([sys.executable,'-I','-S','-B',str(helper),'--root',str(self.root),'--file','lib/../outside.dart'],cwd=self.root,capture_output=True,timeout=5)
        self.assertEqual(refused.returncode,2);self.assertEqual(refused.stderr,b'')
        self.assertEqual(json.loads(refused.stdout)['files'],[])

    def test_four_files_and_empty_source_keep_explicit_order(self):
        (self.root / 'lib/empty.dart').write_bytes(b'')
        paths = ['lib/empty.dart', 'lib/main.dart',
                 'test/value_test.dart', 'lib/models/value.dart']
        value = self.observe(paths)
        self.assertEqual(value['status'], 'observed')
        self.assertEqual([f['path'] for f in value['files']], paths)
        self.assertEqual(value['files'][0]['byte_length'], 0)
        self.assertEqual(value['files'][0]['content_base64'], '')

    def test_path_component_depth_and_exact_total_boundaries(self):
        # Pure admission checks avoid host-specific maximum filename lengths.
        exact_component = 'x' * 123 + '.dart'
        self.assertTrue(sources.selection(['lib/' + exact_component]))
        self.assertFalse(sources.selection(['lib/x' + exact_component]))
        depth = 'lib/' + '/'.join(['a'] * 14) + '/main.dart'
        self.assertTrue(sources.selection([depth]))
        self.assertFalse(sources.selection(['lib/a/' + depth[4:]]))
        path = 'lib/' + '/'.join(['x' * 127] * 3) + '/' + 'y' * 119 + '.dart'
        self.assertEqual(len(path), 512)
        self.assertTrue(sources.selection([path]))
        self.assertFalse(sources.selection([path.replace('y' * 119, 'y' * 120)]))

    def test_invalid_roots_never_open(self):
        with patch.object(sources.os, 'open', side_effect=AssertionError('No open')):
            for root in [None, '', '/', 'relative', str(self.root) + '/',
                         str(self.root) + '/..', '/bad\nroot',
                         '/' + 'x/' * 129 + 'end', '/bad\ud800root']:
                result = sources.inspect_sources(root, ['lib/main.dart'])
                self.assertNotEqual(result['status'], 'observed')
                self.assertEqual(result['files'], [])

    def test_root_and_ancestor_symlinks_never_capture(self):
        alias = self.root / 'alias'
        alias.symlink_to(self.root, target_is_directory=True)
        for root in [alias, alias / 'lib']:
            result = sources.inspect_sources(str(root), ['lib/main.dart'])
            self.assertEqual(result['status'], 'unsupported')
            self.assertEqual(result['files'], [])

    def test_unsupported_host_returns_before_any_open(self):
        with patch.object(sources, 'SUPPORTED_HOST', False), \
                patch.object(sources.os, 'open', side_effect=AssertionError('No open')):
            result = self.observe()
        self.assertEqual(result['status'], 'unsupported')
        self.assertEqual(result['reason'], 'posix_nofollow_unavailable')
        self.assertEqual(result['files'], [])

    def test_selection_is_frozen_before_root_or_file_access(self):
        paths = ['lib/main.dart']
        root = sources.Reader.root
        def opening(reader, path):
            paths[:] = ['lib/../outside.dart']
            return root(reader, path)
        with patch.object(sources.Reader, 'root', opening):
            result = self.observe(paths)
        self.assertEqual(result['status'], 'observed')
        self.assertEqual(result['selected_paths'], ['lib/main.dart'])

    def test_only_selected_source_is_read(self):
        real_open, real_read = os.open, os.read
        names = {}
        def opening(name, *a, **kw):
            fd = real_open(name, *a, **kw)
            names[fd] = name
            return fd
        def reading(fd, size):
            self.assertEqual(names[fd], 'value.dart')
            return real_read(fd, size)
        with patch.object(sources.os, 'open', opening), \
                patch.object(sources.os, 'read', reading):
            result = self.observe(['lib/models/value.dart'])
        self.assertEqual(result['status'], 'observed')

    def test_fifo_and_directory_selected_as_file_refuse_without_read(self):
        fifo = self.root / 'lib/fifo.dart'
        os.mkfifo(fifo)
        (self.root / 'lib/directory.dart').mkdir()
        with patch.object(sources.os, 'read', side_effect=AssertionError('No read')):
            for path in ['lib/fifo.dart', 'lib/directory.dart']:
                self.assertEqual(self.observe([path])['reason'], 'unsafe_source')

    def test_stat_open_fifo_symlink_disappear_growth_and_hardlink_races(self):
        target = self.root / 'lib/main.dart'
        other = self.root / 'lib/models/value.dart'
        real_open = os.open
        for mode in ['fifo', 'symlink', 'disappear', 'grow', 'hardlink']:
            target.write_bytes(b'original')
            def opening(name, *a, **kw):
                if name == 'main.dart':
                    if mode == 'grow':
                        target.write_bytes(b'changed and longer')
                    elif mode == 'hardlink':
                        os.link(target, self.root / 'lib/held.dart')
                    else:
                        target.unlink()
                        if mode == 'fifo':
                            os.mkfifo(target)
                        elif mode == 'symlink':
                            target.symlink_to(other)
                return real_open(name, *a, **kw)
            with patch.object(sources.os, 'open', opening), \
                    patch.object(sources.os, 'read', side_effect=AssertionError('No read')):
                result = self.observe()
            self.assertEqual(result['status'], 'changed', mode)
            self.assertEqual(result['files'], [], mode)
            if target.exists() or target.is_symlink():
                target.unlink()
            held = self.root / 'lib/held.dart'
            if held.exists():
                held.unlink()

    def test_midread_truncation_growth_and_same_size_rewrite_discard(self):
        target = self.root / 'lib/main.dart'
        real_read = os.read
        for replacement in [b'', b'replaced', b'x' * (sources.FILE_LIMIT + 1)]:
            target.write_bytes(b'original')
            changed = False
            def reading(fd, size):
                nonlocal changed
                result = real_read(fd, size)
                if not changed:
                    changed = True
                    target.write_bytes(replacement)
                return result
            with patch.object(sources.os, 'read', reading):
                result = self.observe()
            self.assertEqual(result['status'], 'changed')
            self.assertEqual(result['files'], [])

    def test_final_same_byte_replacement_and_unlink_discard(self):
        original = sources.Reader.validate
        target = self.root / 'lib/main.dart'
        data = target.read_bytes()
        for mode in ['replace', 'remove']:
            target.write_bytes(data)
            def validate(reader):
                target.rename(self.root / 'lib/held.dart')
                if mode == 'replace':
                    target.write_bytes(data)
                return original(reader)
            with patch.object(sources.Reader, 'validate', validate):
                result = self.observe()
            self.assertEqual(result['status'], 'changed')
            self.assertEqual(result['files'], [])
            (self.root / 'lib/held.dart').unlink()

    def test_final_source_directory_root_and_ancestor_replacements_discard(self):
        original = sources.Reader.validate
        for mode in ['source-directory', 'root', 'ancestor']:
            ancestor = self.root / ('case-' + mode)
            root = ancestor / 'selected'
            (root / 'lib').mkdir(parents=True)
            (root / 'lib/main.dart').write_bytes(b'original')
            target = root / 'lib' if mode == 'source-directory' else root if mode == 'root' else ancestor
            def validate(reader):
                target.rename(target.with_name(target.name + '-held'))
                target.mkdir()
                return original(reader)
            with patch.object(sources.Reader, 'validate', validate):
                result = sources.inspect_sources(str(root), ['lib/main.dart'])
            self.assertEqual(result['status'], 'changed')
            self.assertEqual(result['files'], [])

    def test_later_failure_never_leaks_earlier_selected_payload(self):
        (self.root / 'lib/main.dart').write_bytes(b'PRIVATE_SOURCE_SENTINEL')
        (self.root / 'test/value_test.dart').write_bytes(b'bad\x00encoding')
        result = self.observe(['lib/main.dart', 'test/value_test.dart'])
        self.assertEqual(result['files'], [])
        self.assertNotIn('PRIVATE_SOURCE_SENTINEL', json.dumps(result))
        self.assertNotIn(base64.b64encode(b'PRIVATE_SOURCE_SENTINEL').decode(), json.dumps(result))

    def test_duplicate_file_identity_refuses_even_distinct_admitted_spelling(self):
        original = sources.Reader.regular
        first = None
        def regular(reader, parent, name, limit):
            nonlocal first
            data = original(reader, parent, name, limit)
            if first is None:
                first = reader.files[-1][3]
            else:
                previous = reader.files[-1]
                reader.files[-1] = (*previous[:3], first)
            return data
        with patch.object(sources.Reader, 'regular', regular):
            result = self.observe(['lib/main.dart', 'test/value_test.dart'])
        self.assertEqual(result['reason'], 'duplicate_source_identity')
        self.assertEqual(result['files'], [])

    def test_permission_read_and_final_errors_stay_private(self):
        for method in ['open', 'read']:
            with patch.object(sources.os, method, side_effect=PermissionError('private-sentinel')):
                result = self.observe()
            self.assertEqual(result['status'], 'unavailable')
            self.assertEqual(result['files'], [])
            self.assertNotIn('private-sentinel', json.dumps(result))
        original = sources.Reader.validate
        def validate(reader):
            with patch.object(sources.os, 'stat', side_effect=OSError('private-sentinel')):
                return original(reader)
        with patch.object(sources.Reader, 'validate', validate):
            result = self.observe()
        self.assertEqual(result['status'], 'changed')
        self.assertNotIn('private-sentinel', json.dumps(result))

    def test_owned_descriptors_close_on_success_and_all_failure_stages(self):
        real_open, real_close, real_read = os.open, os.close, os.read
        for stage in ['success', 'root', 'directory', 'read', 'validation']:
            opened, closed = [], []
            def opening(name, *a, **kw):
                if stage == 'root' and name == '/':
                    raise PermissionError('private')
                if stage == 'directory' and name == 'lib':
                    raise PermissionError('private')
                fd = real_open(name, *a, **kw)
                opened.append(fd)
                return fd
            def closing(fd):
                closed.append(fd)
                return real_close(fd)
            def reading(fd, size):
                if stage == 'read':
                    raise PermissionError('private')
                return real_read(fd, size)
            def validate(reader):
                raise sources.Refusal('changed', 'source_changed')
            with patch.object(sources.os, 'open', opening), \
                    patch.object(sources.os, 'close', closing), \
                    patch.object(sources.os, 'read', reading):
                if stage == 'validation':
                    with patch.object(sources.Reader, 'validate', validate):
                        self.observe()
                else:
                    self.observe()
            self.assertEqual(closed, list(reversed(opened)), stage)
            for fd in opened:
                with self.assertRaises(OSError):
                    os.fstat(fd)

    def test_read_api_unavailable_refuses_privately(self):
        with patch.object(sources.os, 'read', side_effect=NotImplementedError('private-sentinel')):
            result = self.observe()
        self.assertEqual(result['reason'], 'posix_nofollow_unavailable')
        self.assertEqual(result['files'], [])
        self.assertNotIn('private-sentinel', json.dumps(result))

    def test_cli_malformed_arguments_never_echo_private_input(self):
        helper = str(Path(sources.__file__).resolve())
        for args in [[], ['--private-sentinel'], ['--root', str(self.root)],
                     ['--root', str(self.root), '--other', 'lib/main.dart'],
                     ['--root', str(self.root)] + ['--file', 'lib/main.dart'] * 5]:
            run = subprocess.run([sys.executable, '-I', '-S', '-B', helper, *args],
                                 capture_output=True, timeout=5)
            self.assertEqual(run.returncode, 2)
            self.assertEqual(run.stderr, b'')
            self.assertLessEqual(len(run.stdout), sources.OUTPUT_LIMIT)
            result = json.loads(run.stdout)
            self.assertEqual(result['reason'], 'invalid_request')
            self.assertEqual(result['files'], [])
            self.assertNotIn(b'private-sentinel', run.stdout)

    def test_output_ceiling_returns_only_fixed_refusal(self):
        # Exercise the complete-envelope cap if future payload limits grow.
        import io
        class Output:
            buffer = io.BytesIO()
        large = sources.report(['lib/main.dart'], 'observed', files=[{'content_base64': 'PRIVATE' * sources.OUTPUT_LIMIT}])
        output = Output()
        with patch.object(sources, 'inspect_sources', return_value=large), \
                patch.object(sources.sys, 'stdout', output):
            code = sources.main(['--root', str(self.root), '--file', 'lib/main.dart'])
        payload = output.buffer.getvalue()
        self.assertEqual(code, 2)
        self.assertLessEqual(len(payload), sources.OUTPUT_LIMIT)
        self.assertEqual(json.loads(payload)['reason'], 'output_limit')
        self.assertNotIn(b'PRIVATE', payload)

    def test_no_scan_highlevel_open_network_process_or_source_write(self):
        with patch.object(sources.os, 'listdir', side_effect=AssertionError('No scan')), \
                patch.object(sources.os, 'scandir', side_effect=AssertionError('No scan')), \
                patch('builtins.open', side_effect=AssertionError('No high-level open')), \
                patch.object(subprocess, 'run', side_effect=AssertionError('No process')), \
                patch.object(sources.os, 'write', side_effect=AssertionError('No write')), \
                patch.object(socket, 'socket', side_effect=AssertionError('No network')):
            self.assertEqual(self.observe(['lib/models/value.dart'])['status'], 'observed')

    def test_actual_maximum_path_and_component_depth_read_exact_bytes(self):
        path = 'lib/' + '/'.join(['x' * 127] * 3) + '/' + 'y' * 119 + '.dart'
        file = self.root / path
        file.parent.mkdir(parents=True)
        file.write_bytes(b'// maximum admitted path')
        value = self.observe([path])
        self.assertEqual(value['status'], 'observed')
        self.assertEqual(value['files'][0]['path'], path)
        deep = 'lib/' + '/'.join(['a'] * 14) + '/main.dart'
        file = self.root / deep
        file.parent.mkdir(parents=True)
        file.write_bytes(b'// maximum admitted depth')
        self.assertEqual(self.observe([deep])['status'], 'observed')

    def test_bom_unicode_crlf_and_normalization_distinctions_preserve_bytes(self):
        target = self.root / 'lib/main.dart'
        observed = []
        for text in ['\ufeffcafé\r\n招待\n', 'é', 'e\u0301']:
            data = text.encode('utf-8')
            target.write_bytes(data)
            value = self.observe()['files'][0]
            self.assertEqual(base64.b64decode(value['content_base64']), data)
            self.assertEqual(value['sha256'], hashlib.sha256(data).hexdigest())
            observed.append(value['sha256'])
        self.assertNotEqual(observed[1], observed[2])

    def test_isolated_cli_four_sources_at_exact_aggregate_ceiling(self):
        helper = str(Path(sources.__file__).resolve())
        (self.root / 'lib/main.dart').write_bytes(b'x' * sources.FILE_LIMIT)
        (self.root / 'test/value_test.dart').write_bytes(b'y' * sources.FILE_LIMIT)
        (self.root / 'lib/models/value.dart').write_bytes(b'')
        (self.root / 'lib/empty.dart').write_bytes(b'')
        paths = ['lib/main.dart', 'test/value_test.dart', 'lib/models/value.dart', 'lib/empty.dart']
        args = ['--root', str(self.root)]
        for path in paths:
            args += ['--file', path]
        run = subprocess.run([sys.executable, '-I', '-S', '-B', helper, *args],
                             capture_output=True, timeout=5)
        self.assertEqual(run.returncode, 0)
        self.assertEqual(run.stderr, b'')
        self.assertLessEqual(len(run.stdout), sources.OUTPUT_LIMIT)
        value = json.loads(run.stdout)
        self.assertEqual(value['selected_paths'], paths)
        self.assertEqual(sum(f['byte_length'] for f in value['files']), sources.AGGREGATE_LIMIT)
        self.assertEqual(len(value['files']), 4)

    def test_descriptor_open_flags_cannot_create_truncate_append_or_follow(self):
        real_open = os.open
        def opening(name, flags, *args, **kwargs):
            self.assertEqual(flags & os.O_ACCMODE, os.O_RDONLY)
            self.assertEqual(flags & (os.O_CREAT | os.O_TRUNC | os.O_APPEND), 0)
            self.assertNotEqual(flags & os.O_NOFOLLOW, 0)
            if not flags & os.O_DIRECTORY:
                self.assertNotEqual(flags & os.O_NONBLOCK, 0)
            return real_open(name, flags, *args, **kwargs)
        with patch.object(sources.os, 'open', opening):
            self.assertEqual(self.observe(['lib/models/value.dart'])['status'], 'observed')


if __name__=='__main__':
    unittest.main()
