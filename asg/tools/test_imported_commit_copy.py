# SPDX-License-Identifier: MPL-2.0
# Copyright 2026 Arpit Sinha
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import unittest
from unittest.mock import patch

import imported_commit_copy as copy
import imported_commit_source as observer
import prepare_self_candidate as candidate
import test_prepare_self_candidate as legacy


class CopyTests(unittest.TestCase):
    setUp = legacy.CandidateTests.setUp
    def git(self, *args):
        return subprocess.check_output(
            ['/usr/bin/git', '--no-replace-objects', '-C', str(self.source),
             '-c', 'core.hooksPath=/dev/null', *args],
            env={'PATH':'/usr/bin:/bin','GIT_CONFIG_NOSYSTEM':'1',
                 'GIT_CONFIG_GLOBAL':os.devnull,'GIT_TERMINAL_PROMPT':'0'})
    commit = legacy.CandidateTests.commit

    def fixture(self):
        candidate._stop_requested = False
        self.addCleanup(setattr, candidate, '_stop_requested', False)
        for name, data in {'lib/main.dart':b'\xef\xbb\xbf// caf\xc3\xa9\r\n', 'test/peer.dart':b'',
                           'peer.bin':b'\x00\xffpeer', 'pubspec.yaml':b'name: fixture\n'}.items():
            file=self.source/name;file.parent.mkdir(parents=True,exist_ok=True);file.write_bytes(data)
        (self.source/'lib/main.dart').chmod(0o755)
        commit=self.commit()
        observed=observer.observe(str(self.source),commit,['lib/main.dart','test/peer.dart'])
        self.assertEqual(observed['status'],'observed')
        output=self.parent/'output';output.mkdir()
        data={'version':1,'scope':'imported-commit-copy-request','attempt_id':'a'*32,
              'root':str(self.source),'python':'/trusted/python','destination':str(output),
              'commit':commit,'tree':observed['tree'],'manifest_sha256':observed['manifest_sha256'],
              'manifest_files':observed['manifest_files'],'context_sha256':'b'*64,'plan_sha256':'c'*64,
              'proposal_sha256':'d'*64,'history_sha256':'e'*64,
              'selected_files':[{k:f[k] for k in ('path','mode','git_blob','sha256','byte_length')} for f in observed['files']]}
        return data

    def run_copy(self,data):
        raw=json.dumps(data,separators=(',',':'),ensure_ascii=False)
        return copy.prepare_copy(raw,candidate,observer)

    def test_actual_copy_preserves_immutable_bytes_modes_binary_and_dirty_source_index_refs(self):
        data=self.fixture();before={arg:self.git(*arg.split()) for arg in ['rev-parse HEAD','ls-files --stage','show-ref']}
        (self.source/'lib/main.dart').write_bytes(b'owner dirty\n');(self.source/'untracked').write_bytes(b'keep')
        result=self.run_copy(data)
        self.assertEqual(result['status'],'prepared');self.assertIsNone(result['reason'])
        ready=Path(result['copy_path']);self.assertEqual(ready.parent.parent,Path(data['destination']))
        self.assertEqual((ready/'lib/main.dart').read_bytes(),b'\xef\xbb\xbf// caf\xc3\xa9\r\n')
        self.assertEqual((ready/'test/peer.dart').read_bytes(),b'');self.assertEqual((ready/'peer.bin').read_bytes(),b'\x00\xffpeer')
        self.assertTrue((ready/'lib/main.dart').stat().st_mode&0o100)
        self.assertFalse((ready/'untracked').exists());self.assertFalse((ready.parent/copy.PENDING).exists())
        self.assertEqual(candidate.fingerprint(ready),result['fingerprint'])
        self.assertNotEqual(result['fingerprint'],data['manifest_sha256'])
        self.assertEqual(result['files'],4);self.assertEqual(result['bytes'],sum(p.stat().st_size for p in ready.rglob('*') if p.is_file()))
        self.assertFalse(result['source_verified']);self.assertEqual(result['working_tree'],'unknown')
        self.assertEqual((self.source/'lib/main.dart').read_bytes(),b'owner dirty\n')
        for arg,value in before.items():self.assertEqual(self.git(*arg.split()),value)
        self.assertEqual((self.source/'untracked').read_bytes(),b'keep')
        self.assertEqual(result['request_sha256'],hashlib.sha256(json.dumps(data,separators=(',',':')).encode()).hexdigest())

    def test_wrong_commit_tree_manifest_and_selected_identity_refuse_before_allocation(self):
        data=self.fixture()
        for field,value in [('commit','f'*40),('tree','f'*40),('manifest_sha256','f'*64),('manifest_files',5)]:
            with self.subTest(field=field):
                changed={**data,field:value};result=self.run_copy(changed)
                self.assertEqual(result['status'],'refused');self.assertEqual(result['reason'],'input_changed');self.assertIsNone(result['run_name'])
        for field,value in [('sha256','f'*64),('mode','100644'),('git_blob','f'*40),('byte_length',1)]:
            changed=json.loads(json.dumps(data));changed['selected_files'][0][field]=value
            self.assertEqual(self.run_copy(changed)['reason'],'input_changed')
        self.assertEqual(list(Path(data['destination']).iterdir()),[])

    def test_full_copy_overflow_refuses_even_when_selected_observation_succeeds(self):
        data=self.fixture();(self.source/'unselected.bin').write_bytes(b'x'*(candidate.MAX_FILE_BYTES+1));data['commit']=self.commit()
        observed=observer.observe(str(self.source),data['commit'],['lib/main.dart','test/peer.dart'])
        self.assertEqual(observed['status'],'observed')
        for field in ('tree','manifest_sha256','manifest_files'):data[field]=observed[field]
        result=self.run_copy(data);self.assertEqual(result['status'],'refused');self.assertEqual(result['reason'],'copy_unavailable')
        self.assertEqual(list(Path(data['destination']).iterdir()),[])

    def test_metadata_and_bundle_destination_never_allocate_output(self):
        data=self.fixture()
        for destination in [self.source,self.source/'.git/objects',self.parent/'Stable.app']:
            if not destination.exists():destination.mkdir()
            changed={**data,'destination':str(destination)}
            with self.assertRaises(ValueError):self.run_copy(changed)
            self.assertFalse(list(destination.glob('asg-self-candidate-*')))

    def test_symlinked_parent_refuses_without_touching_target(self):
        data=self.fixture();alias=self.parent/'alias';alias.symlink_to(data['destination'],target_is_directory=True)
        result=self.run_copy({**data,'destination':str(alias)})
        self.assertEqual(result['status'],'refused');self.assertEqual(list(Path(data['destination']).iterdir()),[])

    def test_changed_prepared_manifest_keeps_pending_run_without_success(self):
        data=self.fixture();original=candidate.prepare
        def changed(*args,**kwargs):
            ready=original(*args,**kwargs);(ready/'peer.bin').write_bytes(b'substituted');return ready
        with patch.object(candidate,'prepare',changed):result=self.run_copy(data)
        self.assertEqual(result['status'],'refused');self.assertIsNotNone(result['run_name']);self.assertIsNone(result['copy_path'])
        run=Path(data['destination'])/result['run_name'];self.assertTrue((run/copy.PENDING).is_file())
        self.assertEqual((self.source/'peer.bin').read_bytes(),b'\x00\xffpeer')

    def test_changed_mode_after_preparation_is_not_admitted(self):
        data=self.fixture();original=candidate.prepare
        def changed(*args,**kwargs):
            ready=original(*args,**kwargs);(ready/'lib/main.dart').chmod(0o600);return ready
        with patch.object(candidate,'prepare',changed):result=self.run_copy(data)
        self.assertEqual(result['status'],'refused');self.assertIsNotNone(result['run_name'])

    def test_stop_before_dispatch_and_after_prepare_preserves_recovery(self):
        data=self.fixture();candidate._stop_requested=True
        result=self.run_copy(data);self.assertEqual(result['reason'],'stopped');self.assertIsNone(result['run_name'])
        self.assertEqual(list(Path(data['destination']).iterdir()),[]);candidate._stop_requested=False
        original=candidate.prepare
        def stopped(*args,**kwargs):
            ready=original(*args,**kwargs);candidate._stop_requested=True;return ready
        with patch.object(candidate,'prepare',stopped):result=self.run_copy(data)
        self.assertEqual(result['reason'],'stopped');self.assertIsNotNone(result['run_name'])
        self.assertTrue((Path(data['destination'])/result['run_name']/copy.PENDING).exists())

    def test_preparation_failure_retains_existing_run_and_does_not_remove_unrelated_output(self):
        data=self.fixture();other=Path(data['destination'])/'keep';other.write_bytes(b'owner output')
        original=candidate.write_blob
        def fail(*args):raise OSError('private fixture failure')
        with patch.object(candidate,'write_blob',fail):result=self.run_copy(data)
        self.assertEqual(result['status'],'refused');self.assertIsNotNone(result['run_name'])
        self.assertEqual(other.read_bytes(),b'owner output')
        self.assertTrue((Path(data['destination'])/result['run_name']/'incomplete').exists())
        self.assertNotIn('private fixture failure',json.dumps(result))

    def test_destination_pin_survives_preparation_handoff_before_any_allocation(self):
        data=self.fixture();original=candidate.prepare
        destination=Path(data['destination']);moved=self.parent/'original-output'
        def swapped(*args,**kwargs):
            destination.rename(moved);destination.mkdir()
            return original(*args,**kwargs)
        with patch.object(candidate,'prepare',swapped):result=self.run_copy(data)
        self.assertEqual(result['status'],'refused')
        self.assertEqual(list(destination.iterdir()),[])
        self.assertEqual(list(moved.iterdir()),[])

    def test_source_pin_survives_preparation_handoff_before_allocation(self):
        data=self.fixture();original=candidate.prepare
        moved=self.parent/'original-source'
        def swapped(*args,**kwargs):
            self.source.rename(moved);self.source.mkdir()
            return original(*args,**kwargs)
        with patch.object(candidate,'prepare',swapped):result=self.run_copy(data)
        self.assertEqual(result['status'],'refused')
        self.assertEqual(list(Path(data['destination']).iterdir()),[])
        self.assertTrue((moved/'lib/main.dart').exists())

    def test_changed_pending_marker_is_retained_and_never_published_as_success(self):
        data=self.fixture();original=candidate.fingerprint
        def changed(ready):
            digest=original(ready)
            (ready.parent/copy.PENDING).write_bytes(b'changed marker')
            return digest
        with patch.object(candidate,'fingerprint',changed):result=self.run_copy(data)
        self.assertEqual(result['status'],'refused');self.assertIsNone(result['copy_path'])
        self.assertEqual((Path(data['destination'])/result['run_name']/copy.PENDING).read_bytes(),b'changed marker')

    def test_strict_request_rejects_unknown_duplicate_and_malformed_fields(self):
        data=self.fixture();raw=json.dumps(data,separators=(',',':'))
        cases=[raw.replace('{','{"version":1,',1),raw.replace('{','{"unknown":true,',1),'x'*(copy.REQUEST_LIMIT+1)]
        for field,value in [('version',1.0),('attempt_id','0'*32),('destination','/output/../changed'),('root','//source'),('python',data['root']+'/python'),('manifest_files',True),('selected_files',[])]:
            cases.append(json.dumps({**data,field:value}))
        for value in cases:
            with self.subTest(value=value[:60]),self.assertRaises((ValueError,TypeError)):copy.prepare_copy(value,candidate,observer)
        self.assertEqual(list(Path(data['destination']).iterdir()),[])

    def test_actual_isolated_cli_loads_only_bundled_siblings(self):
        data=self.fixture();bundle=self.parent/'bundle';bundle.mkdir(mode=0o700)
        for name in ['imported_commit_copy.py','imported_commit_source.py','prepare_self_candidate.py']:
            shutil.copyfile(Path(__file__).with_name(name),bundle/name)
        request=bundle/'request.json';request.write_text(json.dumps(data,separators=(',',':')))
        result=subprocess.run([sys.executable,'-I','-S','-B',str(bundle/'imported_commit_copy.py'),str(request)],cwd=bundle,env={},stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=20)
        self.assertEqual(result.returncode,0,result.stderr);self.assertEqual(result.stderr,b'')
        observed=json.loads(result.stdout);self.assertEqual(observed['status'],'prepared')
        self.assertEqual(candidate.fingerprint(Path(observed['copy_path'])),observed['fingerprint'])
        request.write_text('private malformed')
        failed=subprocess.run([sys.executable,'-I','-S','-B',str(bundle/'imported_commit_copy.py'),str(request)],cwd=bundle,env={},stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=5)
        self.assertEqual(failed.returncode,2);self.assertEqual(failed.stdout,b'');self.assertNotIn(b'private malformed',failed.stderr)


if __name__=='__main__':unittest.main()
