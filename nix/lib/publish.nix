# SPDX-License-Identifier: MIT
#
# What `yarn-classic-purifier publish` builds before it runs `yarn publish`:
# the tarball of one package of the project, as the sandboxed build of the
# project packs it. The command evaluates this file with the project root
# and the package name.
{
  pkgs,
  # The project root.
  src,
  # The purifier lockfile, or null when the project has none.
  purifierLockFile ? null,
  # The name of the package to publish.
  package,
}:
let
  project = pkgs.callPackage ./build-yarn-classic-project.nix { } {
    inherit src purifierLockFile;
  };
in
project.packages.${package}.tarball
