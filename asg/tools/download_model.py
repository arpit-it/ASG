# SPDX-License-Identifier: MPL-2.0
# Copyright 2026 Arpit Sinha

"""Download only model artifacts from an explicit Hugging Face repository."""
import argparse
from pathlib import Path

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--repository', required=True)
    parser.add_argument('--revision', required=True)
    parser.add_argument('--destination', required=True)
    args = parser.parse_args()
    destination = Path(args.destination)
    if destination.exists():
        raise RuntimeError('Destination exists; refusing to overwrite files')
    from huggingface_hub import snapshot_download
    snapshot_download(repo_id=args.repository, revision=args.revision, local_dir=str(destination),
                      allow_patterns=['*.json', '*.safetensors', '*.txt', '*.model', '*.jinja', 'README.md', 'LICENSE*'],
                      ignore_patterns=['*.py', '*.bin', '*.pt', '*.pth'], max_workers=4)
    print('Model artifacts downloaded; no repository code executed.', flush=True)

if __name__ == '__main__':
    main()
