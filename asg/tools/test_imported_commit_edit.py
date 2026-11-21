# SPDX-License-Identifier: MPL-2.0
# Copyright 2026 Arpit Sinha
import hashlib
import json
import os
from pathlib import Path
import subprocess
import signal
import time
import sys
import unittest
from unittest.mock import patch
import imported_commit_edit as edit
import imported_commit_copy_recheck as reader
import prepare_self_candidate as candidate
from test_imported_commit_copy import CopyTests

class EditTests(CopyTests):
    def edit_fixture(self):
        old=self.fixture();ready=self.run_copy(old);self.assertEqual(ready['status'],'prepared');self.ready=Path(ready['copy_path'])
        destination=self.parent/'proposed';destination.mkdir();selected=old['selected_files'][0];after='\ufeff// proposed café\r\n'
        data={'version':1,'scope':'imported-commit-edit-request','root':old['root'],'python':'/trusted/python','source_copy':str(self.ready),'destination':str(destination),'attempt_id':'b'*32,'commit':old['commit'],'tree':old['tree'],'manifest_sha256':old['manifest_sha256'],'manifest_files':old['manifest_files'],
              **{k:'c'*64 for k in ('copy_history_sha256','copy_request_sha256','copy_receipt_sha256','recheck_request_sha256','recheck_observation_sha256','context_sha256','plan_sha256','proposal_sha256','proposal_history_sha256')},'expected_source_fingerprint':ready['fingerprint'],'path':selected['path'],'before_mode':selected['mode'],'before_git_blob':selected['git_blob'],'before_sha256':selected['sha256'],'before_byte_length':selected['byte_length'],'replacement':after,'after_sha256':hashlib.sha256(after.encode()).hexdigest(),'after_byte_length':len(after.encode())}
        return data
    def apply(self,data):return edit.prepare(json.dumps(data,separators=(',',':'),ensure_ascii=False),candidate,reader)
    def test_actual_separate_copy_replaces_exactly_one_file_preserving_original_bytes_modes_and_refs(self):
        data=self.edit_fixture();before={p:p.read_bytes() for p in self.source.rglob('*') if p.is_file()};source={p.relative_to(self.ready):p.read_bytes() for p in self.ready.rglob('*') if p.is_file()}
        (self.source/'lib/main.dart').write_bytes(b'owner dirty');(self.source/'untracked').write_bytes(b'keep');before={p:p.read_bytes() for p in self.source.rglob('*') if p.is_file()}
        value=self.apply(data);self.assertEqual(value['status'],'prepared',value);output=Path(value['copy_path'])
        self.assertEqual((output/data['path']).read_bytes(),data['replacement'].encode());self.assertEqual((output/'peer.bin').read_bytes(),source[Path('peer.bin')]);self.assertEqual((output/'test/peer.dart').read_bytes(),b'')
        self.assertTrue((output/data['path']).stat().st_mode&stat_exec())
        self.assertEqual(candidate.fingerprint(output),value['fingerprint']);self.assertNotEqual(value['fingerprint'],data['expected_source_fingerprint'])
        self.assertEqual(source,{p.relative_to(self.ready):p.read_bytes() for p in self.ready.rglob('*') if p.is_file()});self.assertEqual(before,{p:p.read_bytes() for p in self.source.rglob('*') if p.is_file()});self.assertFalse((output.parent/edit.PENDING).exists());self.assertFalse(value['execution_authorized'])
    def test_stale_copy_selected_bytes_mode_and_noop_refuse_before_allocation(self):
        data=self.edit_fixture()
        for change in [{'expected_source_fingerprint':'f'*64},{'before_sha256':'f'*64},{'before_mode':'100644'},{'before_git_blob':'f'*40}]:self.assertEqual(self.apply({**data,**change})['reason'],'input_changed')
        before=(self.ready/data['path']).read_bytes();same={**data,'replacement':before.decode(),'after_sha256':hashlib.sha256(before).hexdigest(),'after_byte_length':len(before)}
        self.assertEqual(self.apply(same)['status'],'refused');self.assertEqual(list(Path(data['destination']).iterdir()),[])
    def test_both_original_pending_markers_refuse_before_allocation(self):
        data=self.edit_fixture()
        for name in reader.MARKERS:
            p=self.ready.parent/name;p.write_text('pending');self.assertEqual(self.apply(data)['status'],'refused');p.unlink()
        self.assertEqual(list(Path(data['destination']).iterdir()),[])
    def test_destinations_inside_source_copy_git_storage_bundle_or_alias_refuse(self):
        data=self.edit_fixture()
        for target in [self.source,self.source/'.git/objects',self.ready,self.ready.parent,self.parent/'Stable.app']:
            if not target.exists():target.mkdir()
            try:value=self.apply({**data,'destination':str(target)});self.assertEqual(value['status'],'refused')
            except ValueError:pass
            self.assertFalse(list(target.glob('asg-self-candidate-*')))
        alias=self.parent/'alias';alias.symlink_to(data['destination'],target_is_directory=True);self.assertEqual(self.apply({**data,'destination':str(alias)})['status'],'refused')
    def test_stop_and_failed_stage_retain_pending_run_never_ready_path(self):
        data=self.edit_fixture();candidate._stop_requested=True;self.assertEqual(self.apply(data)['reason'],'stopped');candidate._stop_requested=False
        with patch.object(candidate,'write_blob',side_effect=ValueError('synthetic stage failure')):value=self.apply(data)
        self.assertEqual(value['status'],'refused');self.assertIsNotNone(value['run_name']);self.assertIsNone(value['copy_path']);self.assertTrue((Path(data['destination'])/value['run_name']/edit.PENDING).exists())
    def test_replaced_input_during_stage_preserves_original_and_pending_output(self):
        data=self.edit_fixture();old=candidate.write_blob;changed=False
        def replacing(*args):
            nonlocal changed
            old(*args)
            if not changed:(self.ready/'peer.bin').write_bytes(b'changed');changed=True
        with patch.object(candidate,'write_blob',replacing):value=self.apply(data)
        self.assertEqual(value['status'],'refused');self.assertIsNotNone(value['run_name']);self.assertTrue((Path(data['destination'])/value['run_name']/edit.PENDING).exists())
    def test_bom_and_legal_header_policy_matches_literal_bytes(self):
        h='// SPDX-License-Identifier: MPL-2.0\r\n// Copyright Example\r\n'
        self.assertTrue(edit.preserves_format('\ufeff'+h+'old','\ufeff'+h+'new'));self.assertFalse(edit.preserves_format('\ufeff'+h+'old',h+'new'));self.assertFalse(edit.preserves_format(h+'old','new'));self.assertTrue(edit.preserves_format('/* Copyright Example */\nold','/* Copyright Example */\nnew'));self.assertFalse(edit.preserves_format('code\n// Copyright late','new'))
        data=self.edit_fixture();text='\ufeff// Copyright Example\r\nold';p=self.ready/data['path'];p.write_bytes(text.encode());blob=p.read_bytes();data.update(expected_source_fingerprint=candidate.fingerprint(self.ready),before_sha256=hashlib.sha256(blob).hexdigest(),before_git_blob=hashlib.sha1(b'blob '+str(len(blob)).encode()+b'\0'+blob).hexdigest(),before_byte_length=len(blob))
        self.assertEqual(self.apply(data)['status'],'refused');self.assertEqual(list(Path(data['destination']).iterdir()),[])
    def test_strict_request_rejects_identity_hash_size_and_replacement_types(self):
        data=self.edit_fixture()
        for change in [{'version':True},{'extra':True},{'attempt_id':'0'*32},{'path':'asg/lib/main.dart'},{'after_sha256':'f'*64},{'replacement':None},{'manifest_files':2049}]:
            with self.assertRaises((ValueError,TypeError)):self.apply({**data,**change})
        with self.assertRaises(ValueError):edit.prepare(json.dumps(data).replace('{','{"version":1,',1),candidate,reader)
    def test_changed_ready_after_publication_retains_edit_pending_marker(self):
        data=self.edit_fixture();original=candidate.publish_verified_snapshot
        def changed(ready,*args,**kwargs):
            digest=original(ready,*args,**kwargs);(ready/'peer.bin').write_bytes(b'changed after publish');return digest
        with patch.object(candidate,'publish_verified_snapshot',changed):value=self.apply(data)
        self.assertEqual(value['status'],'refused');self.assertIsNotNone(value['run_name'])
        self.assertTrue((Path(data['destination'])/value['run_name']/edit.PENDING).exists())

    def test_real_sigterm_during_staging_retains_owned_pending_run(self):
        data=self.edit_fixture();payload=self.parent/'stopped-input.json';payload.write_text(json.dumps(data,separators=(',',':')))
        entered=self.parent/'entered';wrapper=self.parent/'trusted-stop-fixture.py'
        wrapper.write_text("import sys,signal,time,json\nfrom pathlib import Path\nsys.path.insert(0,sys.argv[1])\nimport imported_commit_edit as edit\ncandidate=edit.bundled('prepare_self_candidate');reader=edit.bundled('imported_commit_copy_recheck')\nsignal.signal(signal.SIGTERM,candidate.request_stop)\noriginal=candidate.write_blob\ndef pause(*args):\n original(*args)\n Path(sys.argv[3]).write_text('entered')\n while not candidate._stop_requested: time.sleep(.005)\n candidate.check_stop()\ncandidate.write_blob=pause\nprint(json.dumps(edit.prepare(Path(sys.argv[2]).read_text(),candidate,reader)))\n")
        process=subprocess.Popen([sys.executable,'-I','-S','-B',str(wrapper),str(Path(edit.__file__).parent),str(payload),str(entered)],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        try:
            deadline=time.monotonic()+10
            while not entered.exists() and process.poll() is None and time.monotonic()<deadline:time.sleep(.005)
            self.assertTrue(entered.exists());process.send_signal(signal.SIGTERM);out,err=process.communicate(timeout=5)
            self.assertEqual(err,'');value=json.loads(out);self.assertEqual(value['status'],'refused');self.assertEqual(value['reason'],'stopped');self.assertIsNotNone(value['run_name']);self.assertIsNone(value['copy_path'])
            self.assertTrue((Path(data['destination'])/value['run_name']/edit.PENDING).exists())
        finally:
            if process.poll() is None:process.kill();process.communicate(timeout=5)

    def test_cli_uses_only_private_bundled_tools(self):
        data=self.edit_fixture();payload=self.parent/'payload.json';payload.write_text(json.dumps(data,separators=(',',':')))
        result=subprocess.run([sys.executable,'-I','-S','-B',str(Path(edit.__file__)),str(payload)],capture_output=True,text=True);self.assertEqual(result.returncode,0,result.stderr);self.assertEqual(json.loads(result.stdout)['status'],'prepared')

def stat_exec():return 0o100
if __name__=='__main__':
    names=[n for n in EditTests.__dict__ if n.startswith('test_')];result=unittest.TextTestRunner().run(unittest.TestSuite(EditTests(n) for n in names));raise SystemExit(not result.wasSuccessful())
