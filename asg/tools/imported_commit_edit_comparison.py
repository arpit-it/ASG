# SPDX-License-Identifier: MPL-2.0
# Copyright 2026 Arpit Sinha
"""Bounded complete-copy comparison; no Git, mutation or repository execution."""
import datetime
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import posixpath
import re
import signal
import stat
import sys
import time

LIMIT=32*1024
STRINGS=('scope','root','python','comparison_id','commit','tree',
 'original_destination','original_run','original_copy','proposed_destination',
 'proposed_run','proposed_copy','copy_history_sha256','copy_request_sha256',
 'copy_receipt_sha256','copy_attempt_id','edit_history_sha256','edit_request_sha256',
 'edit_receipt_sha256','edit_attempt_id','original_fingerprint','proposed_fingerprint',
 'path','mode','before_sha256','after_sha256')
INTEGERS=('version','manifest_files','before_byte_length','after_byte_length')
MARKERS=('.asg-preparation-pending','.asg-imported-copy-pending','.asg-imported-edit-pending')


def unique(pairs):
 result={}
 for key,value in pairs:
  if key in result:raise ValueError('Duplicate request member.')
  result[key]=value
 return result


def valid_path(value):
 return (isinstance(value,str) and value.startswith('/') and value!='/' and not value.startswith('//')
  and posixpath.normpath(value)==value and len(value.encode())<=4096
  and not any(ord(c)<32 or 127<=ord(c)<=159 for c in value)
  and not any(p.lower().endswith('.app') for p in value.split('/')))


def inside(root,value):
 root,value=root.casefold(),value.casefold()
 return value==root or value.startswith(root+'/')


def request(raw):
 if not isinstance(raw,str) or len(raw.encode())>LIMIT:raise ValueError('Invalid comparison request.')
 d=json.loads(raw,object_pairs_hook=unique)
 if (not isinstance(d,dict) or set(d)!=set(STRINGS+INTEGERS)
  or any(not isinstance(d[k],str) for k in STRINGS) or any(type(d[k]) is not int for k in INTEGERS)
  or d['version']!=1 or d['scope']!='imported-commit-edit-comparison-request'):raise ValueError('Invalid comparison request.')
 def hexadecimal(k,n,nonzero=False):return re.fullmatch(r'[a-f0-9]{'+str(n)+'}',d[k],re.ASCII) is not None and (not nonzero or d[k]!='0'*n)
 if (any(not hexadecimal(k,40,True) for k in ('commit','tree'))
  or any(not hexadecimal(k,32,True) for k in ('comparison_id','copy_attempt_id','edit_attempt_id'))
  or any(not hexadecimal(k,64) for k in ('copy_history_sha256','copy_request_sha256','copy_receipt_sha256',
    'edit_history_sha256','edit_request_sha256','edit_receipt_sha256','original_fingerprint','proposed_fingerprint','before_sha256','after_sha256'))
  or d['before_sha256']==d['after_sha256'] or d['original_fingerprint']==d['proposed_fingerprint']
  or re.fullmatch(r'(lib|test)/[A-Za-z0-9_.\-/]+\.dart',d['path'],re.ASCII) is None
  or any(p in ('','.','..') for p in d['path'].split('/')) or d['mode'] not in ('100644','100755')
  or not 1<=d['manifest_files']<=2048 or not 0<=d['before_byte_length']<=32768 or not 1<=d['after_byte_length']<=16384
  or any(not valid_path(d[k]) for k in ('root','python','original_destination','original_copy','proposed_destination','proposed_copy'))):raise ValueError('Invalid comparison request.')
 for prefix in ('original','proposed'):
  if (re.fullmatch(r'asg-self-candidate-[a-f0-9]{8}',d[prefix+'_run'],re.ASCII) is None
   or d[prefix+'_copy']!=d[prefix+'_destination']+'/'+d[prefix+'_run']+'/source-'+d['commit']
   or inside(d['root'],d[prefix+'_destination']) or inside(d[prefix+'_destination'],d['python'])):raise ValueError('Invalid comparison request.')
 if (inside(d['root'],d['python']) or d['original_copy']==d['proposed_copy']
  or inside(posixpath.dirname(d['original_copy']),d['proposed_destination'])):raise ValueError('Invalid comparison request.')
 return d


def timestamp():
 now=datetime.datetime.now(datetime.timezone.utc);fraction=f'{now.microsecond:06d}'
 if fraction.endswith('000'):fraction=fraction[:3]
 return now.strftime('%Y-%m-%dT%H:%M:%S.')+fraction+'Z'


