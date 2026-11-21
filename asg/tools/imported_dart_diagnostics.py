# SPDX-License-Identifier: MPL-2.0
# Copyright 2026 Arpit Sinha
"""Fixed isolated-file diagnostics. Never Flutter CLI or repository commands."""
import hashlib
import importlib.util
import json
import os
import queue
import resource
import secrets
import shutil
import signal
import subprocess
import tempfile
import threading
from pathlib import Path
import re
import stat
import sys
import time

PAYLOAD_LIMIT=64*1024
LIBRARY_FILES=2048
LIBRARY_BYTES=128*1024*1024
FILE_BYTES=32*1024*1024
SDK_KEYS=('root','version','runtime_sha256','analyzer_sha256','library_manifest_sha256','library_files','library_bytes')


def bundled(name):
 p=Path(__file__).with_name(name+'.py');s=importlib.util.spec_from_file_location(name,p)
 m=importlib.util.module_from_spec(s);sys.modules[name]=m;s.loader.exec_module(m);return m


def unique(pairs):
 d={}
 for k,v in pairs:
  if k in d:raise ValueError('Duplicate member.')
  d[k]=v
 return d


def sdk_labels(raw,reader):
 if not isinstance(raw,str) or len(raw.encode())>8192:raise ValueError('Invalid SDK identity.')
 d=json.loads(raw,object_pairs_hook=unique)
 if (not isinstance(d,dict) or set(d)!=set(SDK_KEYS)
  or any(not isinstance(d[k],str) for k in SDK_KEYS[:5])
  or any(type(d[k]) is not int for k in SDK_KEYS[5:])
  or not reader.valid_path(d['root']) or len(d['version'])>128
  or re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+(?:[-+][A-Za-z0-9.\-]+)?',d['version'],re.ASCII) is None
  or any(re.fullmatch(r'[a-f0-9]{64}',d[k],re.ASCII) is None for k in SDK_KEYS[2:5])
  or not 1<=d['library_files']<=LIBRARY_FILES or not 0<=d['library_bytes']<=LIBRARY_BYTES):raise ValueError('Invalid SDK identity.')
 return d


def protected_sdk(root,comparison,reader):
 if not reader.valid_path(root):raise ValueError('Invalid SDK path.')
 for protected in (comparison['root'],comparison['original_destination'],comparison['proposed_destination'],comparison['python']):
  if reader.inside(root,protected) or reader.inside(protected,root):raise ValueError('SDK overlaps protected inputs.')


def file_identity(info):
 return (info.st_dev,info.st_ino,info.st_mode,info.st_nlink,info.st_size,info.st_mtime_ns,info.st_ctime_ns)


