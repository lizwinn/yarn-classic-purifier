# SPDX-License-Identifier: MIT
#
# The default package overlay. It adds the packages of pkgs/ under
# `pkgs.yarn-classic-purifier`: the offline wrapper `.yarn` and the command
# `.yarn-classic-purifier`. A consumer that lists this flake in `projects`
# holds it as `yarn-classic-purifier/default`, which its package sets apply
# by default. The builder lives in the library, as
# `lib.yarn-classic-purifier.buildYarnClassicProject`.
{ closure-lib, ... }:
{
  overlay = closure-lib.caisson.nixpkgs.mkPackagesOverlay ../../pkgs "yarn-classic-purifier";
}