def observe(raw,candidate):
 d=request(raw);descriptors=[];reason='unavailable';observations=None;comparison=None;selected=None
 try:
  candidate.check_stop();deadline=time.monotonic()+30;directories=[];runs=[]
  for prefix in ('original','proposed'):
   parent=Path(d[prefix+'_destination']);run=parent/d[prefix+'_run'];root=Path(d[prefix+'_copy'])
   for directory in (parent,run,root):
    fd=candidate.open_directory_no_links(directory);descriptors.append(fd);directories.append(directory)
    candidate.require_directory_identity(directory,fd)
   runs.append(descriptors[-2])
   if os.fstat(runs[-1]).st_mode&0o077:raise ValueError('Run is not private.')
  def current():
   candidate.check_preparation_deadline(deadline)
   for directory,fd in zip(directories,descriptors):candidate.require_directory_identity(directory,fd)
   for run in runs:
    for marker in MARKERS:
     try:os.stat(marker,dir_fd=run,follow_symlinks=False)
     except FileNotFoundError:pass
     else:raise ValueError('Incomplete copy.')
  current();scans=[]
  for prefix in ('original','proposed'):
   total=0;capture={d['path']:None}
   def count(name,content,mode):
    nonlocal total
    if content is not None:total+=len(content)
   fingerprint,index=candidate.scan_candidate(Path(d[prefix+'_copy']),capture=capture,sink=count,deadline=deadline)
   current();scans.append((fingerprint,index,total,capture[d['path']]))
  for prefix,scan in zip(('original','proposed'),scans):
   again,_=candidate.scan_candidate(Path(d[prefix+'_copy']),deadline=deadline);current()
   if again!=scan[0]:raise ValueError('Copy changed during comparison.')
  before,after=scans;selected=True
  for side,scan in zip(('before','after'),scans):
   blob=scan[3];entry=scan[1].get(d['path'])
   selected=selected and blob is not None and entry is not None and entry[0]==d['mode'] and len(blob)==d[side+'_byte_length'] and hashlib.sha256(blob).hexdigest()==d[side+'_sha256']
  comparison=candidate.comparison_result(d['commit'],after[0],before[1],after[1]);current()
  both=before[0]==d['original_fingerprint'] and after[0]==d['proposed_fingerprint']
  if both and (not selected or len(before[1])!=d['manifest_files'] or len(after[1])!=d['manifest_files']
    or comparison['counts']!={'added':0,'modified':1,'removed':0,'executableChanged':0}
    or comparison['changes']!=[{'path':d['path'],'kind':'modified','executableChanged':False}] or comparison['truncated']):raise ValueError('Matching identity mismatch.')
  observations=(before,after);reason=None
 except (OSError,ValueError,KeyboardInterrupt):reason='stopped' if candidate._stop_requested else 'unavailable'
 finally:
  for fd in descriptors:os.close(fd)
 if reason:observations=comparison=selected=None
 before,after=observations if observations else (None,None)
 return {'version':1,'scope':'imported-commit-edit-comparison','request_sha256':hashlib.sha256(raw.encode()).hexdigest(),
  'comparison_id':d['comparison_id'],'original_copy':d['original_copy'],'proposed_copy':d['proposed_copy'],
  'expected_original_fingerprint':d['original_fingerprint'],'expected_proposed_fingerprint':d['proposed_fingerprint'],
  'status':'refused' if reason else 'matching' if both else 'changed',
  'original_fingerprint':before[0] if before else None,'proposed_fingerprint':after[0] if after else None,
  'original_files':len(before[1]) if before else None,'proposed_files':len(after[1]) if after else None,
  'original_bytes':before[2] if before else None,'proposed_bytes':after[2] if after else None,
  'selected_matches':selected,'comparison':comparison,'reason':reason,
  'source_verified':False,'mutation_authorized':False,'execution_authorized':False,'recorded_at':timestamp()}


def main(argv):
 try:
  if len(argv)!=1:raise ValueError()
  fd=os.open(argv[0],os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK)
  try:
   info=os.fstat(fd)
   if not stat.S_ISREG(info.st_mode) or info.st_nlink!=1 or info.st_size>LIMIT:raise ValueError()
   raw=os.read(fd,LIMIT+1).decode()
   if len(raw.encode())!=info.st_size:raise ValueError()
  finally:os.close(fd)
  helper=Path(__file__).with_name('prepare_self_candidate.py');spec=importlib.util.spec_from_file_location('prepare_self_candidate',helper)
  module=importlib.util.module_from_spec(spec);sys.modules[spec.name]=module;spec.loader.exec_module(module)
  signal.signal(signal.SIGTERM,module.request_stop);value=observe(raw,module);print(json.dumps(value,separators=(',',':')))
  return 2 if value['status']=='refused' else 0
 except (OSError,ValueError,TypeError,UnicodeError,RecursionError):
  print('Proposed-copy comparison unavailable.',file=sys.stderr);return 2


if __name__=='__main__':raise SystemExit(main(sys.argv[1:]))
