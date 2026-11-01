#!/usr/bin/env python3
"""Prepare a disposable, checksum-verified vendored bridge source tree.

The global Go module cache is never patched. The complete vendor inventory and
the exact upstream-to-repaired file hashes remain available beside the build.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def prepare(output):
    source = Path(__file__).resolve().parent
    manifest = json.loads((source/'DependencyRepairs.json').read_text())
    patch = source/'dependency-repairs.patch'
    if digest(patch) != manifest['patch_sha256']:
        raise ValueError('Dependency patch differs from its recorded hash')
    output.mkdir(parents=True, exist_ok=False)
    bridge = output/'Tools/AezeedBridge'
    bridge.mkdir(parents=True)
    names = ['go.mod', 'go.sum', 'main.go', 'main_test.go', 'dependency_repairs_test.go']
    for name in names:
        shutil.copyfile(source/name, bridge/name)
    shutil.copytree(source/'cmd', bridge/'cmd', ignore=shutil.ignore_patterns('._*', '.DS_Store'))
    shutil.copytree(source/'include', bridge/'include', ignore=shutil.ignore_patterns('._*', '.DS_Store'))
    shutil.copytree(source/'testdata', bridge/'testdata', ignore=shutil.ignore_patterns('._*', '.DS_Store'))
    env = {k: v for k, v in os.environ.items() if k in
           ['HOME', 'PATH', 'TMPDIR', 'LANG', 'LC_ALL', 'DEVELOPER_DIR', 'GOCACHE', 'GOMODCACHE']}
    env.update(GOTOOLCHAIN='go1.26.5', GOWORK='off', GOFLAGS='-mod=readonly',
               GIT_CEILING_DIRECTORIES=str(output))
    def run(args):
        subprocess.run(args, cwd=bridge, env=env, check=True)
    run(['go', 'mod', 'download'])
    run(['go', 'mod', 'verify'])
    run(['go', 'mod', 'vendor'])
    for name in ['go.mod', 'go.sum']:
        if (bridge/name).read_bytes() != (source/name).read_bytes():
            raise ValueError('Dependency graph changed while preparing sources')
    def inventory():
        return {str(p.relative_to(bridge)): digest(p) for p in sorted(bridge.rglob('*')) if p.is_file()}
    before = inventory()
    expected = {row['path']: row for row in manifest['files']}
    if len(expected) != len(manifest['files']):
        raise ValueError('Duplicate patch inventory path')
    for name, row in expected.items():
        if not name.startswith('vendor/') or before.get(name) != row['before_sha256']:
            raise ValueError('Unexpected dependency source: '+name)
    headers = [line[6:] for line in patch.read_text().splitlines() if line.startswith(('--- a/', '+++ b/'))]
    if len(headers) != 2*len(expected) or set(headers) != set(expected):
        raise ValueError('Patch must touch only the recorded dependency files')
    run(['git', 'apply', '--check', str(patch)])
    run(['git', 'apply', str(patch)])
    after = inventory()
    if set(before) != set(after) or {name for name in before if before[name] != after[name]} != set(expected):
        raise ValueError('Dependency patch changed unlisted files')
    for name, row in expected.items():
        if after[name] != row['after_sha256']:
            raise ValueError('Repaired source hash mismatch: '+name)
    (output/'prepared-source.json').write_text(json.dumps({
        'schema': 1, 'go_toolchain': 'go1.26.5', 'patch_sha256': digest(patch),
        'repairs': manifest['files'],
        'vendor_files': {name: sha for name, sha in after.items() if name.startswith('vendor/')},
        'source_files': {name: sha for name, sha in after.items() if not name.startswith('vendor/')},
        'go_mod_sha256': digest(bridge/'go.mod'), 'go_sum_sha256': digest(bridge/'go.sum'),
    }, indent=2)+'\n')
    return bridge


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path, help='New disposable output directory; must not exist')
    args = parser.parse_args()
    print(prepare(args.output.resolve()))
