# SPDX-License-Identifier: MPL-2.0
# Copyright 2026 Arpit Sinha
import hashlib,json,os,subprocess,sys,unittest
from pathlib import Path
from unittest.mock import patch
import imported_commit_edit_comparison as comparison
import prepare_self_candidate as candidate
from test_imported_commit_edit import EditTests

class ComparisonTests(EditTests):
 def comparison_fixture(self):
  old=self.edit_fixture();receipt=self.apply(old);self.assertEqual(receipt['status'],'prepared');self.proposed=Path(receipt['copy_path'])
  d={'version':1,'scope':'imported-commit-edit-comparison-request','root':old['root'],'python':'/trusted/python','comparison_id':'d'*32,'commit':old['commit'],'tree':old['tree'],
   'original_destination':str(self.ready.parent.parent),'original_run':self.ready.parent.name,'original_copy':str(self.ready),
   'proposed_destination':old['destination'],'proposed_run':receipt['run_name'],'proposed_copy':str(self.proposed),
   **{k:'c'*64 for k in ('copy_history_sha256','copy_request_sha256','copy_receipt_sha256','edit_history_sha256','edit_request_sha256','edit_receipt_sha256')},
   'copy_attempt_id':'a'*32,'edit_attempt_id':old['attempt_id'],'original_fingerprint':old['expected_source_fingerprint'],'proposed_fingerprint':receipt['fingerprint'],
   'manifest_files':old['manifest_files'],'path':old['path'],'mode':old['before_mode'],'before_sha256':old['before_sha256'],'after_sha256':old['after_sha256'],
   'before_byte_length':old['before_byte_length'],'after_byte_length':old['after_byte_length']}
  return d
 def observe(self,d):return comparison.observe(json.dumps(d,separators=(',',':')),candidate)
 def test_actual_complete_comparison_no_process_or_file_mutation(self):
  d=self.comparison_fixture();before={p:p.read_bytes() for root in (self.source,self.ready,self.proposed) for p in root.rglob('*') if p.is_file()}
  with patch('subprocess.run',side_effect=AssertionError('no process')),patch('subprocess.check_output',side_effect=AssertionError('no process')):r=self.observe(d)
  self.assertEqual(r['status'],'matching',r);self.assertTrue(r['selected_matches']);self.assertEqual(r['comparison']['counts'],{'added':0,'modified':1,'removed':0,'executableChanged':0});self.assertEqual(r['original_files'],4);self.assertFalse(r['execution_authorized']);self.assertEqual(before,{p:p.read_bytes() for p in before})
 def test_changed_selected_bytes_and_binary_peer_are_observed_not_matching(self):
  d=self.comparison_fixture();p=self.proposed/d['path'];old=p.read_bytes();p.write_bytes(b'other');r=self.observe(d);self.assertEqual(r['status'],'changed');self.assertFalse(r['selected_matches']);p.write_bytes(old)
  (self.proposed/'peer.bin').write_bytes(b'changed');r=self.observe(d);self.assertEqual(r['status'],'changed');self.assertTrue(r['selected_matches']);self.assertEqual(r['comparison']['counts']['modified'],2)
 def test_changed_original_and_executable_mode(self):
  d=self.comparison_fixture();(self.ready/'peer.bin').write_bytes(b'changed');self.assertEqual(self.observe(d)['status'],'changed');(self.proposed/d['path']).chmod(0o600);r=self.observe(d);self.assertEqual(r['status'],'changed');self.assertEqual(r['comparison']['counts']['executableChanged'],1);self.assertFalse(r['selected_matches'])
 def test_empty_directory_changes_complete_fingerprint_without_file_counts(self):
  d=self.comparison_fixture();(self.proposed/'empty').mkdir();r=self.observe(d);self.assertEqual(r['status'],'changed');self.assertEqual(r['comparison']['counts']['modified'],1)
 def test_all_three_markers_on_both_copies_refuse_without_partial_observations(self):
  d=self.comparison_fixture()
  for root in (self.ready,self.proposed):
   for marker in comparison.MARKERS:
    p=root.parent/marker;p.write_text('pending')
    try:r=self.observe(d);self.assertEqual(r['status'],'refused');self.assertIsNone(r['comparison']);self.assertIsNone(r['original_fingerprint'])
    finally:p.unlink()
 def test_missing_or_symlinked_output_refuses(self):
  d=self.comparison_fixture();p=self.proposed/'peer.bin';p.unlink();p.symlink_to(self.ready/'peer.bin');self.assertEqual(self.observe(d)['status'],'refused');p.unlink();self.proposed.rename(self.proposed.with_name('missing'));self.assertEqual(self.observe(d)['status'],'refused')
 def test_same_bytes_replaced_directory_rejected_by_held_identity(self):
  d=self.comparison_fixture();original=candidate.scan_candidate;changed=False
  def swapped(root,*args,**kwargs):
   nonlocal changed
   value=original(root,*args,**kwargs)
   if root==self.proposed and not changed:
    changed=True;old=root.with_name('displaced');root.rename(old);root.mkdir();__import__('shutil').copytree(old,root,dirs_exist_ok=True)
   return value
  with patch.object(candidate,'scan_candidate',swapped):self.assertEqual(self.observe(d)['status'],'refused')
 def test_changed_tree_during_second_read_never_returns_partial_success(self):
  d=self.comparison_fixture();original=candidate.scan_candidate;calls=0
  def changed(root,*args,**kwargs):
   nonlocal calls
   calls+=1
   if calls==3:(self.ready/'peer.bin').write_bytes(b'changed')
   return original(root,*args,**kwargs)
  with patch.object(candidate,'scan_candidate',changed):r=self.observe(d)
  self.assertEqual(r['status'],'refused');self.assertIsNone(r['comparison'])
 def test_stop_and_deadline_refuse_and_preserve_all_output(self):
  d=self.comparison_fixture();candidate._stop_requested=True;self.assertEqual(self.observe(d)['reason'],'stopped');candidate._stop_requested=False
  with patch.object(candidate,'scan_candidate',side_effect=ValueError('deadline')):self.assertEqual(self.observe(d)['status'],'refused')
  self.assertTrue(self.proposed.exists());self.assertEqual(self.observe(d)['status'],'matching')
 def test_matching_fingerprints_cannot_hide_wrong_selected_metadata(self):
  d=self.comparison_fixture()
  for change in [{'before_sha256':'f'*64},{'after_byte_length':1},{'manifest_files':3},{'mode':'100644'}]:self.assertEqual(self.observe({**d,**change})['status'],'refused')
 def test_strict_request_rejects_unknown_duplicate_types_paths_limits(self):
  d=self.comparison_fixture()
  for change in [{'version':True},{'extra':1},{'python':str(self.ready/'python')},{'comparison_id':'0'*32},{'mode':'120000'},{'path':'lib/../main.dart'},{'original_copy':d['proposed_copy']},{'manifest_files':2049},{'after_byte_length':16385}]:
   with self.assertRaises((ValueError,TypeError)):self.observe({**d,**change})
  with self.assertRaises(ValueError):comparison.request(json.dumps(d).replace('{','{"version":1,',1))
 def test_cli_bundled_read_only_tools(self):
  d=self.comparison_fixture();p=self.parent/'request.json';p.write_text(json.dumps(d,separators=(',',':')))
  r=subprocess.run([sys.executable,'-I','-S','-B',comparison.__file__,str(p)],capture_output=True,text=True);self.assertEqual(r.returncode,0,r.stderr);self.assertEqual(json.loads(r.stdout)['status'],'matching')

if __name__=='__main__':
 names=[n for n in ComparisonTests.__dict__ if n.startswith('test_')];r=unittest.TextTestRunner(verbosity=2).run(unittest.TestSuite(ComparisonTests(n) for n in names));raise SystemExit(not r.wasSuccessful())