def read_sdk(root,comparison,candidate,reader,*,copy_to=None):
 """Hash bounded no-link installed inputs, optionally copy exact reviewed bytes.

 The analyzer later executes only private verified copies. SDK libraries are
 readonly parser inputs too; executable/snapshot hashes alone are insufficient.
 """
 protected_sdk(root,comparison,reader);root=Path(root);fds=[];deadline=time.monotonic()+30
 def current():
  candidate.check_preparation_deadline(deadline)
  for directory,fd in fds:candidate.require_directory_identity(directory,fd)
 def directory(p):
  fd=candidate.open_directory_no_links(p);fds.append((p,fd));current();return fd
 try:
  root_fd=directory(root);bin_fd=directory(root/'bin');snap_fd=directory(root/'bin/snapshots');lib_fd=directory(root/'lib')
  copy_fd=None
  if copy_to is not None:
   if reader.inside(str(root),str(copy_to)) or reader.inside(str(copy_to),str(root)):raise ValueError('SDK copy overlaps input.')
   copy_fd=directory(copy_to)
   if os.fstat(copy_fd).st_mode&0o077 or any(os.scandir(copy_fd)):raise ValueError('Private SDK destination changed.')
  def output_directory(relative):
   parent=os.dup(copy_fd)
   try:
    for part in relative.split('/'):
     if not part:continue
     try:os.mkdir(part,0o700,dir_fd=parent)
     except FileExistsError:pass
     child=os.open(part,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW,dir_fd=parent);os.close(parent);parent=child
    return parent
   except BaseException:os.close(parent);raise
  if copy_fd is not None:
   for name in ('bin/snapshots','lib'):os.close(output_directory(name))
  def regular(parent,name,limit,target=None,*,executable=False,capture=False):
   current();fd=os.open(name,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK,dir_fd=parent);output=None
   try:
    before=os.fstat(fd)
    if not stat.S_ISREG(before.st_mode) or before.st_nlink!=1 or not 0<=before.st_size<=limit:raise ValueError('Invalid SDK input.')
    if executable and (before.st_size==0 or not before.st_mode&0o111):raise ValueError('SDK runtime is not executable.')
    if target is not None:
     parent=output_directory(target.rsplit('/',1)[0] if '/' in target else '')
     try:output=os.open(target.rsplit('/',1)[-1],os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o700 if executable else 0o600,dir_fd=parent)
     finally:os.close(parent)
    digest=hashlib.sha256();total=0;captured=bytearray()
    while True:
     current();part=os.read(fd,65536)
     if not part:break
     total+=len(part)
     if total>limit:raise ValueError('SDK input grew.')
     digest.update(part)
     if capture:captured.extend(part)
     if output is not None:
      view=memoryview(part)
      while view:
       count=os.write(output,view)
       if count<=0:raise ValueError('Private SDK copy failed.')
       view=view[count:]
    if total!=before.st_size or file_identity(before)!=file_identity(os.fstat(fd)):raise ValueError('SDK input changed.')
    if output is not None:os.fsync(output)
    return digest.hexdigest(),total,bytes(captured)
   finally:
    os.close(fd)
    if output is not None:os.close(output)
  runtime,_,_=regular(bin_fd,'dartaotruntime',FILE_BYTES,'bin/dartaotruntime' if copy_to else None,executable=True)
  analyzer,_,_=regular(snap_fd,'analysis_server_aot.dart.snapshot',FILE_BYTES,'bin/snapshots/analysis_server_aot.dart.snapshot' if copy_to else None)
  _,_,version=regular(root_fd,'version',256,'version' if copy_to else None,capture=True)
  version=version.decode('ascii').strip()
  if re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+(?:[-+][A-Za-z0-9.\-]+)?',version,re.ASCII) is None:raise ValueError('Invalid SDK version.')
  manifest=hashlib.sha256(b'ASG Dart SDK libraries v1\0');files=total=entries=0
  def visit(parent,prefix,depth):
   nonlocal files,total,entries
   current();before=os.fstat(parent)
   names=sorted(entry.name for entry in os.scandir(parent));seen=set()
   for name in names:
    current();entries+=1
    if entries>4096 or depth>=16 or re.fullmatch(r'[A-Za-z0-9_. @+()\-]{1,128}',name,re.ASCII) is None or name in ('.','..') or name.casefold() in seen:raise ValueError('Unsupported SDK library path.')
    seen.add(name.casefold());relative=prefix+name
    info=os.stat(name,dir_fd=parent,follow_symlinks=False)
    if stat.S_ISDIR(info.st_mode):
     child=os.open(name,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW,dir_fd=parent)
     try:
      if (info.st_dev,info.st_ino)!=(os.fstat(child).st_dev,os.fstat(child).st_ino):raise ValueError('SDK library directory changed.')
      manifest.update(b'D'+relative.encode('ascii')+b'\0')
      if copy_to:os.close(output_directory('lib/'+relative))
      visit(child,relative+'/',depth+1)
      now=os.stat(name,dir_fd=parent,follow_symlinks=False)
      if (now.st_dev,now.st_ino)!=(info.st_dev,info.st_ino):raise ValueError('SDK library directory replaced.')
     finally:os.close(child)
    elif stat.S_ISREG(info.st_mode):
     digest,size,_=regular(parent,name,FILE_BYTES,'lib/'+relative if copy_to else None)
     files+=1;total+=size
     if files>LIBRARY_FILES or total>LIBRARY_BYTES:raise ValueError('SDK libraries exceed limits.')
     manifest.update(b'F'+relative.encode('ascii')+b'\0'+bytes.fromhex(digest))
    else:raise ValueError('Linked or special SDK library.')
   after=os.fstat(parent)
   if (before.st_mtime_ns,before.st_ctime_ns)!=(after.st_mtime_ns,after.st_ctime_ns):raise ValueError('SDK libraries changed.')
  visit(lib_fd,'',0);current()
  if files<1:raise ValueError('SDK libraries unavailable.')
  return {'root':str(root),'version':version,'runtime_sha256':runtime,'analyzer_sha256':analyzer,'library_manifest_sha256':manifest.hexdigest(),'library_files':files,'library_bytes':total}
 finally:
  for _,fd in reversed(fds):os.close(fd)


