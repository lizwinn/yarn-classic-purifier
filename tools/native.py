# SPDX-License-Identifier: MIT
"""Lend Yarn a native lock for this working directory and restore its source."""
import argparse
import json
import os
from pathlib import Path
import subprocess
from npm_inputs import normalize_lock

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--root', type=Path, required=True)
parser.add_argument('--tool-lock', type=Path, required=True)
parser.add_argument('--views', required=True)
parser.add_argument('command', nargs=argparse.REMAINDER)
args = parser.parse_args()
command = args.command[1:] if args.command[:1] == ['--'] else args.command
file = args.root/'yarn.lock'
saved = file.read_bytes() if file.exists() else None
views = json.loads(args.views)
env = dict(os.environ, YARN_CLASSIC_PURIFIER_NATIVE_CONTEXT='1')
code = 1
try:
    if args.tool_lock.resolve() != file.resolve():
        file.write_bytes(args.tool_lock.read_bytes())
    if views:
        normalize_lock(file, views, args.root)
        rebound = subprocess.run([command[0],'install','--offline','--ignore-scripts','--non-interactive','--no-progress'],
            cwd=args.root,env=env)
        if rebound.returncode:
            raise SystemExit(rebound.returncode)
    code = subprocess.run(command, env=env).returncode
finally:
    if saved is None:
        file.unlink(missing_ok=True)
    else:
        file.write_bytes(saved)
raise SystemExit(code)
