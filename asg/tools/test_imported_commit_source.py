# SPDX-License-Identifier: MPL-2.0
# Copyright 2026 Arpit Sinha
import base64
from dataclasses import FrozenInstanceError
import hashlib
import os
from pathlib import Path
import subprocess
import tempfile
import json
import signal
import sys
import time
from unittest.mock import patch
import unittest

import imported_commit_source as observer


def oid(kind, data):
    return hashlib.sha1(kind.encode() + b' ' + str(len(data)).encode() + b'\0' + data).hexdigest()


def entry(name, mode=b'100644', value='a' * 40):
    return mode + b' ' + name + b'\0' + bytes.fromhex(value)


class CommitObjectParserTests(unittest.TestCase):
    def test_request_freezes_selection_without_claiming_native_admission(self):
        paths = ['lib/my-file.dart', 'test/peer.v2.dart']
        value = observer.request('/fixture/project', 'a' * 40, paths)
        paths.clear()
        self.assertEqual(value.paths, ('lib/my-file.dart', 'test/peer.v2.dart'))
        with self.assertRaises(FrozenInstanceError):
            value.root = '/changed'
        for root in ['/', '//fixture', '/fixture/../project', '/fixture/', '/fixture/\ud800', '/'+('x'*4096)]:
            with self.subTest(root=repr(root)), self.assertRaises(observer.InvalidCommitSource):
                observer.request(root, 'a'*40, ['lib/main.dart'])
        for commit in ['HEAD', 'a'*39, 'A'*40, '0'*40, 'a'*40+'^{tree}']:
            with self.assertRaises(observer.InvalidCommitSource):
                observer.request('/fixture', commit, ['lib/main.dart'])

    def test_invalid_or_ambiguous_readsets_refuse(self):
        for paths in [[], ['lib/main.dart']*2, ['lib/A.dart','lib/a.dart'], ['lib/../main.dart'], ['.git/config'], ['lib/.hidden.dart'], ['lib/a.dart\n'], ['lib/a\\b.dart'], ['lib/é.dart'], ['lib/a.dart']*5]:
            with self.subTest(paths=paths), self.assertRaises(observer.InvalidCommitSource):
                observer.selection(paths)

    def test_commit_tree_requires_verified_exact_bytes_and_unambiguous_header(self):
        tree = 'a'*40
        body = b'tree '+tree.encode()+b'\nauthor Fixture\ncommitter Fixture\n\nmessage\n'
        self.assertEqual(observer.commit_tree(oid('commit', body), body), tree)
        with self.assertRaises(observer.InvalidCommitSource):
            observer.commit_tree(oid('commit', body), body+b'changed')
        for bad in [b'tree '+tree.encode(), b'parent '+tree.encode()+b'\n\n', b'tree '+tree.encode()+b'\ntree '+tree.encode()+b'\n\n', b'tree '+b'0'*40+b'\n\n']:
            with self.assertRaises(observer.InvalidCommitSource):
                observer.commit_tree(oid('commit', bad), bad)

    def test_verified_binary_tree_preserves_entry_mode_and_identity(self):
        raw = entry(b'lib', b'40000')+entry(b'pubspec.yaml')+entry(b'test', b'40000')
        result = observer.tree_entries(oid('tree', raw), raw)
        self.assertEqual([(e.mode,e.name,e.oid) for e in result], [('40000','lib','a'*40),('100644','pubspec.yaml','a'*40),('40000','test','a'*40)])
        self.assertIsInstance(result, tuple)
        with self.assertRaises(FrozenInstanceError):
            result[0].mode = '100755'
        self.assertEqual(observer.tree_entries(oid('tree',b''),b''), ())
        with self.assertRaises(observer.InvalidCommitSource):
            observer.tree_entries(oid('tree', raw), raw[:-1])

    def test_unsafe_modes_names_collisions_sort_and_truncated_trees_refuse(self):
        cases=[entry(b'link',b'120000'),entry(b'submodule',b'160000'),entry(b'.git'),entry(b'..'),entry(b'a/b'),entry(b'a\n'),entry(b'a'*101),entry(b'A')+entry(b'a'),entry(b'a')+entry(b'a'),entry(b'z')+entry(b'a'),entry(b'lib',b'40000')[:-1],b'bad',entry(b'a',value='0'*40)]
        for raw in cases:
            with self.subTest(raw=raw[:40]), self.assertRaises(observer.InvalidCommitSource):
                observer.tree_entries(oid('tree',raw), raw)

    def test_selected_blob_preserves_bom_crlf_multibyte_and_empty_bytes(self):
        for raw in [b'\xef\xbb\xbf// caf\xc3\xa9\r\n', b'', b'// no newline']:
            blob = oid('blob',raw)
            result = observer.blob_record('lib/main.dart',blob,raw)
            self.assertEqual(base64.b64decode(result['content_base64']), raw)
            self.assertEqual(result['sha256'],hashlib.sha256(raw).hexdigest())
            self.assertEqual(result['byte_length'],len(raw))
            with self.assertRaises(observer.InvalidCommitSource):
                observer.blob_record('lib/main.dart',blob,raw+b'x')
        for raw in [b'\xff', b'x\0y', b'x'*(observer.FILE_LIMIT+1)]:
            with self.assertRaises(observer.InvalidCommitSource):
                observer.blob_record('lib/main.dart',oid('blob',raw),raw)

    def test_tree_entry_count_is_bounded(self):
        raw = b''.join(entry(('e%05d' % i).encode()) for i in range(observer.MAX_TREE_ENTRIES + 1))
        with self.assertRaises(observer.InvalidCommitSource):
            observer.tree_entries(oid('tree', raw), raw)

    def test_actual_owned_git_commit_tree_and_blob_match_parser_identities(self):
        with tempfile.TemporaryDirectory(prefix='asg-commit-parser-') as temporary:
            root = Path(temporary).resolve()
            env = {'PATH':'/usr/bin:/bin', 'GIT_CONFIG_NOSYSTEM':'1', 'GIT_CONFIG_GLOBAL':os.devnull, 'GIT_TERMINAL_PROMPT':'0'}
            def git(*args):
                return subprocess.run(['/usr/bin/git','--no-replace-objects','-C',str(root),'-c','core.hooksPath=/dev/null','-c','user.name=Fixture','-c','user.email=fixture@example.invalid','-c','commit.gpgsign=false',*args],env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=10,check=True).stdout
            git('init','-q')
            source = root/'lib/main.dart'; source.parent.mkdir()
            raw = b'\xef\xbb\xbf// caf\xc3\xa9\r\n'
            source.write_bytes(raw)
            git('add','lib/main.dart'); git('commit','-qm','synthetic parser fixture')
            commit = git('rev-parse','HEAD').decode().strip()
            tree = observer.commit_tree(commit,git('cat-file','commit',commit))
            top = observer.tree_entries(tree,git('cat-file','tree',tree))
            self.assertEqual([(e.mode,e.name) for e in top],[('40000','lib')])
            subtree = top[0].oid
            leaf = observer.tree_entries(subtree,git('cat-file','tree',subtree))[0]
            value = observer.blob_record('lib/'+leaf.name,leaf.oid,git('cat-file','blob',leaf.oid))
            self.assertEqual(base64.b64decode(value['content_base64']),raw)
            self.assertEqual(source.read_bytes(),raw)

    def test_all_object_bounds_and_types_refuse_privately(self):
        for kind,limit in [('commit',observer.COMMIT_LIMIT),('tree',observer.TREE_LIMIT),('blob',observer.FILE_LIMIT)]:
            raw=b'x'*(limit+1)
            with self.assertRaisesRegex(observer.InvalidCommitSource,'Invalid or oversized immutable source inputs'):
                observer.verified_object(kind,oid(kind,raw),raw)
        with self.assertRaises(observer.InvalidCommitSource):
            observer.verified_object('tag','a'*40,b'private data')


class NativeCommitObserverTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='asg-commit-observer-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()/'source'; self.root.mkdir()
        self.raw = b'\xef\xbb\xbf// caf\xc3\xa9\r\n'
        self.git('init','-q')
        for name,data in {'lib/main.dart':self.raw,'test/my-file.v2.dart':b'// peer\n','lib/other.dart':b'// original other\n'}.items():
            f=self.root/name;f.parent.mkdir(parents=True,exist_ok=True);f.write_bytes(data)
        self.commit()

    def git(self,*args,data=None):
        env={'PATH':'/usr/bin:/bin','GIT_CONFIG_NOSYSTEM':'1','GIT_CONFIG_GLOBAL':os.devnull,'GIT_TERMINAL_PROMPT':'0','GIT_NO_LAZY_FETCH':'1'}
        return subprocess.run(['/usr/bin/git','--no-replace-objects','-C',str(self.root),'-c','core.hooksPath=/dev/null','-c','user.name=Fixture','-c','user.email=fixture@example.invalid','-c','commit.gpgsign=false',*args],input=data,env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=10,check=True).stdout

    def commit(self):
        self.git('add','.')
        self.git('commit','-qm','synthetic fixture')
        self.head=self.git('rev-parse','HEAD').decode().strip()

    def observe(self,paths=None,**kwargs):
        return observer.observe(str(self.root),self.head,paths or ['lib/main.dart','test/my-file.v2.dart'],**kwargs)

    def assertRefused(self,value,reason=None):
        self.assertEqual(value['status'],'refused',value)
        self.assertEqual(value['files'],[])
        self.assertIsNone(value['tree']);self.assertIsNone(value['manifest_sha256'])
        self.assertFalse(value['source_verified'])
        if reason:self.assertEqual(value['reason'],reason)

    def test_real_read_protocol_exact_bytes_no_writes_and_dirty_invariance(self):
        before=(self.root/'.git/index').read_bytes()
        value=self.observe()
        self.assertEqual(value['status'],'observed',value)
        self.assertEqual(base64.b64decode(value['files'][0]['content_base64']),self.raw)
        self.assertEqual(value['manifest_files'],3)
        self.assertEqual(value['working_tree'],'unknown');self.assertEqual(value['conflict'],'unknown')
        (self.root/'lib/main.dart').write_bytes(b'// dirty\n')
        (self.root/'lib/untracked.dart').write_bytes(b'// local\n')
        self.assertEqual(self.observe(),value)
        self.assertEqual((self.root/'.git/index').read_bytes(),before)
        self.assertEqual((self.root/'lib/main.dart').read_bytes(),b'// dirty\n')
        script=Path(observer.__file__).resolve()
        result=subprocess.run([sys.executable,'-I','-S','-B',str(script),'--root',str(self.root),'--commit',self.head,'--file','lib/main.dart','--file','test/my-file.v2.dart'],stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=15)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(json.loads(result.stdout),value)
        self.assertLessEqual(len(result.stdout),observer.OUTPUT_LIMIT)

    def test_conflicted_index_is_preserved_and_never_used_for_blob_reads(self):
        hashes=[self.git('hash-object','-w','--stdin',data=d).strip() for d in (b'base',b'ours',b'theirs')]
        self.git('update-index','--index-info',data=b'0 '+b'0'*40+b'\tlib/main.dart\n'+b''.join(b'100644 '+h+b' '+str(i).encode()+b'\tlib/main.dart\n' for i,h in enumerate(hashes,1)))
        before=(self.root/'.git/index').read_bytes()
        value=self.observe()
        self.assertEqual(value['status'],'observed',value)
        self.assertEqual(base64.b64decode(value['files'][0]['content_base64']),self.raw)
        self.assertEqual((self.root/'.git/index').read_bytes(),before)
        self.assertEqual(value['conflict'],'unknown')

    def test_missing_commit_wrong_type_and_missing_selected_file_refuse(self):
        self.assertRefused(observer.observe(str(self.root),'f'*40,['lib/main.dart']))
        blob=self.git('rev-parse','HEAD:lib/main.dart').decode().strip()
        self.assertRefused(observer.observe(str(self.root),blob,['lib/main.dart']))
        self.assertRefused(self.observe(['lib/missing.dart']),'selected_path_missing')

    def test_unselected_symlink_and_gitlink_tree_entries_refuse(self):
        (self.root/'unsafe').symlink_to('/not-read')
        self.commit();self.assertRefused(self.observe(),'invalid_object_or_request')
        (self.root/'unsafe').unlink();self.git('add','-u')
        self.git('update-index','--add','--cacheinfo','160000,'+self.head+',vendor/submodule')
        self.git('commit','-qm','gitlink fixture');self.head=self.git('rev-parse','HEAD').decode().strip()
        self.assertRefused(self.observe(),'invalid_object_or_request')

    def test_case_collisions_in_unselected_tree_refuse(self):
        other=self.git('hash-object','-w','--stdin',data=b'other').decode().strip()
        self.git('update-index','--add','--cacheinfo','100644,'+other+',LIB/other.dart')
        self.git('commit','-qm','case fixture');self.head=self.git('rev-parse','HEAD').decode().strip()
        self.assertRefused(self.observe(),'invalid_object_or_request')

    def test_empty_committed_file_is_observed_not_missing(self):
        (self.root/'lib/main.dart').write_bytes(b'');self.commit()
        value=self.observe();self.assertEqual(value['status'],'observed',value)
        self.assertEqual(value['files'][0]['byte_length'],0)
        self.assertEqual(value['files'][0]['content_base64'],'')
        self.assertEqual(value['files'][0]['git_blob'],'e69de29bb2d1d6434b8b29ae775ad8c2e48c5391')

    def test_object_info_indirection_refuses_before_git_dispatch(self):
        info=self.root/'.git/objects/info'
        entry=info/'commit-graph';entry.symlink_to('/not-read')
        with patch.object(observer.subprocess,'Popen') as start:
            self.assertRefused(self.observe(),'unsupported_layout')
            start.assert_not_called()

    def test_file_and_aggregate_byte_limits_refuse(self):
        for name in ('lib/main.dart','test/my-file.v2.dart','lib/other.dart'):
            (self.root/name).write_bytes(b'a'*observer.FILE_LIMIT)
        self.commit()
        self.assertRefused(self.observe(['lib/main.dart','test/my-file.v2.dart','lib/other.dart']),'sources_limit')
        (self.root/'lib/main.dart').write_bytes(b'a'*(observer.FILE_LIMIT+1));self.commit()
        self.assertRefused(self.observe(),'object_limit')

    def test_tree_count_depth_and_metadata_byte_limits_refuse(self):
        for setting,value in [('MAX_FILES',2),('MAX_DIRECTORIES',1),('TREE_LIMIT',1)]:
            with self.subTest(setting=setting),patch.object(observer,setting,value):
                self.assertRefused(self.observe())

    def test_alternates_indirection_hardlinks_and_config_hazards_refuse(self):
        info=self.root/'.git/objects/info';info.mkdir(exist_ok=True)
        alternates=info/'alternates';alternates.write_text('/not-read\n')
        self.assertRefused(self.observe(),'unsupported_layout');alternates.unlink()
        config=self.root/'.git/config';original=config.read_bytes()
        for extra in [b'\n[include]\n path = /not-read\n',b'\n[core]\n fsmonitor = /not-run\n',b'\n[extensions]\n objectformat = sha256\n',b'\n[filter "test"]\n smudge = /not-run\n',b'\n[core]\n worktree = /not-read\n']:
            config.write_bytes(original+extra)
            self.assertRefused(self.observe(),'unsupported_configuration')
        config.write_bytes(original)
        marker=self.root/'.git/commondir';marker.write_text('/not-read')
        self.assertRefused(self.observe(),'unsupported_layout');marker.unlink()
        linked=config.with_name('linked-config');os.link(config,linked)
        self.assertRefused(self.observe(),'unsupported_layout');linked.unlink()
        saved=config.with_name('saved-config');config.rename(saved);config.symlink_to(saved)
        self.assertRefused(self.observe(),'unsupported_layout')

    def test_packed_objects_work_and_pack_symlinks_refuse(self):
        self.git('repack','-ad')
        value=self.observe();self.assertEqual(value['status'],'observed',value)
        pack=next((self.root/'.git/objects/pack').glob('*.pack'))
        saved=self.root.parent/'saved-pack';pack.rename(saved);pack.symlink_to(saved)
        self.assertRefused(self.observe(),'unsupported_layout')

    def test_stopped_deadline_and_configuration_change_drop_all_output(self):
        self.assertRefused(self.observe(stopped=lambda:True),'stopped')
        self.assertRefused(self.observe(deadline_seconds=0.000001),'deadline')
        original=observer._ObjectReader.read
        def changed(reader,kind,oid):
            data=original(reader,kind,oid)
            with (self.root/'.git/config').open('ab') as target:target.write(b'\n')
            return data
        with patch.object(observer._ObjectReader,'read',changed):
            self.assertRefused(self.observe(),'repository_changed')

    def test_corrupt_loose_object_cannot_publish_source_bytes(self):
        import zlib
        blob=self.git('rev-parse','HEAD:lib/main.dart').decode().strip()
        file=self.root/'.git/objects'/blob[:2]/blob[2:]
        original=file.read_bytes();mode=file.stat().st_mode
        file.chmod(0o600)
        try:
            file.write_bytes(zlib.compress(b'blob 4\0evil'))
            self.assertRefused(self.observe(),'invalid_object_or_request')
            self.assertEqual((self.root/'lib/main.dart').read_bytes(),self.raw)
        finally:
            file.write_bytes(original);file.chmod(mode)

    def test_aggregate_tree_depth_and_response_bounds(self):
        with patch.object(observer,'TREE_LIMIT',120):
            self.assertRefused(self.observe(),'tree_limit')
        with patch.object(observer,'OUTPUT_LIMIT',100):
            self.assertRefused(self.observe(),'response_limit')
        nested=self.root/('/'.join(['deep']*16))/'entry'
        nested.parent.mkdir(parents=True);nested.write_bytes(b'bounded')
        self.commit();self.assertRefused(self.observe(),'tree_limit')

    def test_cleanup_uncertainty_refuses_without_dispatching_more_reads(self):
        real=subprocess.Popen;children=[]
        def start(args,**kwargs):
            child=real(args,**kwargs);children.append(child)
            wait=child.wait
            def uncertain(timeout=None):
                wait(timeout=timeout)
                raise subprocess.TimeoutExpired('owned fixture child',timeout)
            child.wait=uncertain
            return child
        with patch.object(observer.subprocess,'Popen',start):
            self.assertRefused(self.observe(),'cleanup_uncertain')
        self.assertEqual(len(children),1)
        self.assertIsNotNone(children[0].poll())

    def test_cli_invalid_request_private_failure_and_layout_indirection(self):
        script=Path(observer.__file__).resolve()
        result=subprocess.run([sys.executable,'-I','-S','-B',str(script),'--root',str(self.root),'--commit','HEAD','--file','lib/main.dart'],stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=15)
        self.assertEqual(result.returncode,2)
        value=json.loads(result.stdout);self.assertRefused(value,'invalid_object_or_request')
        self.assertIsNone(value['root']);self.assertNotIn(str(self.root).encode(),result.stderr)
        git=self.root/'.git';saved=self.root.parent/'saved-git';git.rename(saved);git.symlink_to(saved,target_is_directory=True)
        self.assertRefused(self.observe(),'repository_unavailable')

    def test_command_surface_and_scrubbed_environment(self):
        real=subprocess.Popen;calls=[]
        def start(args,**kwargs):
            calls.append((args,kwargs));return real(args,**kwargs)
        with patch.dict(os.environ,{'GIT_EXTERNAL_DIFF':'private','GIT_CONFIG_COUNT':'1','GIT_CONFIG_KEY_0':'include.path','GIT_CONFIG_VALUE_0':'/not-read'}),patch.object(observer.subprocess,'Popen',start):
            value=self.observe()
        self.assertEqual(value['status'],'observed',value)
        for args,kwargs in calls:
            self.assertEqual(args[0],'/usr/bin/git')
            self.assertIn('cat-file',args)
            self.assertNotIn('GIT_EXTERNAL_DIFF',kwargs['env'])
            self.assertNotIn('GIT_CONFIG_COUNT',kwargs['env'])
            self.assertEqual(kwargs['env']['GIT_NO_LAZY_FETCH'],'1')
            self.assertIs(kwargs['stdin'],subprocess.DEVNULL)

    def test_command_output_limit_and_stop_kill_and_reap_owned_child(self):
        repository=observer._Repository(observer.request(str(self.root),self.head,['lib/main.dart']))
        repository.open();real=subprocess.Popen;children=[]
        try:
            for mode in ('limit','stop','deadline'):
                stop=False
                def start(_args,**kwargs):
                    nonlocal stop
                    code='import os,time;os.write(1,b"x"*100);time.sleep(10)' if mode=='limit' else 'import time;time.sleep(10)'
                    child=real([sys.executable,'-I','-S','-B','-c',code],**kwargs);children.append(child)
                    stop=mode=='stop'
                    return child
                reader=observer._ObjectReader(repository,time.monotonic()+(0.05 if mode=='deadline' else 2),lambda:stop)
                with patch.object(observer.subprocess,'Popen',start),self.assertRaises(observer._Refused):
                    reader.command(['cat-file','-s',self.head],1,self.head)
                self.assertIsNotNone(children[-1].poll())
        finally:
            repository.close()


if __name__ == '__main__':
    unittest.main()
