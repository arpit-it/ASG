# SPDX-License-Identifier: MPL-2.0
# Copyright 2026 Arpit Sinha
"""Trusted isolated proposal staging, never working-tree editing or execution."""
import datetime
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import secrets
import signal
import stat
import subprocess
import sys
import time

LIMIT=64*1024
PENDING='.asg-imported-edit-pending'
KEYS=('version','scope','root','python','source_copy','destination','attempt_id','commit','tree','manifest_sha256','manifest_files','copy_history_sha256','copy_request_sha256','copy_receipt_sha256','recheck_request_sha256','recheck_observation_sha256','context_sha256','plan_sha256','proposal_sha256','proposal_history_sha256','expected_source_fingerprint','path','before_mode','before_git_blob','before_sha256','before_byte_length','replacement','after_sha256','after_byte_length')


def valid_text(value):
    if not isinstance(value,str):
        return False
    data=value.encode('utf-8')
    return (len(data)<=16384 and len(value.splitlines())<=500
            and not any((ord(c)<32 and c not in '\t\r\n') or 127<=ord(c)<=159 for c in value))


def preserves_format(before,after):
    bom=before.startswith('\ufeff')
    if bom!=after.startswith('\ufeff'):
        return False
    source=before[1:] if bom else before
    replacement=after[1:] if bom else after
    def legal(text):
        return re.search(r'SPDX-License-Identifier:|copyright',text,re.IGNORECASE) is not None
    if not legal(source):
        return True
    match=re.match(r'^(?://[^\r\n]*(?:\r\n|\r|\n))+',source)
    header=match.group(0) if match else None
    if header is None and source.startswith('/*'):
        end=source.find('*/',2)
        if end>=0:
            length=end+2
            if source.startswith('\r\n',length):
                length+=2
            elif source.startswith(('\r','\n'),length):
                length+=1
            header=source[:length]
    return header is not None and legal(header) and replacement.startswith(header)


def request(raw,reader):
    if not isinstance(raw,str) or len(raw.encode('utf-8'))>LIMIT:
        raise ValueError('Invalid isolated proposal intent.')
    data=json.loads(raw,object_pairs_hook=reader.unique)
    if not isinstance(data,dict) or set(data)!=set(KEYS):
        raise ValueError('Invalid isolated proposal intent.')
    integers={'version','manifest_files','before_byte_length','after_byte_length'}
    if (any(type(data[k]) is not int if k in integers else not isinstance(data[k],str) for k in KEYS)
            or data['version']!=1 or data['scope']!='imported-commit-edit-request'
            or not all(reader.valid_path(data[k]) for k in ('root','python','source_copy','destination'))
            or not all(re.fullmatch(r'[a-f0-9]{40}',data[k],re.ASCII) and data[k]!='0'*40 for k in ('commit','tree','before_git_blob'))
            or not all(re.fullmatch(r'[a-f0-9]{64}',data[k],re.ASCII) for k in KEYS if k.endswith('_sha256') or k=='expected_source_fingerprint')
            or not re.fullmatch(r'[a-f0-9]{32}',data['attempt_id'],re.ASCII) or data['attempt_id']=='0'*32
            or not re.fullmatch(r'(lib|test)/[A-Za-z0-9_]+(?:/[A-Za-z0-9_]+)*\.dart',data['path'],re.ASCII) or len(data['path'].split('/'))>16
            or data['before_mode'] not in ('100644','100755') or not 1<=data['manifest_files']<=2048
            or not 0<=data['before_byte_length']<=32768 or not valid_text(data['replacement'])
            or data['after_byte_length']!=len(data['replacement'].encode('utf-8'))
            or data['after_sha256']!=hashlib.sha256(data['replacement'].encode('utf-8')).hexdigest()):
        raise ValueError('Invalid isolated proposal intent.')
    source=Path(data['source_copy']);run=source.parent
    if (source.name!='source-'+data['commit'] or re.fullmatch(r'asg-self-candidate-[a-f0-9]{8}',run.name,re.ASCII) is None
            or reader.inside(data['root'],str(source)) or reader.inside(data['root'],data['destination'])
            or reader.inside(str(run),data['destination']) or reader.inside(data['root'],data['python'])
            or reader.inside(str(run.parent),data['python']) or reader.inside(data['destination'],data['python'])):
        raise ValueError('Invalid isolated proposal paths.')
    return data


