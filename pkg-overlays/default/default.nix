# SPDX-License-Identifier: MIT
#
# The default package overlay. It adds one attribute to the package set:
# the scope `pkgs.yarn-classic-purifier`, made with lib.makeScope. The scope
# holds the packages of pkgs/ (`.yarn`, the offline wrapper, and
# `.yarn-classic-purifier`, the command) and the builder
# `.buildYarnClassicProject` (nix/lib/build-yarn-classic-project.nix), a
# package for callPackage in that scope. `.overrideScope` replaces what
# everything in the scope shares, `.buildYarnClassicProject.override`
# replaces what the builder takes, and a package written for callPackage
# takes the scope by name. A consumer that lists this flake in `projects`
# holds it as `yarn-classic-purifier/default`, which its package sets apply
# by default.
{ closure-lib, ... }:
let
  packages = closure-lib.caisson.nixpkgs.mkPackagesOverlay ../../pkgs "yarn-classic-purifier";
in
{
  overlay =
    final: prev:
    let
      scoped = packages final prev;
    in
    scoped
    // {
      yarn-classic-purifier = scoped.yarn-classic-purifier.overrideScope (
        self: _: {
          inherit (closure-lib) purifier;
          # The scope's own `yarn` is the offline wrapper, so the builder
          # takes Yarn Classic from nixpkgs explicitly.
          buildYarnClassicProject = self.callPackage ../../nix/lib/build-yarn-classic-project.nix {
            inherit (final) yarn;
            inherit (closure-lib) purifier;
          };
        }
      );
    };
}
