#!/usr/bin/env python3
"""Export manifest-pinned inputs, not an already prepared or dirty worktree."""
import argparse
import hashlib
import io
import json
from pathlib import Path
import subprocess
import tarfile
import tempfile


def pins(path):
    return dict(line.split('=', 1) for line in path.read_text().splitlines()
                if line and not line.startswith('#'))


def git(repo, *args):
    return subprocess.check_output(['git', '-C', str(repo)] + list(args))


def export(repo, commit, paths, dest):
    data = git(repo, 'archive', commit, *paths)
    with tarfile.open(fileobj=io.BytesIO(data)) as archive:
        for member in archive.getmembers():
            if member.name.startswith('/') or '..' in Path(member.name).parts:
                raise ValueError('unsafe Git archive')
        archive.extractall(str(dest))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('target')
    parser.add_argument('--repo', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--context', type=Path, default=Path(__file__).resolve().parents[1])
    args = parser.parse_args()
    manifest = pins(args.context / 'targets' / args.target / 'manifest.txt')
    tool_commit = manifest.get('profile_commit', manifest.get('source_export_commit', manifest['base_commit']))
    baseline = manifest.get('source_export_commit', manifest['base_commit'])
    profile_bytes = git(args.repo, 'show', tool_commit + ':' + manifest['profile'])
    if hashlib.sha256(profile_bytes).hexdigest() != manifest['profile_sha256']:
        raise ValueError('profile checksum does not match target manifest')
    profile = json.loads(profile_bytes)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        export(args.repo, tool_commit, ['tools/pvm-oot'], root / 'tool')
        export(args.repo, baseline, profile['source']['export_roots'], root / 'baseline')
        # Only host build tools, never a full kernel or GPU module build.
        export(args.repo, baseline, ['tools', 'scripts'], root / 'btf-source')
        (root / 'bundle.json').write_text(json.dumps({
            'format': 1, 'target': args.target, 'base_commit': manifest['base_commit'],
            'export_commit': baseline, 'profile': manifest['profile'],
            'profile_sha256': manifest['profile_sha256'],
        }, sort_keys=True, indent=2) + '\n')
        temporary_output = args.output.with_suffix(args.output.suffix + '.part')
        with tarfile.open(str(temporary_output), 'w:gz') as archive:
            for name in ('baseline', 'tool', 'btf-source', 'bundle.json'):
                archive.add(str(root / name), arcname=name)
        temporary_output.replace(args.output)
    digest = hashlib.sha256(args.output.read_bytes()).hexdigest()
    Path(str(args.output) + '.sha256').write_text(digest + '  ' + args.output.name + '\n')
    print('PVM_SOURCE_BUNDLE_SHA256=' + digest)


if __name__ == '__main__':
    main()
