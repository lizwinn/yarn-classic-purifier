# SPDX-License-Identifier: MIT
{ ... }:
{
  config,
  inputs,
  lib,
  ...
}:
{

  imports = [ inputs.flake-parts.flakeModules.partitions ];

  debug = false;
  caisson = {
    libOverlays.exported = libOverlays: {
      inherit (libOverlays) default;
    };

    # The scope `pkgs.yarn-classic-purifier` is the `default` entry of this
    # flake's package overlay registry (pkg-overlays/): the package set
    # applies it by default, and the flake exports it as `pkgOverlays` and
    # as the plain `overlays.default`. The scope also holds the builder, a
    # function, so the flake exports its two commands as `packages` itself.
    nixpkgs = {
      packages.export.enabled = false;
    };
  };

  # `nix run github:nix-purifiers/yarn-classic-purifier -- install` runs
  # Yarn on the locked tarballs, offline. `nix develop
  # github:nix-purifiers/yarn-classic-purifier` gives a shell where `yarn`
  # is that wrapper, with Node.js and the `yarn-classic-purifier` command
  # beside it.
  perSystem =
    { config, pkgs, ... }:
    {
      packages = {
        inherit (pkgs.yarn-classic-purifier) yarn yarn-classic-purifier;
        default = config.packages.yarn;
      };
      devShells.default = pkgs.mkShell {
        packages = [
          config.packages.yarn
          config.packages.yarn-classic-purifier
          pkgs.nodejs
        ];
      };
    };

  partitionedAttrs.checks = "checks";
  partitionedAttrs.formatter = "formatter";

  partitions.formatter = {
    extraInputs = (lib.caisson.pins.flake-compat ../../../tests/dependencies).sources;
    module =
      { inputs, ... }:
      {
        imports = [ inputs.treefmt-nix.flakeModule ];
        perSystem.treefmt.programs.nixfmt.enable = true;
      };
  };

  partitions.checks = {
    extraInputs = (lib.caisson.pins.flake-compat ../../../tests/dependencies).sources;
    module =
      { inputs, self, ... }:
      {
        imports = [ inputs.treefmt-nix.flakeModule ];
        perSystem =
          { pkgs, ... }:
          {
            checks = import ../../../tests {
              inherit pkgs;
              overlay = self.overlays.default;
              inherit (self.lib) purifier yarn-classic-purifier;
            };
            treefmt.programs.nixfmt.enable = true;
          };
      };
  };

}
