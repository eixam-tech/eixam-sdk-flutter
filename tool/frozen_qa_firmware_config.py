#!/usr/bin/env python3
"""Create a debug-only immutable firmware dart-define file.

Example: python3 tool/frozen_qa_firmware_config.py --zip /path/candidate.zip
  --sha256 <expected-zip-hash> --firmware-sha <full-git-sha>
  --version <exact-device-readable-version> --model 'EIXAM R1'
  --output /private/tmp/physical-qa.json

Use alongside the host's normal environment defines with a DEBUG build.
Never add this generated file or its artifact to host assets/pubspecs.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import zipfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('zip', 'sha256', 'firmware-sha', 'version', 'model', 'output'):
        parser.add_argument('--' + name, required=True)
    args = parser.parse_args()
    data = Path(args.zip).read_bytes()
    digest = hashlib.sha256(data).hexdigest()
    if digest != args.sha256 or not 0 < len(data) <= 16 * 1024 * 1024:
        parser.error('ZIP hash or size does not match the frozen candidate')
    if not re.fullmatch(r'[0-9a-f]{40}', args.firmware_sha):
        parser.error('firmware-sha must be a full immutable Git SHA')
    if not args.version.strip() or args.version != args.version.strip():
        parser.error('version must be the exact device-readable identity')
    with zipfile.ZipFile(args.zip) as archive:
        manifest = json.loads(archive.read('manifest.json'))['manifest']
        if 'application' not in manifest:
            parser.error('expected application DFU ZIP')
    configuration = {
        'EIXAM_PHYSICAL_QA': True,
        'EIXAM_QA_FIRMWARE': True,
        'EIXAM_QA_FIRMWARE_SHA': args.firmware_sha,
        'EIXAM_QA_FIRMWARE_VERSION': args.version,
        'EIXAM_QA_FIRMWARE_MODEL': args.model,
        'EIXAM_QA_FIRMWARE_ZIP_SHA256': digest,
        'EIXAM_QA_FIRMWARE_ZIP_BYTES': len(data),
    }
    with open(args.output, 'x', encoding='utf-8') as output:
        os.chmod(args.output, 0o600)
        json.dump(configuration, output)
        output.write('\n')
    release_id = f'physical-qa-{args.firmware_sha}-{digest}'
    reference = hashlib.sha256(f'{release_id}\n{args.version}\n{digest}'.encode()).hexdigest()
    print(f'Frozen QA configuration: {args.output}; SHA256={digest}; bytes={len(data)}')
    print(f'Preseed ZIP into SDK cache as {reference}.zip')


if __name__ == '__main__':
    main()
