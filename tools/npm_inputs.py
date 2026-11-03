# SPDX-License-Identifier: MIT
"""Bind native Yarn manifests to Nix-supplied npm installation archives."""
from contextlib import contextmanager
import copy
import glob
import json
import os
from pathlib import Path
import re
import subprocess

KINDS = ('dependencies', 'devDependencies', 'optionalDependencies', 'peerDependencies')


def manifests(root):
    root = Path(root)
    paths = {root/'package.json'}
    data = json.loads((root/'package.json').read_text())
    workspaces = data.get('workspaces', [])
    if isinstance(workspaces, dict):
        workspaces = workspaces.get('packages', [])
    excluded = {Path(path) for pattern in workspaces if pattern.startswith('!')
                for path in glob.glob(str(root/pattern[1:]/'package.json'), recursive=True)}
    for pattern in workspaces:
        if not pattern.startswith('!'):
            paths.update(Path(path) for path in glob.glob(str(root/pattern/'package.json'), recursive=True))
    return sorted(paths-excluded)


def bind(root, views):
    grouped = {}
    for view in views:
        for item in json.loads(Path(view['catalog']).read_text())['modules']:
            item = dict(item, repository=view['repository'])
            versions = grouped.setdefault(item['name'], [])
            same = next((previous for previous in versions if previous['version'] == item['version']), None)
            if same is not None:
                if same['integrity'] != item['integrity']:
                    raise ValueError('conflicting Nix npm artifacts: '+item['name'])
                same['primary'] = same.get('primary', False) or item.get('primary', False)
            else:
                versions.append(item)
    saved = {}
    try:
        for path in manifests(root):
            original = path.read_bytes()
            manifest = json.loads(original)
            changed = False
            for kind in KINDS:
                for name, request in list(manifest.get(kind, {}).items()):
                    if not isinstance(request, str) or request.startswith('workspace:'):
                        continue
                    alias = re.fullmatch(r'npm:(@[^/]+/[^@]+|[^@]+)@(.+)', request)
                    actual, wanted = alias.groups() if alias else (name, request)
                    versions = grouped.get(actual, [])
                    if not versions:
                        continue
                    exact = next((item for item in versions if item['version'] == wanted), None)
                    primary = [item for item in versions if item.get('primary')]
                    selected = exact or (primary[0] if len(primary) == 1 else versions[0] if len(versions) == 1 else None)
                    if selected is None:
                        raise ValueError('Nix inputs supply multiple versions without a unique producer: '+actual)
                    manifest[kind][name] = 'file:'+str(Path(selected['repository'])/selected['archive'])
                    changed = True
            if changed:
                saved[str(path)] = {'original': original.decode(), 'bound': copy.deepcopy(manifest)}
                path.write_text(json.dumps(manifest, indent=2)+'\n')
        return saved
    except BaseException:
        restore(saved)
        raise


def restore(saved, persist=False):
    for path, state in saved.items():
        path = Path(path)
        original = state['original']
        if persist:
            before, after = json.loads(original), json.loads(path.read_text())
            for kind in KINDS:
                for name, request in state['bound'].get(kind, {}).items():
                    if after.get(kind, {}).get(name) == request and name in before.get(kind, {}):
                        after[kind][name] = before[kind][name]
            if before != after:
                path.write_text(json.dumps(after, indent=2)+'\n')
                continue
        path.write_text(original)


def normalize_lock(file, views, root=None):
    """Only declared Nix archive references are portable; other paths stay native."""
    archives = {}
    for view in views:
        for item in json.loads(Path(view['catalog']).read_text())['modules']:
            archive = Path(view['repository'])/item['archive']
            archives[archive.name] = str(archive) if root is None else os.path.relpath(archive, root)
    file = Path(file)
    if file.exists():
        before = file.read_text()
        after = re.sub(r"file:[^\s'\"{}]*?/tarballs/([a-f0-9]+\.tgz)",
            lambda match: 'file:'+archives[match[1]] if match[1] in archives else match[0], before)
        if before != after:
            file.write_text(after)


@contextmanager
def bindings(root, views, persist=False):
    saved = bind(root, views) if views else {}
    succeeded = False
    try:
        yield
        succeeded = True
    finally:
        restore(saved, persist=persist and succeeded)


if __name__ == '__main__':
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['bind', 'restore', 'normalize'])
    parser.add_argument('--state', type=Path)
    parser.add_argument('--file', type=Path)
    parser.add_argument('--root', type=Path)
    parser.add_argument('--views', type=Path)
    args = parser.parse_args()
    if args.action == 'normalize':
        normalize_lock(args.file, json.loads(args.views.read_text()))
    elif args.action == 'bind':
        views = json.loads(args.views.read_text())
        args.state.write_text(json.dumps(bind(args.root, views)))
        normalize_lock(args.root/'yarn.lock', views, args.root)
    else:
        restore(json.loads(args.state.read_text()))
