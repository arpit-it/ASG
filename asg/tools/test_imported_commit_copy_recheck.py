# SPDX-License-Identifier: MPL-2.0
# Copyright 2026 Arpit Sinha
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import unittest
from unittest.mock import patch
import imported_commit_copy_recheck as recheck
import prepare_self_candidate as candidate
from test_imported_commit_copy import CopyTests

class RecheckTests(CopyTests):
    def fixture_recheck(self):
        data=self.fixture();value=self.run_copy(data);self.assertEqual(value['status'],'prepared')
        self.ready=Path(value['copy_path'])
        return {'version':1,'scope':'imported-commit-copy-recheck-request','root':data['root'],
                'python':data['python'],'destination':data['destination'],'copy_path':value['copy_path'],
                'run_name':value['run_name'],'commit':data['commit'],'tree':data['tree'],
                'expected_fingerprint':value['fingerprint'],'copy_history_sha256':'a'*64,
                'copy_request_sha256':value['request_sha256'],'copy_receipt_sha256':'b'*64,
                'copy_attempt_id':data['attempt_id'],'recheck_id':'c'*32}
    def check(self,data):
        return recheck.observe(json.dumps(data,separators=(',',':')),candidate)
    def test_matching_recheck_is_read_only_and_never_reads_git(self):
        data=self.fixture_recheck();(self.source/'lib/main.dart').write_bytes(b'owner dirty');(self.source/'untracked').write_bytes(b'keep')
        original={p:p.read_bytes() for p in self.source.rglob('*') if p.is_file()}
        with patch.object(candidate,'read_git',side_effect=AssertionError('Git must not run')):
            value=self.check(data)
        self.assertEqual(value['status'],'matching');self.assertEqual(value['observed_fingerprint'],data['expected_fingerprint'])
        self.assertEqual(value['files'],4);self.assertFalse(value['mutation_authorized']);self.assertFalse(value['source_verified'])
        self.assertEqual(original,{p:p.read_bytes() for p in self.source.rglob('*') if p.is_file()})
        self.assertEqual(value['request_sha256'],hashlib.sha256(json.dumps(data,separators=(',',':')).encode()).hexdigest())
    def test_all_bytes_executable_and_empty_directories_affect_observation(self):
        data=self.fixture_recheck()
        for file in ['lib/main.dart','peer.bin']:
            p=self.ready/file;old=p.read_bytes();p.write_bytes(b'changed')
            self.assertEqual(self.check(data)['status'],'changed');p.write_bytes(old)
        p=self.ready/'lib/main.dart';p.chmod(0o600);self.assertEqual(self.check(data)['status'],'changed');p.chmod(0o700)
        (self.ready/'extra').mkdir();self.assertEqual(self.check(data)['status'],'changed')
    def test_both_pending_markers_including_links_refuse(self):
        data=self.fixture_recheck()
        for marker in recheck.MARKERS:
            p=self.ready.parent/marker;p.write_text('pending');self.assertEqual(self.check(data)['status'],'refused');p.unlink()
            p.symlink_to('/missing');self.assertEqual(self.check(data)['status'],'refused');p.unlink()
    def test_linked_files_and_nonprivate_run_refuse(self):
        data=self.fixture_recheck();p=self.ready/'peer.bin';old=p.read_bytes();p.unlink();p.symlink_to(self.source/'peer.bin')
        self.assertEqual(self.check(data)['status'],'refused');p.unlink();os.link(self.source/'peer.bin',p)
        self.assertEqual(self.check(data)['status'],'refused');p.unlink();p.write_bytes(old)
        self.ready.parent.chmod(0o755);self.assertEqual(self.check(data)['status'],'refused')
    def test_replaced_root_or_parent_alias_refuses(self):
        data=self.fixture_recheck();original=candidate.scan_candidate
        def replaced(root,*args,**kwargs):
            result=original(root,*args,**kwargs);root.rename(root.with_name('moved'));root.mkdir();return result
        with patch.object(candidate,'scan_candidate',replaced):self.assertEqual(self.check(data)['status'],'refused')
        alias=self.parent/'alias';alias.symlink_to(data['destination'],target_is_directory=True)
        altered={**data,'destination':str(alias),'copy_path':str(alias/data['run_name']/('source-'+data['commit']))}
        self.assertEqual(self.check(altered)['status'],'refused')
    def test_marker_appearing_after_scan_and_changed_second_scan_refuse(self):
        data=self.fixture_recheck();original=candidate.scan_candidate
        def pending(*args,**kwargs):
            result=original(*args,**kwargs);(self.ready.parent/recheck.MARKERS[1]).write_text('pending');return result
        with patch.object(candidate,'scan_candidate',pending):self.assertEqual(self.check(data)['status'],'refused')
        (self.ready.parent/recheck.MARKERS[1]).unlink()
        def changed(*args,**kwargs):
            result=original(*args,**kwargs);(self.ready/'peer.bin').write_bytes(os.urandom(5));return result
        with patch.object(candidate,'scan_candidate',changed):self.assertEqual(self.check(data)['status'],'refused')
    def test_stop_and_oversized_file_refuse_without_ready_claims(self):
        data=self.fixture_recheck();candidate._stop_requested=True
        self.assertEqual(self.check(data)['reason'],'stopped');candidate._stop_requested=False
        (self.ready/'peer.bin').write_bytes(b'x'*(candidate.MAX_FILE_BYTES+1));value=self.check(data)
        self.assertEqual(value['status'],'refused');self.assertIsNone(value['observed_fingerprint']);self.assertIsNone(value['files'])
    def test_strict_input_and_outside_python_refuse_before_observation(self):
        data=self.fixture_recheck()
        for edit in [{'version':True},{'extra':True},{'python':data['root']+'/python'},{'recheck_id':'0'*32},{'copy_path':'/foreign'},{'expected_fingerprint':'bad'}]:
            with self.assertRaises(ValueError):self.check({**data,**edit})
        raw=json.dumps(data)
        for raw in ['private',raw.replace('{','{"version":1,',1),'x'*(recheck.LIMIT+1)]:
            with self.assertRaises(ValueError):recheck.observe(raw,candidate)
    def test_cli_uses_bundled_reader_and_bounded_request_file(self):
        data=self.fixture_recheck();payload=self.parent/'payload.json';payload.write_text(json.dumps(data,separators=(',',':')))
        result=subprocess.run([sys.executable,'-I','-S','-B',str(Path(recheck.__file__)),str(payload)],capture_output=True,text=True)
        self.assertEqual(result.returncode,0,result.stderr);self.assertEqual(json.loads(result.stdout)['status'],'matching')

if __name__=='__main__':
    names=[n for n in RecheckTests.__dict__ if n.startswith('test_')]
    result=unittest.TextTestRunner().run(unittest.TestSuite(RecheckTests(n) for n in names))
    raise SystemExit(not result.wasSuccessful())
