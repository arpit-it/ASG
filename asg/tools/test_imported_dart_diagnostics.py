# SPDX-License-Identifier: MPL-2.0
# Copyright 2026 Arpit Sinha
import hashlib,json,os,shutil,subprocess,sys,tempfile,unittest
from pathlib import Path
from unittest.mock import patch
import imported_dart_diagnostics as diagnostics
import imported_commit_edit_comparison as reader
import prepare_self_candidate as candidate
from test_imported_commit_edit_comparison import ComparisonTests

class SdkReviewTests(ComparisonTests):
 def sdk_fixture(self):
  comparison=self.comparison_fixture();root=self.parent/'sdk';(root/'bin/snapshots').mkdir(parents=True);(root/'lib/core').mkdir(parents=True)
  (root/'bin/dartaotruntime').write_bytes(b'owned synthetic executable');(root/'bin/dartaotruntime').chmod(0o700)
  (root/'bin/snapshots/analysis_server_aot.dart.snapshot').write_bytes(b'owned synthetic snapshot');(root/'version').write_text('3.10.0\n')
  (root/'lib/core/core.dart').write_text('library core;\n');(root/'lib/empty.dart').write_text('')
  return root,comparison
 def test_hash_review_has_no_process_effect_and_binds_library_data(self):
  sdk,c=self.sdk_fixture()
  with patch('subprocess.Popen',side_effect=AssertionError('SDK review cannot launch')) as forbidden:
   value=diagnostics.read_sdk(str(sdk),c,candidate,reader)
   self.assertEqual(value['library_files'],2);self.assertEqual(value['library_bytes'],len(b'library core;\n'));forbidden.assert_not_called()
  self.assertEqual(diagnostics.sdk_labels(json.dumps(value),reader),value)
  (sdk/'lib/core/core.dart').write_text('changed');self.assertNotEqual(diagnostics.read_sdk(str(sdk),c,candidate,reader)['library_manifest_sha256'],value['library_manifest_sha256'])
 def test_private_copy_is_exact_and_preserves_original(self):
  sdk,c=self.sdk_fixture();output=self.parent/'private-sdk';output.mkdir(mode=0o700)
  before={p:p.read_bytes() for p in sdk.rglob('*') if p.is_file()}
  value=diagnostics.read_sdk(str(sdk),c,candidate,reader,copy_to=output)
  copied=diagnostics.read_sdk(str(output),c,candidate,reader)
  self.assertEqual({**value,'root':str(output)},copied);self.assertEqual(before,{p:p.read_bytes() for p in before})
  self.assertTrue((output/'bin/dartaotruntime').stat().st_mode&0o100)
 def test_sdk_links_hardlinks_nonprivate_or_nonempty_copy_refuse(self):
  sdk,c=self.sdk_fixture();p=sdk/'lib/core/core.dart';p.unlink();p.symlink_to(sdk/'version')
  with self.assertRaises((OSError,ValueError)):diagnostics.read_sdk(str(sdk),c,candidate,reader)
  p.unlink();os.link(sdk/'version',p)
  with self.assertRaises(ValueError):diagnostics.read_sdk(str(sdk),c,candidate,reader)
  p.unlink();p.write_text('restored');output=self.parent/'private-sdk';output.mkdir(mode=0o700);(output/'owner').write_text('keep')
  with self.assertRaises(ValueError):diagnostics.read_sdk(str(sdk),c,candidate,reader,copy_to=output)
  self.assertEqual((output/'owner').read_text(),'keep')
 def test_sdk_overlaps_or_changed_library_cannot_be_reviewed(self):
  sdk,c=self.sdk_fixture()
  for value in [c['root'],c['original_destination'],c['proposed_copy'],c['python'],'/alias/../sdk']:
   with self.assertRaises((ValueError,OSError)):diagnostics.read_sdk(value,c,candidate,reader)
  with patch.object(diagnostics,'LIBRARY_BYTES',1):
   with self.assertRaises(ValueError):diagnostics.read_sdk(str(sdk),c,candidate,reader)
 def test_copy_destination_link_cannot_retarget_sdk_writes(self):
  sdk,c=self.sdk_fixture();outside=self.parent/'outside';outside.mkdir();alias=self.parent/'alias';alias.symlink_to(outside,target_is_directory=True)
  with self.assertRaises((ValueError,OSError)):diagnostics.read_sdk(str(sdk),c,candidate,reader,copy_to=alias)
  self.assertEqual(list(outside.iterdir()),[])
 def test_sdk_changed_during_hash_refuses(self):
  sdk,c=self.sdk_fixture();original=diagnostics.os.read;changed=False
  def read(fd,size):
   nonlocal changed
   value=original(fd,size)
   if value==b'library core;\n' and not changed:(sdk/'lib/core/core.dart').write_text('changed');changed=True
   return value
  with patch.object(diagnostics.os,'read',read):
   with self.assertRaises(ValueError):diagnostics.read_sdk(str(sdk),c,candidate,reader)
 def test_strict_sdk_labels_and_cli(self):
  sdk,c=self.sdk_fixture();value=diagnostics.read_sdk(str(sdk),c,candidate,reader)
  for update in [{'extra':True},{'library_manifest_sha256':'bad'},{'library_files':True},{'library_files':2049},{'library_bytes':129*1024*1024},{'version':'latest'}]:
   with self.assertRaises(ValueError):diagnostics.sdk_labels(json.dumps({**value,**update}),reader)
  payload=self.parent/'review.json';payload.write_text(json.dumps({'version':1,'scope':'imported-dart-sdk-review-request','comparison_request':json.dumps(c,separators=(',',':')),'sdk_root':str(sdk)}))
  result=subprocess.run([sys.executable,'-I','-S','-B',diagnostics.__file__,str(payload)],capture_output=True,text=True)
  self.assertEqual(result.returncode,0,result.stderr);self.assertEqual(json.loads(result.stdout),value)

 def diagnostic_fixture(self):
  sdk,c=self.sdk_fixture();tools=diagnostics.read_sdk(str(sdk),c,candidate,reader)
  text=(self.proposed/c['path']).read_bytes().decode('utf-8')
  # Python utf-8 decoding preserves this fixture's literal BOM.
  data={'version':1,'scope':'imported-dart-diagnostics-request','comparison_request':json.dumps(c,separators=(',',':')),
   'comparison_receipt_sha256':'c'*64,'sdk_identity':json.dumps(tools,separators=(',',':')),'replacement':text,'run_id':'d'*32}
  return sdk,c,data
 def run_diagnostics(self,data):return diagnostics.diagnose(json.dumps(data,separators=(',',':'),ensure_ascii=False),candidate,reader,private_parent=self.parent)
 def test_diagnostic_staging_uses_only_exact_bytes_and_fixed_inputs(self):
  sdk,c,d=self.diagnostic_fixture();before={p:p.read_bytes() for root in (sdk,self.ready,self.proposed) for p in root.rglob('*') if p.is_file()}
  def analyze(source,work,copy,text,candidate):
   self.assertNotEqual(copy,sdk);self.assertEqual((source/'lib/main.dart').read_bytes(),d['replacement'].encode())
   self.assertEqual(sorted(str(p.relative_to(source)) for p in source.rglob('*') if p.is_file()),['lib/main.dart','pubspec.yaml'])
   self.assertEqual((copy/'lib/core/core.dart').read_bytes(),(sdk/'lib/core/core.dart').read_bytes());return []
  with patch.object(diagnostics,'analyze',analyze):r=self.run_diagnostics(d)
  self.assertEqual(r['status'],'clean');self.assertFalse(r['project_verified']);self.assertFalse(r['execution_authorized'])
  self.assertEqual(before,{p:p.read_bytes() for p in before});self.assertEqual(list(self.parent.glob('diagnostics-owned-*')),[])
 def test_pending_or_changed_sdk_refuses_before_analyzer(self):
  sdk,c,d=self.diagnostic_fixture();marker=self.proposed.parent/'.asg-imported-edit-pending';marker.write_text('pending')
  with patch.object(diagnostics,'analyze') as launch:
   self.assertEqual(self.run_diagnostics(d)['status'],'unavailable');launch.assert_not_called()
  marker.unlink();tools=json.loads(d['sdk_identity']);tools['library_manifest_sha256']='f'*64;d['sdk_identity']=json.dumps(tools,separators=(',',':'))
  with patch.object(diagnostics,'analyze') as launch:
   self.assertEqual(self.run_diagnostics(d)['reason'],'input_changed');launch.assert_not_called()
  self.assertEqual(list(self.parent.glob('diagnostics-owned-*')),[])
 def test_changed_original_sdk_private_copy_or_proposed_tree_revokes_result(self):
  for target in ('installed','private','proposed'):
   with self.subTest(target=target):
    # Each mutation is restored after its own bounded refusal.
    sdk,c,d=self.diagnostic_fixture() if not hasattr(self,'_mutate_setup') else self._mutate_setup
    self._mutate_setup=(sdk,c,d);file=(sdk/'lib/core/core.dart') if target=='installed' else (self.proposed/'peer.bin')
    old=file.read_bytes()
    def changed(source,work,copy,text,candidate):
     if target=='private':(copy/'lib/core/core.dart').write_text('changed')
     else:file.write_bytes(b'changed')
     return []
    with patch.object(diagnostics,'analyze',changed):r=self.run_diagnostics(d)
    self.assertEqual(r['status'],'unavailable');self.assertEqual(r['reason'],'input_changed');self.assertEqual(r['diagnostics'],[])
    if target!='private':file.write_bytes(old)
    self.assertEqual(list(self.parent.glob('diagnostics-owned-*')),[])
 def test_stop_or_protocol_refusal_has_no_partial_diagnostics(self):
  sdk,c,d=self.diagnostic_fixture();candidate._stop_requested=True
  try:
   with patch.object(diagnostics,'analyze') as launch:self.assertEqual(self.run_diagnostics(d)['status'],'stopped');launch.assert_not_called()
  finally:candidate._stop_requested=False
  for reason in ('protocol','output_limit','deadline','unsupported_sdk'):
   with patch.object(diagnostics,'analyze',side_effect=diagnostics.Refusal(reason)):r=self.run_diagnostics(d)
   self.assertEqual(r['status'],'unavailable');self.assertEqual(r['reason'],reason);self.assertEqual(r['diagnostics'],[]);self.assertIsNone(r['protocol_version'])
 def test_foreign_or_oversized_diagnostic_intent_has_no_dispatch(self):
  sdk,c,d=self.diagnostic_fixture()
  for change in [{'extra':True},{'version':True},{'replacement':'changed'},{'run_id':'0'*32},{'comparison_receipt_sha256':'bad'}]:
   with patch.object(diagnostics,'analyze') as launch:
    with self.assertRaises((ValueError,TypeError)):self.run_diagnostics({**d,**change})
    launch.assert_not_called()
  with self.assertRaises(ValueError):diagnostics.diagnostics_request(' '*(diagnostics.PAYLOAD_LIMIT+1),reader)

if __name__=='__main__':
 names=[n for n in SdkReviewTests.__dict__ if n.startswith('test_')];r=unittest.TextTestRunner(verbosity=2).run(unittest.TestSuite(SdkReviewTests(n) for n in names));raise SystemExit(not r.wasSuccessful())
