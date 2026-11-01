# SPDX-License-Identifier: MIT
#
# What `yarn-classic-purifier prefetch` and the `yarn` wrapper build for a
# project: the offline mirror of the packages its yarn.lock names, the same
# tree a sandboxed build of the project uses. The commands evaluate this
# file with the absolute paths of the lockfiles and keep the result alive
# with a garbage-collector root in the project.
{
  pkgs,
  # The `purifier` namespace of the shared library.
  purifier,
  # The project's yarn.lock.
  yarnLock,
  # The purifier lockfile, or null when the project has none.
  lockFile ? null,
}:
let
  lock = import ./lock.nix {
    inherit (pkgs) lib;
    inherit yarnLock lockFile;
  };
in
if lock.missing != [ ] then
  throw ''
    yarn-classic-purifier: yarn-classic-purifier.lock.json records nothing for these packages:
      ${pkgs.lib.concatMapStringsSep "\n  " (m: m.resolved) lock.missing}
    Run `yarn-classic-purifier lock` in the project to record them.''
else
  pkgs.callPackage ./offline-mirror.nix {
    inherit (lock) downloads;
    inherit purifier;
  }
