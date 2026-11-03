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
  nativeLock = import ./lock.nix {
    inherit (pkgs) lib;
    inherit yarnLock lockFile;
  };
  # The mirror needs the native download graph, including when the lock is
  # kept outside the project. Package outputs belong to the project builder.
  lock = purifier.checkLock {
    purifier = "yarn-classic-purifier";
    entries = nativeLock.downloads;
    outputs = { };
    inherit (nativeLock) problems;
  };
in
pkgs.callPackage ./offline-mirror.nix {
  downloads = purifier.entriesFor pkgs.stdenv.hostPlatform.system lock;
  inherit purifier;
}
