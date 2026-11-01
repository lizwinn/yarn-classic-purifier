# SPDX-License-Identifier: MIT
#
# The `yarn-classic-purifier` library namespace: the builder
# `buildYarnClassicProject` (nix/lib/build-yarn-classic-project.nix), which
# takes the package set to build with as its `pkgs` argument. It fetches
# through the `purifier` namespace of the same library.
{ ... }:
{

  overlay = final: prev: {
    yarn-classic-purifier = {
      buildYarnClassicProject = import ../../nix/lib/build-yarn-classic-project.nix {
        inherit (final) purifier;
      };
    };
  };

}
