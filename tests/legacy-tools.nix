# SPDX-License-Identifier: MIT
{ pkgs, scope }:
let
  nodejs = import ./node-fixture.nix {
    inherit pkgs;
    version = "12.22.12";
  };
  yarnClassic = pkgs.yarn.override { inherit nodejs; };
  yarn = scope.yarn.override { inherit nodejs yarnClassic; };
  command = scope.yarn-classic-purifier.override { inherit nodejs yarnClassic yarn; };
in
pkgs.buildEnv {
  name = "yarn-classic-legacy-tools";
  paths = [
    nodejs
    yarn
    command
  ];
}
