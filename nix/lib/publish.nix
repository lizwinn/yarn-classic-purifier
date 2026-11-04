# SPDX-License-Identifier: MIT
#
# What `yarn-classic-purifier publish` builds before it runs `yarn publish`:
# the tarball of one package of the project from the project's `release`,
# as package.tgz. The command evaluates this file with a package set that
# has the flake's `overlays.default` applied, the project root and the
# package name.
{
  pkgs,
  node ? pkgs.nodejs,
  yarnClassic ? pkgs.yarn,
  # The project root.
  src,
  # Yarn's lockfile.
  yarnLock ? src + "/yarn.lock",
  # The purifier lockfile, or null when the project has none.
  lockFile ? null,
  # The name of the package to publish.
  package,
}:
let
  project = (pkgs.yarn-classic-purifier.buildYarnClassicProject.override { yarn = yarnClassic; }) {
    inherit
      src
      yarnLock
      lockFile
      node
      ;
  };
  file = (builtins.replaceStrings [ "@" "/" ] [ "" "__" ] package) + ".tgz";
in
pkgs.runCommand "yarn-classic-purifier-publish" { } ''
  mkdir -p "$out"
  ln -s ${project.release}/${pkgs.lib.escapeShellArg file} "$out/package.tgz"
''
