# SPDX-License-Identifier: MIT
#
# What the `yarn` wrapper builds for a project: the offline mirror of the
# packages its yarn.lock names, the same tree a sandboxed build of the
# project uses. The wrapper evaluates this file with the absolute paths of
# the lockfiles and keeps the result alive with a GC root.
{
  pkgs,
  lockFile,
  purifierLockFile ? null,
}:
let
  lock = import ./lock.nix {
    inherit (pkgs) lib;
    inherit lockFile purifierLockFile;
  };
in
if lock.missing != [ ] then
  throw ''
    yarn-classic-purifier: yarn-classic-purifier.lock.json records nothing for these packages:
      ${pkgs.lib.concatMapStringsSep "\n  " (m: m.resolved) lock.missing}
    Run `yarn-classic-purifier lock` in the project to record them.''
else
  pkgs.callPackage ./offline-mirror.nix { inherit (lock) downloads; }