# Fixed trusted analyzer only; no caller command or repository-config interface.
def analyzer_profile(sdk,source,work):
 reads=[sdk,source,work,'/System','/usr','/bin','/sbin','/Library','/private/etc','/private/var/db','/private/preboot','/dev']
 subpaths=' '.join('(subpath '+json.dumps(str(p))+')' for p in reads)
 return '\n'.join(['(version 1)','(deny default)','(allow process-exec sysctl-read)',
  '(deny syscall-unix (syscall-number SYS_setsid SYS_setpgid SYS_posix_spawn))',
  '(allow signal (target same-sandbox))',
  '(allow mach-lookup (global-name "com.apple.cfprefsd.daemon") (global-name "com.apple.system.logger") (global-name "com.apple.logd") (global-name "com.apple.trustd"))',
  '(allow file-read-metadata)','(allow file-read-data (literal "/"))',
  '(allow file-read* '+subpaths+')','(allow file-write* (subpath '+json.dumps(str(work))+') (literal "/dev/null"))'])+'\n'


def analyzer_limits():
 os.umask(0o077);resource.setrlimit(resource.RLIMIT_CORE,(0,0));resource.setrlimit(resource.RLIMIT_CPU,(20,20))
 resource.setrlimit(resource.RLIMIT_FSIZE,(32*1024*1024,32*1024*1024));resource.setrlimit(resource.RLIMIT_NOFILE,(128,128))


class Refusal(Exception):pass


