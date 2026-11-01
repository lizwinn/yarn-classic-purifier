# SPDX-License-Identifier: MIT
#
# What `yarn-classic-purifier publish` builds before it runs `yarn publish`:
# the tarball of one package of the project from the project's `release`,
# as package.tgz. The command evaluates this file with the project root and
# the package name.
{
  pkgs,
  # The `purifier` namespace of the shared library.
  purifier,
  # The project root.
  src,
  # The purifier lockfile, or null when the project has none.
  lockFile ? null,
  # The name of the package to publish.
  package,
}:
let
  project = import ./build-yarn-classic-project.nix { inherit purifier; } {
    inherit pkgs src lockFile;
  };
  file = (builtins.replaceStrings [ "@" "/" ] [ "" "__" ] package) + ".tgz";
in
pkgs.runCommand "yarn-classic-purifier-publish" { } ''
  mkdir -p "$out"
  ln -s ${project.release}/${pkgs.lib.escapeShellArg file} "$out/package.tgz"
''