def timestamp():
    now=datetime.datetime.now(datetime.timezone.utc);fraction=f'{now.microsecond:06d}'
    if fraction.endswith('000'):
        fraction=fraction[:3]
    return now.strftime('%Y-%m-%dT%H:%M:%S.')+fraction+'Z'


def response(data,digest,reason,run=None,fingerprint=None,size=None):
    return {'version':1,'scope':'imported-commit-edit','request_sha256':digest,'attempt_id':data['attempt_id'],
            'root':data['root'],'source_copy':data['source_copy'],'destination':data['destination'],'commit':data['commit'],
            'expected_source_fingerprint':data['expected_source_fingerprint'],'selected_path':data['path'],'after_sha256':data['after_sha256'],
            'status':'refused' if reason else 'prepared','reason':reason,'run_name':run,
            'copy_path':str(Path(data['destination'])/run/('source-'+data['commit'])) if reason is None else None,
            'fingerprint':fingerprint,'files':data['manifest_files'] if reason is None else None,'bytes':size,
            'source_verified':False,'execution_authorized':False,'recorded_at':timestamp()}


def prepare(raw,candidate,reader):
    data=request(raw,reader);digest=hashlib.sha256(raw.encode('utf-8')).hexdigest()
    descriptors=[];run_name=None
    try:
        candidate.check_stop();deadline=time.monotonic()+45
        original=Path(data['root']);source=Path(data['source_copy']);source_run=source.parent;destination=Path(data['destination'])
        paths=(original,source_run.parent,source_run,source)
        for directory in paths:
            fd=candidate.open_directory_no_links(directory);descriptors.append(fd);candidate.require_directory_identity(directory,fd)
        if os.fstat(descriptors[2]).st_mode&0o077:
            raise ValueError('Expected private original copy.')
        # Only trusted, config-disabled Git metadata reads protect external object stores.
        storage=candidate.git_storage_directories(original,deadline,require_worktree_root=True)
        parent_fd=candidate.open_snapshot_destination(destination,(original,source_run,*storage),'Choose an output outside original/copy/Git storage.')
        descriptors.append(parent_fd)
        def current():
            candidate.check_preparation_deadline(deadline)
            for directory,fd in zip(paths,descriptors[:4]):
                candidate.require_directory_identity(directory,fd)
            candidate.require_directory_identity(destination,parent_fd)
            if os.fstat(descriptors[2]).st_mode&0o077:
                raise ValueError('Original run privacy changed.')
            for marker in reader.MARKERS:
                try:
                    os.stat(marker,dir_fd=descriptors[2],follow_symlinks=False)
                except FileNotFoundError:
                    pass
                else:
                    raise ValueError('Original copy is incomplete.')
        current();captured={data['path']:None}
        source_digest,index=candidate.scan_candidate(source,capture=captured,deadline=deadline)
        before=captured[data['path']];replacement=data['replacement'].encode('utf-8')
        if (source_digest!=data['expected_source_fingerprint'] or len(index)!=data['manifest_files'] or before is None
                or len(before)!=data['before_byte_length'] or hashlib.sha256(before).hexdigest()!=data['before_sha256']
                or index[data['path']]!=(data['before_mode'],data['before_git_blob']) or before==replacement
                or not preserves_format(before.decode('utf-8'),data['replacement'])):
            return response(data,digest,'input_changed')
        current()
        for _ in range(8):
            candidate.check_preparation_deadline(deadline)
            proposed='asg-self-candidate-'+secrets.token_hex(4)
            try:
                os.mkdir(proposed,0o700,dir_fd=parent_fd);run_name=proposed;break
            except FileExistsError:
                pass
        if run_name is None:
            raise ValueError('No fresh output available.')
        run=destination/run_name;run_fd=os.open(run_name,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW,dir_fd=parent_fd);descriptors.append(run_fd)
        marker=os.open(PENDING,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600,dir_fd=run_fd)
        with os.fdopen(marker,'w') as pending:
            pending.write(digest);pending.flush();os.fsync(pending.fileno())
        os.mkdir('incomplete',0o700,dir_fd=run_fd)
        stage_fd=os.open('incomplete',os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW,dir_fd=run_fd);descriptors.append(stage_fd)
        expected=hashlib.sha256(b'ASG candidate tree v1\0');total=substitutions=0
        def copy(relative,content,mode):
            nonlocal total,substitutions
            candidate.check_preparation_deadline(deadline)
            parts=relative.split('/')
            if content is None:
                expected.update(b'D'+relative.encode('ascii')+b'\0')
                holder=os.dup(stage_fd)
                try:
                    for part in parts:
                        try:os.mkdir(part,0o700,dir_fd=holder)
                        except FileExistsError:pass
                        child=os.open(part,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW,dir_fd=holder);os.close(holder);holder=child
                finally:os.close(holder)
                return
            if relative==data['path']:
                if content!=before or ('100755' if mode&stat.S_IXUSR else '100644')!=data['before_mode']:
                    raise ValueError('Selected original changed.')
                content=replacement;substitutions+=1
            total+=len(content)
            if total>candidate.MAX_TOTAL_BYTES:
                raise ValueError('Proposed output exceeds limits.')
            expected.update((b'X' if mode&stat.S_IXUSR else b'F')+relative.encode('ascii')+b'\0'+hashlib.sha256(content).digest())
            candidate.write_blob(stage_fd,parts,mode,content)
        copied,index=candidate.scan_candidate(source,sink=copy,deadline=deadline)
        if copied!=source_digest or substitutions!=1:
            raise ValueError('Original copy changed.')
        current();candidate.require_directory_identity(run,run_fd)
        staging=run/'incomplete';candidate.require_directory_identity(staging,stage_fd)
        staged,index=candidate.scan_candidate(staging,allow_incomplete=True,deadline=deadline)
        if staged!=expected.hexdigest() or len(index)!=data['manifest_files']:
            raise ValueError('Staged output differs.')
        if candidate.scan_candidate(source,deadline=deadline)[0]!=source_digest:
            raise ValueError('Original copy changed before publication.')
        current()
        ready=run/source.name
        published=candidate.publish_verified_snapshot(ready,parent_fd,run_fd,stage_fd,staged,deadline=deadline)
        current();candidate.require_directory_identity(run,run_fd)
        # The new protocol remains pending until its own final full observation,
        # even when legacy publication verification already succeeded.
        candidate.require_directory_identity(ready,stage_fd)
        final_digest,final_index=candidate.scan_candidate(ready,deadline=deadline)
        if final_digest!=published or len(final_index)!=data['manifest_files']:
            raise ValueError('Published proposed copy changed.')
        current();candidate.require_directory_identity(run,run_fd)
        candidate.require_directory_identity(ready,stage_fd)
        if published==source_digest:
            raise ValueError('No proposed change observed.')
        marker=os.open(PENDING,os.O_RDONLY|os.O_NOFOLLOW,dir_fd=run_fd)
        try:
            info=os.fstat(marker)
            if not stat.S_ISREG(info.st_mode) or info.st_nlink!=1 or os.read(marker,65)!=digest.encode('ascii'):
                raise ValueError('Pending marker changed.')
        finally:os.close(marker)
        os.unlink(PENDING,dir_fd=run_fd)
        return response(data,digest,None,run_name,published,total)
    except (OSError,ValueError,subprocess.SubprocessError,KeyboardInterrupt):
        return response(data,digest,'stopped' if candidate._stop_requested else 'unavailable',run_name)
    finally:
        for fd in descriptors:os.close(fd)


