# SPDX-License-Identifier: MIT
#
# `readLock`: the lock in memory of the purifier contract, read from a
# project's yarn.lock and its purifier lockfile:
#
#   purifier  "yarn-classic-purifier"
#   entries   the download entries of the purifier library that yarn.lock
#             and the purifier lockfile lock (nix/lib/lock.nix). Yarn
#             Classic fetches every package on every system, so no entry
#             carries `systems`. A git entry for a repository with a
#             `prepare` script carries the entries of the repository's own
#             yarn.lock in `downloads`.
#   outputs   the project's packages by name, as { version, dir, bin }
#             (nix/lib/workspaces.nix)
#   problems  why the lockfiles cannot be used, each naming the command
#             that fixes it
#
# The builder passes it to `checkLock` of the purifier library.
{ lib }:
{
  # The root of the Yarn project.
  src,
  # Yarn's lockfile.
  yarnLock ? src + "/yarn.lock",
  # The purifier lockfile, or null when the project has none.
  lockFile ?
    if builtins.pathExists (src + "/yarn-classic-purifier.lock.json") then
      src + "/yarn-classic-purifier.lock.json"
    else
      null,
}:
let
  lock = import ./lock.nix { inherit lib yarnLock lockFile; };
in
{
  purifier = "yarn-classic-purifier";
  entries = if lock.problems == [ ] then lock.downloads else [ ];
  outputs = lib.mapAttrs (_: p: {
    inherit (p) version dir bin;
  }) (import ./workspaces.nix { inherit lib src; });
  inherit (lock) problems;
}
