#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Run after building checks.<system>.legacy-node-tools; takes its store path."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

from registry_fixture import registry

tools = Path(sys.argv[1]).resolve()
expected_archive = Path(sys.argv[2]).resolve()
env = dict(os.environ, PATH=str(tools / 'bin') + os.pathsep + os.environ['PATH'],
           npm_config_registry='http://127.0.0.1:9', YARN_DISABLE_SELF_UPDATE_CHECK='true')


def run(*args, cwd):
    return subprocess.run(args, cwd=cwd, env=env, check=True, text=True, stdout=subprocess.PIPE).stdout.strip()


with tempfile.TemporaryDirectory(prefix='yarn-legacy-native-') as temporary:
    root = Path(temporary) / 'project'
    shutil.copytree(Path(__file__).parent / 'fixtures' / 'legacy-node', root)
    env['HOME'] = str(Path(temporary) / 'home')
    Path(env['HOME']).mkdir()
    before = {p.relative_to(root): p.read_bytes() for p in root.rglob('*') if p.is_file()}
    assert run('node', '--version', cwd=root) == 'v12.22.12'
    assert run('yarn', '--version', cwd=root) == '1.22.22'
    run('yarn-classic-purifier', 'lock', cwd=root)
    run('yarn-classic-purifier', 'prefetch', cwd=root)
    run('yarn', 'install', '--frozen-lockfile', cwd=root)
    run('yarn', 'workspace', 'legacy-app', 'run', 'build', cwd=root)
    run('yarn', 'workspace', 'legacy-app', 'run', 'test', cwd=root)
    assert (root / 'packages/app/built.txt').read_text() == 'v12.22.12'
    assert run('node', 'packages/app/cli.js', cwd=root) == '42 on v12.22.12'
    assert (root / 'installed.txt').read_text() == 'v12.22.12'
    for path, contents in before.items():
        assert (root / path).read_bytes() == contents, f'native workflow changed {path}'
    with registry(root) as (url, uploads):
        env['npm_config_registry'] = url
        run('yarn-classic-purifier', 'publish', 'legacy-app', '--registry', url, cwd=root)
        assert uploads and 'node/v12.22.12' in uploads[0][1], uploads
    assert uploads[0][0] == expected_archive.read_bytes(), 'native upload differs from the pure release'
    for path, contents in before.items():
        assert (root / path).read_bytes() == contents, f'publication changed {path}'
    print('PASS Node12/Yarn1 native lock, prefetch, offline install, workspace build/test and actual publication; source unchanged')