def analyze(source,work,sdk,text,candidate):
 policy=work/'policy.sb';policy.write_text(analyzer_profile(sdk,source,work));policy.chmod(0o600)
 package=work/'package_config.json';package.write_text(json.dumps({'configVersion':2,'packages':[{'name':'isolated_fixture','rootUri':source.as_uri()+'/','packageUri':'lib/','languageVersion':'3.0'}]}))
 target=source/'lib/main.dart';events=queue.Queue(maxsize=256);overflow=threading.Event();invalid=threading.Event();lock=threading.Lock()
 sizes={'stdout':0,'stderr':0};process=None;threads=[];started=time.monotonic();responses={};notifications=0;findings=None;failure=None;shutdown=False
 def check():
  if candidate._stop_requested:raise Refusal('stopped')
  if overflow.is_set():raise Refusal('output_limit')
  if invalid.is_set():raise Refusal('protocol')
  if time.monotonic()-started>=15:raise Refusal('deadline')
 def read(stream,key):
  pending=bytearray()
  try:
   while True:
    part=stream.read1(4096)
    if not part:break
    if overflow.is_set() or invalid.is_set():continue
    with lock:
     remaining=65536-sum(sizes.values());sizes[key]+=min(len(part),max(0,remaining))
     if len(part)>remaining:overflow.set();continue
    if key=='stdout':
     pending.extend(part)
     if len(pending)>32768:invalid.set();pending.clear();continue
     while b'\n' in pending:
      line,_,rest=pending.partition(b'\n');pending=bytearray(rest)
      if line:
       try:events.put_nowait(json.loads(line.decode('utf-8'),object_pairs_hook=unique))
       except (ValueError,UnicodeError,queue.Full):invalid.set();pending.clear();break
   if pending.strip():invalid.set()
  finally:stream.close()
 def send(identifier,method,params=None):
  check();value={'id':identifier,'method':method}
  if params is not None:value['params']=params
  process.stdin.write((json.dumps(value,separators=(',',':'))+'\n').encode());process.stdin.flush()
 def receive(identifier):
  nonlocal notifications
  while identifier not in responses:
   check()
   try:value=events.get(timeout=.02)
   except queue.Empty:
    if process.poll() is not None:raise Refusal('protocol')
    continue
   if not isinstance(value,dict):raise Refusal('protocol')
   if 'id' in value:
    if not isinstance(value['id'],str) or value['id'] not in ('1','2','3','4') or value['id'] in responses:raise Refusal('protocol')
    responses[value['id']]=value
   elif 'event' in value:
    notifications+=1
    if notifications>128 or value['event']=='server.error':raise Refusal('protocol')
   else:raise Refusal('protocol')
  value=responses[identifier]
  if 'error' in value:raise Refusal('protocol')
  return value.get('result',{})
 try:
  check();argv=[str(sdk/'bin/dartaotruntime'),str(sdk/'bin/snapshots/analysis_server_aot.dart.snapshot'),
   '--protocol=analyzer','--client-id=asg-isolated-file-diagnostics','--dart-sdk='+str(sdk),'--cache='+str(work/'cache'),'--packages='+str(package)]
  # Inherit the native host's owned group. The restricted child cannot escape it.
  process=subprocess.Popen(['/usr/bin/sandbox-exec','-f',str(policy),*argv],cwd=work,
   env={'PATH':'/usr/bin:/bin','LANG':'en_US.UTF-8'},stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,
   start_new_session=False,preexec_fn=analyzer_limits,close_fds=True)
  for key,stream in [('stdout',process.stdout),('stderr',process.stderr)]:
   t=threading.Thread(target=read,args=(stream,key),daemon=True);t.start();threads.append(t)
  send('1','server.getVersion')
  if receive('1').get('version')!='1.40.1':raise Refusal('unsupported_sdk')
  send('2','analysis.setAnalysisRoots',{'included':[str(source)],'excluded':[]});receive('2')
  send('3','analysis.getErrors',{'file':str(target)});errors=receive('3').get('errors')
  if not isinstance(errors,list) or len(errors)>100:raise Refusal('output_limit')
  findings=[];units=len(text.encode('utf-16-le'))//2
  for error in errors:
   if not isinstance(error,dict) or not isinstance(error.get('location'),dict):raise Refusal('protocol')
   location=error['location']
   if location.get('file')!=str(target):raise Refusal('protocol')
   finding={k:error.get(k) for k in ('severity','type','code','message')}
   finding.update(offset=location.get('offset'),length=location.get('length'),line=location.get('startLine'),column=location.get('startColumn'))
   if (any(not isinstance(finding[k],str) for k in ('severity','type','code','message'))
    or finding['severity'] not in ('ERROR','WARNING','INFO')
    or re.fullmatch(r'[A-Z_]{1,80}',finding['type'],re.ASCII) is None
    or re.fullmatch(r'[a-z0-9_]{1,120}',finding['code'],re.ASCII) is None
    or not 1<=len(finding['message'])<=2048 or '\0' in finding['message']
    or any(type(finding[k]) is not int for k in ('offset','length','line','column'))
    or finding['offset']<0 or finding['length']<0 or finding['offset']+finding['length']>units
    or not 1<=finding['line']<=units+1 or not 1<=finding['column']<=units+1):raise Refusal('protocol')
   findings.append(finding)
  send('4','server.shutdown');receive('4');process.stdin.close();process.wait(timeout=2);check()
  if process.returncode!=0:raise Refusal('protocol')
  shutdown=True
 except Refusal as e:failure=str(e);findings=None
 except (OSError,ValueError,TypeError,UnicodeError,subprocess.TimeoutExpired):failure='protocol';findings=None
 finally:
  if process is not None:
   if process.poll() is None:process.terminate()
   try:process.wait(timeout=.5)
   except subprocess.TimeoutExpired:process.kill();process.wait(timeout=2)
   if not process.stdin.closed:process.stdin.close()
  for t in threads:t.join(timeout=2)
  if any(t.is_alive() for t in threads):failure='cleanup';findings=None
  if overflow.is_set():failure='output_limit';findings=None
  elif invalid.is_set() or sizes['stderr']:failure='protocol';findings=None
  if candidate._stop_requested:failure='stopped';findings=None
 if failure:raise Refusal(failure)
 if not shutdown or findings is None:raise Refusal('protocol')
 return findings