def bundled(name):
    file=Path(__file__).with_name(name+'.py');spec=importlib.util.spec_from_file_location(name,file)
    module=importlib.util.module_from_spec(spec);sys.modules[name]=module;spec.loader.exec_module(module);return module


def main(argv):
    try:
        if len(argv)!=1:raise ValueError()
        fd=os.open(argv[0],os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK)
        try:
            info=os.fstat(fd)
            if not stat.S_ISREG(info.st_mode) or info.st_nlink!=1 or info.st_size>LIMIT:raise ValueError()
            raw=os.read(fd,LIMIT+1).decode('utf-8')
            if len(raw.encode('utf-8'))!=info.st_size:raise ValueError()
        finally:os.close(fd)
        candidate=bundled('prepare_self_candidate');reader=bundled('imported_commit_copy_recheck')
        signal.signal(signal.SIGTERM,candidate.request_stop)
        value=prepare(raw,candidate,reader);print(json.dumps(value,separators=(',',':')))
        return 0 if value['status']=='prepared' else 2
    except (OSError,ValueError,TypeError,UnicodeError,RecursionError):
        print('Isolated proposed copy unavailable. Inspect the destination.',file=sys.stderr);return 2


if __name__=='__main__':raise SystemExit(main(sys.argv[1:]))
