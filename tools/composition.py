# SPDX-License-Identifier: MIT
"""Native command context for Nix repository inputs, with exact restoration."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
from npm_inputs import bindings, normalize_lock

parser = argparse.ArgumentParser()
for name in ('mode', 'inner', 'native-yarn', 'flake', 'nixpkgs', 'system', 'tools'):
    parser.add_argument('--'+name, required=True)
parser.add_argument('arguments', nargs=argparse.REMAINDER)
options = parser.parse_args()
arguments = options.arguments
if arguments[:1] == ['--']:
    arguments = arguments[1:]
env = dict(os.environ, YARN_CLASSIC_PURIFIER_REENTER='1')
if options.mode == 'tool' and env.get('YARN_CLASSIC_PURIFIER') == '0':
    os.execve(options.inner, [options.inner, *arguments], env)
references, cleaned = [], []
iterator = iter(arguments)
for argument in iterator:
    if options.mode == 'cli' and argument == '--input':
        reference = next(iterator, None)
        if not reference:
            parser.error('--input needs a Nix producer reference')
        references.append(reference)
    elif options.mode == 'cli' and argument.startswith('--input='):
        references.append(argument.split('=', 1)[1])
    else:
        cleaned.append(argument)
subcommand = cleaned[0] if options.mode == 'cli' and cleaned else None
tool_file = env.get('YARN_CLASSIC_PURIFIER_TOOL_LOCKFILE')
for index, argument in enumerate(cleaned):
    if argument == '--tool-lockfile':
        tool_file = cleaned[index+1]
    elif argument.startswith('--tool-lockfile='):
        tool_file = argument.split('=',1)[1]
root = Path.cwd()
marker = 'package.json' if tool_file and Path(tool_file).exists() else 'yarn.lock'
while not (root/marker).exists() and root != root.parent:
    root = root.parent
if root == root.parent and not (root/marker).exists():
    root = Path.cwd() if subcommand == 'lock' and (Path.cwd()/'package.json').exists() else None
if root is None:
    os.execve(options.inner, [options.inner, *cleaned], env)
lockfile = Path(env.get('YARN_CLASSIC_PURIFIER_LOCKFILE', str(root/'yarn-classic-purifier.lock.json'))).resolve()
for index, argument in enumerate(cleaned):
    if argument == '--lockfile':
        lockfile = Path(cleaned[index+1]).resolve()
    elif argument.startswith('--lockfile='):
        lockfile = Path(argument.split('=',1)[1]).resolve()
try:
    previous = json.loads(lockfile.read_text()).get('projectInputs', []) if lockfile.exists() else []
except json.JSONDecodeError:
    previous = []
if not references and not previous:
    os.execve(options.inner, [options.inner, *cleaned], env)
sys.path.insert(0, options.tools)
import project_inputs
pins = project_inputs.pin(references or [item['reference'] for item in previous], previous, subcommand == 'update')
state = lockfile.parent/'.yarn-classic-purifier/inputs'
state.mkdir(parents=True, exist_ok=True)
build_env = dict(env, YARN_COMPOSITION_FLAKE=options.flake, YARN_COMPOSITION_NIXPKGS=options.nixpkgs,
                 YARN_COMPOSITION_SYSTEM=options.system, YARN_COMPOSITION_INPUTS=json.dumps(pins))
expression = '''let
  flake = builtins.getFlake ("path:" + builtins.getEnv "YARN_COMPOSITION_FLAKE");
  system = builtins.getEnv "YARN_COMPOSITION_SYSTEM";
  pkgs = import (/. + builtins.getEnv "YARN_COMPOSITION_NIXPKGS") { inherit system; };
  repository = flake.lib.purifier.npmInstallRepository {
    dependencies = flake.lib.purifier.lockedProjectInputs {
      inputs = builtins.fromJSON (builtins.getEnv "YARN_COMPOSITION_INPUTS"); inherit system;
    };
    inherit (pkgs) runCommand python3;
  };
in [ repository repository.metadata ]'''
builds = json.loads(subprocess.check_output(['nix','build','--impure','--json','--expr',expression,
    '--out-link',str(state/'repository')],env=build_env,text=True))
outputs = {name:path for build in builds for name,path in build['outputs'].items()}
views = [{'repository':outputs['out'], 'catalog':str(Path(outputs['metadata'])/'catalog.json')}]
env['YARN_CLASSIC_PURIFIER_PROJECT_INPUTS'] = json.dumps(pins)
env['YARN_CLASSIC_PURIFIER_INPUT_VIEWS'] = json.dumps(views)
(state/'views.json').write_text(json.dumps(views))
env['YARN_CLASSIC_PURIFIER_INPUT_VIEWS_FILE'] = str(state/'views.json')
if subcommand == 'publish':
    from publication import publish
    publish(options, cleaned, root, lockfile, pins, env)
    raise SystemExit(0)
mutating = options.mode == 'tool' and cleaned and cleaned[0] in ('add','remove','upgrade','upgrade-interactive','import')
with bindings(root, [] if subcommand == 'publish' else views, persist=mutating):
    if subcommand == 'lock':
        native = root/'yarn.lock'
        target = Path(tool_file).resolve() if tool_file else native
        outside = target.resolve() != native.resolve()
        saved = native.read_bytes() if native.exists() else None
        try:
            if outside and target.exists():
                native.write_bytes(target.read_bytes())
            subprocess.run([options.native_yarn,'install','--ignore-scripts','--non-interactive'],cwd=root,env=env,check=True)
            normalize_lock(native, views)
            if outside:
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(native.read_bytes())
        finally:
            if outside:
                if saved is None:
                    native.unlink(missing_ok=True)
                else:
                    native.write_bytes(saved)
    result = subprocess.run([options.inner, *cleaned], env=env)
    if result.returncode:
        raise SystemExit(result.returncode)

    if subcommand == 'update' or mutating:
        normalize_lock(Path(tool_file).resolve() if tool_file else root/'yarn.lock', views)