def diagnostics_request(raw,reader):
 if not isinstance(raw,str) or len(raw.encode('utf-8'))>PAYLOAD_LIMIT:raise ValueError('Invalid diagnostics request.')
 d=json.loads(raw,object_pairs_hook=unique)
 keys={'version','scope','comparison_request','comparison_receipt_sha256','sdk_identity','replacement','run_id'}
 if (not isinstance(d,dict) or set(d)!=keys or type(d['version']) is not int or d['version']!=1
  or d['scope']!='imported-dart-diagnostics-request' or any(not isinstance(d[k],str) for k in keys-{'version'})
  or re.fullmatch(r'[a-f0-9]{64}',d['comparison_receipt_sha256'],re.ASCII) is None
  or re.fullmatch(r'[a-f0-9]{32}',d['run_id'],re.ASCII) is None or d['run_id']=='0'*32):raise ValueError('Invalid diagnostics request.')
 comparison=reader.request(d['comparison_request']);sdk=sdk_labels(d['sdk_identity'],reader);protected_sdk(sdk['root'],comparison,reader)
 content=d['replacement'].encode('utf-8')
 if not 0<len(content)<=16384 or len(content)!=comparison['after_byte_length'] or hashlib.sha256(content).hexdigest()!=comparison['after_sha256']:raise ValueError('Selected bytes changed.')
 return d,comparison,sdk,content


def clear_private_directory(fd):
 entries=0
 def clear(parent,depth):
  nonlocal entries
  if depth>32:raise ValueError('Unexpected private directory depth.')
  for entry in os.scandir(parent):
   entries+=1
   if entries>16384:raise ValueError('Unexpected private directory size.')
   info=os.stat(entry.name,dir_fd=parent,follow_symlinks=False)
   if stat.S_ISDIR(info.st_mode):
    child=os.open(entry.name,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW,dir_fd=parent)
    try:
     held=os.fstat(child)
     if (held.st_dev,held.st_ino)!=(info.st_dev,info.st_ino):raise ValueError('Private cleanup target changed.')
     clear(child,depth+1)
     now=os.stat(entry.name,dir_fd=parent,follow_symlinks=False)
     if (now.st_dev,now.st_ino)!=(held.st_dev,held.st_ino):raise ValueError('Private cleanup target replaced.')
     os.rmdir(entry.name,dir_fd=parent)
    finally:os.close(child)
   elif stat.S_ISREG(info.st_mode) or stat.S_ISLNK(info.st_mode):os.unlink(entry.name,dir_fd=parent)
   else:raise ValueError('Unexpected private cleanup entry.')
 clear(fd,0)


