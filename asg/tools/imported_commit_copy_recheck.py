# SPDX-License-Identifier: MPL-2.0
# Copyright 2026 Arpit Sinha
"""Bounded read-only whole-copy observation. Never Git, mutation or execution."""
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

LIMIT = 32 * 1024
KEYS = ('version','scope','root','python','destination','copy_path','run_name','commit','tree',
        'expected_fingerprint','copy_history_sha256','copy_request_sha256','copy_receipt_sha256',
        'copy_attempt_id','recheck_id')
MARKERS = ('.asg-preparation-pending', '.asg-imported-copy-pending')


def unique(pairs):
    result = {}
    for key,value in pairs:
        if key in result:
            raise ValueError('Invalid recheck request.')
        result[key] = value
    return result


def valid_path(value):
    return (isinstance(value,str) and value.startswith('/') and value != '/'
            and not value.startswith('//') and posixpath.normpath(value) == value
            and len(value.encode('utf-8')) <= 4096
            and not any(ord(c)<32 or 127<=ord(c)<=159 for c in value)
            and not any(p.lower().endswith('.app') for p in value.split('/')))


def inside(root,value):
    root,value = root.casefold(),value.casefold()
    return value == root or value.startswith(root+'/')


def request(raw):
    if not isinstance(raw,str) or len(raw.encode('utf-8')) > LIMIT:
        raise ValueError('Invalid recheck request.')
    data=json.loads(raw,object_pairs_hook=unique)
    if (not isinstance(data,dict) or set(data)!=set(KEYS)
            or type(data['version']) is not int or data['version']!=1
            or data['scope']!='imported-commit-copy-recheck-request'
            or any(not isinstance(data[k],str) for k in KEYS[2:])
            or any(not valid_path(data[k]) for k in ('root','python','destination','copy_path'))
            or any(re.fullmatch(r'[a-f0-9]{40}',data[k],re.ASCII) is None or data[k]=='0'*40 for k in ('commit','tree'))
            or any(re.fullmatch(r'[a-f0-9]{64}',data[k],re.ASCII) is None for k in ('expected_fingerprint','copy_history_sha256','copy_request_sha256','copy_receipt_sha256'))
            or any(re.fullmatch(r'[a-f0-9]{32}',data[k],re.ASCII) is None or data[k]=='0'*32 for k in ('copy_attempt_id','recheck_id'))
            or re.fullmatch(r'asg-self-candidate-[a-f0-9]{8}',data['run_name'],re.ASCII) is None
            or data['copy_path']!=data['destination']+'/'+data['run_name']+'/source-'+data['commit']
            or inside(data['root'],data['destination']) or inside(data['root'],data['python'])
            or inside(data['destination'],data['python'])):
        raise ValueError('Invalid recheck request.')
    return data


def timestamp():
    now=datetime.datetime.now(datetime.timezone.utc)
    fraction=f'{now.microsecond:06d}'
    if fraction.endswith('000'):
        fraction=fraction[:3]
    return now.strftime('%Y-%m-%dT%H:%M:%S.')+fraction+'Z'


def observe(raw, candidate):
    data=request(raw)
    digest=hashlib.sha256(raw.encode('utf-8')).hexdigest()
    fingerprint=files=size=None
    reason='unavailable'
    descriptors=[]
    try:
        candidate.check_stop()
        parent=Path(data['destination']);run=parent/data['run_name'];root=Path(data['copy_path'])
        for directory in (parent,run,root):
            descriptor=candidate.open_directory_no_links(directory)
            descriptors.append(descriptor)
            candidate.require_directory_identity(directory,descriptor)
        if os.fstat(descriptors[1]).st_mode & 0o077:
            raise ValueError('Run is not private.')
        def current():
            candidate.check_stop()
            for directory,descriptor in zip((parent,run,root),descriptors):
                candidate.require_directory_identity(directory,descriptor)
            for marker in MARKERS:
                try:
                    os.stat(marker,dir_fd=descriptors[1],follow_symlinks=False)
                except FileNotFoundError:
                    pass
                else:
                    raise ValueError('Copy is incomplete.')
        current()
        total=0
        def count(name,content,mode):
            nonlocal total
            if content is not None:
                total+=len(content)
        deadline=time.monotonic()+15
        observed,index=candidate.scan_candidate(root,sink=count,deadline=deadline)
        current()
        second,_=candidate.scan_candidate(root,deadline=deadline)
        current()
        if observed != second:
            raise ValueError('Copy changed during recheck.')
        fingerprint,files,size=observed,len(index),total
        reason=None
    except (OSError,ValueError,KeyboardInterrupt):
        reason='stopped' if candidate._stop_requested else 'unavailable'
    finally:
        for descriptor in descriptors:
            os.close(descriptor)
    return {'version':1,'scope':'imported-commit-copy-recheck','request_sha256':digest,
            'recheck_id':data['recheck_id'],'copy_path':data['copy_path'],
            'expected_fingerprint':data['expected_fingerprint'],
            'status':('refused' if reason else 'matching' if fingerprint==data['expected_fingerprint'] else 'changed'),
            'observed_fingerprint':fingerprint,'files':files,'bytes':size,'reason':reason,
            'source_verified':False,'mutation_authorized':False,'recorded_at':timestamp()}


def main(argv):
    try:
        if len(argv)!=1:
            raise ValueError()
        fd=os.open(argv[0],os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK)
        try:
            info=os.fstat(fd)
            if not stat.S_ISREG(info.st_mode) or info.st_nlink!=1 or info.st_size>LIMIT:
                raise ValueError()
            raw=os.read(fd,LIMIT+1).decode('utf-8')
            if len(raw.encode('utf-8'))!=info.st_size:
                raise ValueError()
        finally:
            os.close(fd)
        helper=Path(__file__).with_name('prepare_self_candidate.py')
        spec=importlib.util.spec_from_file_location('prepare_self_candidate',helper)
        module=importlib.util.module_from_spec(spec);sys.modules[spec.name]=module;spec.loader.exec_module(module)
        signal.signal(signal.SIGTERM,module.request_stop)
        value=observe(raw,module)
        print(json.dumps(value,separators=(',',':')))
        return 2 if value['status']=='refused' else 0
    except (OSError,ValueError,TypeError,UnicodeError,RecursionError):
        print('Original-copy recheck unavailable.',file=sys.stderr)
        return 2


if __name__=='__main__':
    raise SystemExit(main(sys.argv[1:]))
