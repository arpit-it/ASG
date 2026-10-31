# SPDX-License-Identifier: MPL-2.0
# Copyright 2026 Arpit Sinha

"""Explicit artifact download with private numeric telemetry and owned resume."""
import argparse
import fnmatch
import json
import os
from pathlib import Path, PurePosixPath
import threading
import time

ALLOW = ['*.json', '*.safetensors', '*.txt', '*.model', '*.jinja', 'README.md', 'LICENSE*']
IGNORE = ['*.py', '*.bin', '*.pt', '*.pth']
MARKER = '.asg-download.json'


def allowed(name):
    path = PurePosixPath(name)
    return (not path.is_absolute() and '..' not in path.parts and '\\' not in name
            and name != MARKER and not name.startswith('.cache/')
            and any(fnmatch.fnmatch(name, p) for p in ALLOW)
            and not any(fnmatch.fnmatch(name, p) for p in IGNORE))


def prepare_destination(destination, repository, revision, resume):
    identity = {'version': 1, 'repository': repository, 'revision': revision}
    if destination.is_symlink():
        raise ValueError('Linked destinations cannot be resumed')
    if destination.exists():
        if not resume:
            raise RuntimeError('Destination exists; refusing to overwrite files. Use Resume for an ASG partial download.')
        marker = destination / MARKER
        if marker.is_symlink() or not marker.is_file() or marker.stat().st_size > 4096:
            raise ValueError('No matching ASG partial download')
        saved = json.loads(marker.read_text())
        if saved != identity:
            raise ValueError('Partial download belongs to another repository or revision')
        for root, folders, files in os.walk(destination, followlinks=False):
            if any((Path(root) / name).is_symlink() for name in folders + files):
                raise ValueError('Linked partial download files are not supported')
    else:
        if resume:
            raise ValueError('No partial download to resume')
        destination.mkdir()
        (destination / MARKER).write_text(json.dumps(identity))


def transfer(repository, revision, destination, resume, hub, emit=print, interval=0.5):
    # Resolve a branch once and pin the whole transfer to that immutable revision.
    info = hub.HfApi().model_info(repository, revision=revision, files_metadata=True)
    files = {f.rfilename: f.size for f in info.siblings
             if allowed(f.rfilename) and isinstance(f.size, int) and f.size >= 0}
    if not files or not any(n.endswith('.safetensors') for n in files):
        raise ValueError('No downloadable model weights')
    prepare_destination(destination, repository, info.sha, resume)
    total = sum(files.values())
    stop = threading.Event()
    from tqdm.auto import tqdm
    lock = threading.Lock()
    # Count completed local artifacts plus Hub reconstruction callbacks, never
    # .incomplete file lengths: Xet can preallocate those before bytes arrive.
    baseline = sum(size for name, size in files.items()
                   if (destination / name).is_file()
                   and (destination / name).stat().st_size == size)
    counters = {'logical': baseline, 'network': 0}
    last_network, last_time = 0, time.monotonic()

    class Progress(tqdm):
        def __init__(self, *args, **kwargs):
            self.kind = ('logical' if str(kwargs.get('desc', '')).startswith('Reconstructing')
                         else 'network' if kwargs.get('desc') == 'Downloading bytes' else None)
            super().__init__(*args, **kwargs)

        def update(self, n=1):
            if self.kind and n is not None:
                with lock:
                    # Hub rolls reconstruction back when a server ignores Range.
                    if self.kind == 'logical':
                        counters['logical'] = max(baseline, counters['logical'] + int(n))
                    else:
                        counters['network'] += max(0, int(n))
            return super().update(n)

    def report(final=False):
        nonlocal last_network, last_time
        now = time.monotonic()
        with lock:
            current = min(total, counters['logical'])
            network = counters['network']
        speed = max(0, network - last_network) / max(0.001, now - last_time)
        emit(json.dumps({'v': 1, 'event': 'progress', 'bytes': total if final else current,
                         'total': total, 'speed': 0 if final else round(speed, 1)}, separators=(',', ':')), flush=True)
        last_network, last_time = network, now

    def monitor():
        while not stop.wait(interval):
            try:
                report()
            except OSError:
                pass  # transient file rename; next observation retries
    report()
    worker = threading.Thread(target=monitor, daemon=True)
    worker.start()
    try:
        hub.snapshot_download(repo_id=repository, revision=info.sha,
                              local_dir=str(destination), allow_patterns=list(files),
                              ignore_patterns=IGNORE, max_workers=4, tqdm_class=Progress)
        for name, size in files.items():
            if (destination / name).stat().st_size != size:
                raise ValueError('Downloaded artifact size mismatch')
    finally:
        stop.set()
        worker.join(timeout=2)
    report(final=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--repository', required=True)
    parser.add_argument('--revision', required=True)
    parser.add_argument('--destination', required=True)
    parser.add_argument('--resume', action='store_true')
    args = parser.parse_args()
    try:
        import huggingface_hub as hub
    except ImportError:
        print('{"v":1,"event":"missing_dependency"}', flush=True)
        raise
    transfer(args.repository, args.revision, Path(args.destination), args.resume, hub)


if __name__ == '__main__':
    main()
