# SPDX-License-Identifier: MIT
"""Publish the exact Nix projection with Yarn's native registry client."""
import json
from pathlib import Path
import subprocess
import tempfile


def publish(options, arguments, root, lockfile, pins, env):
    positional = []
    tool_lock = Path(env.get('YARN_CLASSIC_PURIFIER_TOOL_LOCKFILE', str(root/'yarn.lock'))).resolve()
    iterator = iter(arguments[1:])
    for argument in iterator:
        if argument in ('--lockfile', '--tool-lockfile'):
            value = next(iterator)
            if argument == '--tool-lockfile':
                tool_lock = Path(value).resolve()
        else:
            positional.append(argument)
    if not positional:
        raise ValueError('publish needs a package name')
    package, *flags = positional
    build_env = dict(env, YARN_COMPOSITION_FLAKE=options.flake, YARN_COMPOSITION_NIXPKGS=options.nixpkgs,
        YARN_COMPOSITION_SYSTEM=options.system, YARN_COMPOSITION_ROOT=str(root),
        YARN_COMPOSITION_LOCK=str(lockfile), YARN_COMPOSITION_TOOL_LOCK=str(tool_lock),
        YARN_COMPOSITION_PACKAGE=package, YARN_COMPOSITION_INPUTS=json.dumps(pins))
    expression = '''let
      flake = builtins.getFlake ("path:" + builtins.getEnv "YARN_COMPOSITION_FLAKE");
      system = builtins.getEnv "YARN_COMPOSITION_SYSTEM";
      pkgs = import (/. + builtins.getEnv "YARN_COMPOSITION_NIXPKGS") {
        inherit system; overlays = [ flake.overlays.default ];
      };
      project = pkgs.yarn-classic-purifier.buildYarnClassicProject {
        src = /. + builtins.getEnv "YARN_COMPOSITION_ROOT";
        lockFile = /. + builtins.getEnv "YARN_COMPOSITION_LOCK";
        yarnLock = /. + builtins.getEnv "YARN_COMPOSITION_TOOL_LOCK";
        dependencies = flake.lib.purifier.lockedProjectInputs {
          inputs = builtins.fromJSON (builtins.getEnv "YARN_COMPOSITION_INPUTS"); inherit system;
        };
      };
      repository = project.packages.${builtins.getEnv "YARN_COMPOSITION_PACKAGE"}.projections.npm;
    in [ repository repository.metadata ]'''
    builds = json.loads(subprocess.check_output(['nix','build','--impure','--no-link','--json','--expr',expression],
        env=build_env,text=True))
    outputs = {name:path for build in builds for name,path in build['outputs'].items()}
    modules = json.loads((Path(outputs['metadata'])/'catalog.json').read_text())['modules']
    registry = []
    iterator = iter(flags)
    for flag in iterator:
        if flag in ('--registry','--userconfig'):
            registry.extend([flag,next(iterator)])
        elif flag.startswith(('--registry=','--userconfig=')):
            registry.append(flag)
    publish_flags = flags if any(flag == '--tag' or flag.startswith('--tag=') for flag in flags) else ['--tag','nix',*flags]
    for item in sorted(modules,key=lambda item:(item['primary'],item['name'])):
        if not item['primary']:
            lookup = list(registry)
            if not any(flag == '--registry' or flag.startswith('--registry=') for flag in lookup) and item['package'].get('publishConfig',{}).get('registry'):
                lookup.extend(['--registry',item['package']['publishConfig']['registry']])
            existing = subprocess.run([options.native_yarn,'info',item['name']+'@'+item['version'],
                'dist.integrity','--json',*lookup],cwd=root,env=env,capture_output=True,text=True)
            integrity = None
            if existing.returncode == 0:
                for line in existing.stdout.splitlines():
                    document = json.loads(line)
                    if document.get('type') == 'inspect':
                        integrity = document.get('data')
            if integrity == item['integrity']:
                continue
            if integrity is not None:
                raise ValueError('registry artifact differs from Nix input: '+item['name']+'@'+item['version'])
        # Yarn 1 reads registry coordinates from cwd even for a tarball
        # argument. Give its native publisher that archive's own metadata.
        # A child of the ignored state directory retains project config.
        staging = root/'.yarn-classic-purifier'
        staging.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(prefix='publication-',dir=staging) as temporary:
            directory = Path(temporary)
            (directory/'package.json').write_text(json.dumps(item['package']))
            subprocess.run([options.native_yarn,'publish',str(Path(outputs['out'])/item['archive']),
                '--non-interactive',*publish_flags],cwd=directory,env=env,check=True)
