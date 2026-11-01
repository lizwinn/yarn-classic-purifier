# SPDX-License-Identifier: MIT
#
# The default package overlay. It adds the packages of pkgs/ under
# `pkgs.yarn-classic-purifier` (`.yarn` and `.yarn-classic-purifier`), and
# the builder `pkgs.buildYarnClassicProject`
# (nix/lib/build-yarn-classic-project.nix) beside them, where nixpkgs keeps
# its own builders, so a package written for callPackage takes it by name.
# A consumer that lists this flake in `projects` holds it as
# `yarn-classic-purifier/default`, which its package sets apply by default.
{ closure-lib, ... }:
let
  packages = closure-lib.caisson.nixpkgs.mkPackagesOverlay ../../pkgs "yarn-classic-purifier";
in
{
  overlay =
    final: prev:
    packages final prev
    // {
      buildYarnClassicProject = final.callPackage ../../nix/lib/build-yarn-classic-project.nix {
        inherit (closure-lib) purifier;
      };
    };
}