def diagnose(raw,candidate,reader,*,private_parent=None):
 d,comparison,sdk,content=diagnostics_request(raw,reader);scratch=None;scratch_fd=parent_fd=None;failure=None;findings=[];protocol=None
 try:
  if candidate._stop_requested:raise Refusal('stopped')
  if read_sdk(sdk['root'],comparison,candidate,reader)!=sdk:raise Refusal('input_changed')
  observed=reader.observe(d['comparison_request'],candidate)
  if observed['status']!='matching':raise Refusal('stopped' if candidate._stop_requested else 'input_changed')
  parent=Path(private_parent) if private_parent is not None else Path(__file__).parent
  parent_fd=candidate.open_directory_no_links(parent)
  for _ in range(8):
   name='diagnostics-owned-'+secrets.token_hex(8)
   try:os.mkdir(name,0o700,dir_fd=parent_fd);break
   except FileExistsError:continue
  else:raise Refusal('unavailable')
  scratch=parent/name;scratch_fd=os.open(name,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW,dir_fd=parent_fd)
  candidate.require_directory_identity(parent,parent_fd);candidate.require_directory_identity(scratch,scratch_fd)
  sdk_copy=scratch/'sdk';sdk_copy.mkdir(mode=0o700);source=scratch/'source';source.mkdir(mode=0o700);(source/'lib').mkdir(mode=0o700)
  work=scratch/'work';work.mkdir(mode=0o700)
  copied=read_sdk(sdk['root'],comparison,candidate,reader,copy_to=sdk_copy)
  if copied!=sdk or read_sdk(str(sdk_copy),comparison,candidate,reader)!={**sdk,'root':str(sdk_copy)}:raise Refusal('input_changed')
  target=source/'lib/main.dart';target.write_bytes(content);(source/'pubspec.yaml').write_text("name: isolated_fixture\nenvironment:\n  sdk: '>=3.0.0 <4.0.0'\n")
  findings=analyze(source,work,sdk_copy,d['replacement'],candidate)
  if target.read_bytes()!=content or read_sdk(str(sdk_copy),comparison,candidate,reader)!={**sdk,'root':str(sdk_copy)} or read_sdk(sdk['root'],comparison,candidate,reader)!=sdk:raise Refusal('input_changed')
  if reader.observe(d['comparison_request'],candidate)['status']!='matching':raise Refusal('stopped' if candidate._stop_requested else 'input_changed')
  protocol='1.40.1'
 except Refusal as e:failure=str(e)
 except (OSError,ValueError,TypeError,UnicodeError,KeyboardInterrupt):failure='stopped' if candidate._stop_requested else 'unavailable'
 finally:
  if scratch is not None:
   try:
    candidate.require_directory_identity(scratch,scratch_fd)
    clear_private_directory(scratch_fd)
    candidate.require_directory_identity(scratch,scratch_fd)
    os.rmdir(scratch.name,dir_fd=parent_fd)
   except (OSError,ValueError):failure='cleanup'
  if scratch_fd is not None:os.close(scratch_fd)
  if parent_fd is not None:os.close(parent_fd)
  if candidate._stop_requested:failure='stopped'
 if failure:findings=[];protocol=None
 status=('stopped' if failure=='stopped' else 'unavailable') if failure else ('incomplete' if any(f['code'].startswith('uri_') for f in findings) else 'issues' if findings else 'clean')
 value={'version':1,'scope':'imported-dart-diagnostics','request_sha256':hashlib.sha256(raw.encode()).hexdigest(),
  'run_id':d['run_id'],'comparison_request_sha256':hashlib.sha256(d['comparison_request'].encode()).hexdigest(),
  'sdk_identity_sha256':hashlib.sha256(d['sdk_identity'].encode()).hexdigest(),'selected_path':comparison['path'],'source_sha256':comparison['after_sha256'],
  'status':status,'reason':failure,'protocol_version':protocol,'diagnostics':findings,'source_verified':False,'project_verified':False,
  'mutation_authorized':False,'execution_authorized':False,'recorded_at':reader.timestamp()}
 if len(json.dumps(value,separators=(',',':'),ensure_ascii=False).encode())>32768:
  value.update(status='unavailable',reason='output_limit',protocol_version=None,diagnostics=[])
 return value


def main(argv):
 try:
  os.umask(0o077)
  if len(argv)!=1:raise ValueError()
  fd=os.open(argv[0],os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK)
  try:
   info=os.fstat(fd)
   if not stat.S_ISREG(info.st_mode) or info.st_nlink!=1 or info.st_size>PAYLOAD_LIMIT:raise ValueError()
   raw=os.read(fd,PAYLOAD_LIMIT+1).decode('utf-8')
   if len(raw.encode())!=info.st_size:raise ValueError()
  finally:os.close(fd)
  data=json.loads(raw,object_pairs_hook=unique);candidate=bundled('prepare_self_candidate');reader=bundled('imported_commit_edit_comparison')
  signal.signal(signal.SIGTERM,candidate.request_stop)
  if isinstance(data,dict) and data.get('scope')=='imported-dart-sdk-review-request':
   if set(data)!= {'version','scope','comparison_request','sdk_root'} or type(data['version']) is not int or data['version']!=1:raise ValueError()
   comparison=reader.request(data['comparison_request']);value=read_sdk(data['sdk_root'],comparison,candidate,reader);code=0
  else:
   value=diagnose(raw,candidate,reader);code=2 if value['status'] in ('unavailable','stopped') else 0
  print(json.dumps(value,separators=(',',':'),ensure_ascii=False));return code
 except (OSError,ValueError,TypeError,UnicodeError,RecursionError):
  print('Isolated Dart diagnostics unavailable.',file=sys.stderr);return 2


if __name__=='__main__':raise SystemExit(main(sys.argv[1:]))
