# SPDX-License-Identifier: MPL-2.0
# Copyright 2026 Arpit Sinha
import importlib.util
import json
from pathlib import Path
import tempfile
import time
import types
import unittest
from unittest.mock import patch
import sys
class Tqdm:
    def __init__(self,*a,**kw): pass
    def update(self,n=1): pass
sys.modules.setdefault("tqdm.auto",types.SimpleNamespace(tqdm=Tqdm))

spec = importlib.util.spec_from_file_location('download_model', Path(__file__).with_name('download_model.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

class DownloadTests(unittest.TestCase):
    def hub(self, download):
        info = types.SimpleNamespace(sha='pinned', siblings=[types.SimpleNamespace(rfilename=n, size=s) for n,s in [('model.safetensors',1024),('config.json',2),('bad.py',100),('../escape.json',1)]])
        return types.SimpleNamespace(HfApi=lambda: types.SimpleNamespace(model_info=lambda *a,**kw: info), snapshot_download=download)

    def test_real_partial_files_progress_and_pinned_resume(self):
        with tempfile.TemporaryDirectory() as root:
            destination=Path(root)/'model'
            calls=[]; events=[]
            def first(**kw):
                calls.append(kw)
                kw['tqdm_class'](desc='Reconstructing (incomplete total...)',unit='B',disable=True).update(256)
                kw['tqdm_class'](desc='Downloading bytes',unit='B',disable=True).update(256)
                (destination/'model.safetensors').write_bytes(b'x'*256)
                time.sleep(.04)
                raise OSError('offline')
            with self.assertRaises(OSError):
                module.transfer('owner/model','main',destination,False,self.hub(first),emit=lambda s,**kw:events.append(json.loads(s)),interval=.01)
            self.assertEqual((destination/'model.safetensors').stat().st_size,256)
            self.assertTrue(any(e['bytes']==256 and e['speed']>0 for e in events))
            def finish(**kw):
                calls.append(kw)
                self.assertEqual((destination/'model.safetensors').stat().st_size,256)
                (destination/'model.safetensors').write_bytes(b'x'*1024)
                (destination/'config.json').write_text('{}')
            module.transfer('owner/model','pinned',destination,True,self.hub(finish),emit=lambda s,**kw:events.append(json.loads(s)))
            self.assertEqual(events[-1]['bytes'],1026)
            self.assertEqual(calls[-1]['revision'],'pinned')
            self.assertNotIn('bad.py',calls[-1]['allow_patterns'])
            self.assertNotIn('../escape.json',calls[-1]['allow_patterns'])
            self.assertNotIn(str(destination),json.dumps(events))

    def test_existing_unowned_mismatched_and_linked_destinations_refused(self):
        with tempfile.TemporaryDirectory() as root:
            target=Path(root)/'model'; target.mkdir()
            with self.assertRaises(RuntimeError): module.prepare_destination(target,'a','b',False)
            with self.assertRaises(ValueError): module.prepare_destination(target,'a','b',True)
            (target/module.MARKER).write_text(json.dumps({'version':1,'repository':'a','revision':'b'}))
            with self.assertRaises(ValueError): module.prepare_destination(target,'a','other',True)
            (target/'link').symlink_to(Path(root))
            with self.assertRaises(ValueError): module.prepare_destination(target,'a','b',True)
            self.assertTrue((target/'link').is_symlink())

    def test_cache_counts_only_incomplete_transfer_payload(self):
        with tempfile.TemporaryDirectory() as root:
            target=Path(root); cache=target/'.cache/huggingface/download';cache.mkdir(parents=True)
            (cache/'x.incomplete').write_bytes(b'x'*500)
            (cache/'x.metadata').write_bytes(b'x'*1000)
            self.assertEqual(module.measured_bytes(target,{'model.safetensors':1024}),500)

    def test_actual_helper_process_pause_and_restart_resume(self):
        import subprocess
        import os
        import sys
        with tempfile.TemporaryDirectory() as root:
            root=Path(root)
            (root/'huggingface_hub.py').write_text("""
from pathlib import Path
from types import SimpleNamespace
import time
class HfApi:
 def model_info(self,*a,**kw):
  return SimpleNamespace(sha='pin',siblings=[SimpleNamespace(rfilename='model.safetensors',size=100)])
def snapshot_download(**kw):
 d=Path(kw['local_dir']);f=d/'model.safetensors'
 n=f.stat().st_size if f.exists() else 0
 logical=kw['tqdm_class'](desc='Reconstructing',disable=True)
 network=kw['tqdm_class'](desc='Downloading bytes',disable=True)
 for i in range(n,100):
  with f.open('ab') as out: out.write(b'x')
  logical.update(1);network.update(1);time.sleep(.02)
""")
            tqdm=root/'tqdm';tqdm.mkdir();(tqdm/'__init__.py').write_text('')
            (tqdm/'auto.py').write_text('class tqdm:\n def __init__(self,*a,**kw): pass\n def update(self,n): pass\n')
            target=root/'model'
            args=[sys.executable,str(Path(module.__file__)), '--repository','owner/model','--revision','pin','--destination',str(target)]
            env=dict(os.environ,PYTHONPATH=str(root))
            child=subprocess.Popen(args,env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
            try:
                first=json.loads(child.stdout.readline())
                self.assertEqual(first['bytes'],0)
                progressed=json.loads(child.stdout.readline())
                self.assertGreater(progressed['bytes'],0)
                self.assertGreater(progressed['speed'],0)
                child.terminate();child.wait(timeout=5)
                partial=(target/'model.safetensors').stat().st_size
                self.assertTrue(0<partial<100)
            finally:
                if child.poll() is None: child.kill();child.wait()
                child.stdout.close();child.stderr.close()
            result=subprocess.run(args+['--resume'],env=env,capture_output=True,text=True,timeout=10)
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertEqual((target/'model.safetensors').read_bytes(),b'x'*100)
            events=[json.loads(line) for line in result.stdout.splitlines()]
            self.assertEqual(events[-1]['bytes'],100)
            self.assertNotIn(str(root),result.stdout)

if __name__=='__main__': unittest.main()
