# SPDX-License-Identifier: MIT
# An EOL target runtime, independent of the purifier's metadata tooling.
{ pkgs, buildYarnClassicProject }:
let
  archives = {
    x86_64-linux = {
      arch = "x64";
      sha256 = "e6d052364bfa2c17da92cf31794100cfd709ba147415ddaeed2222eec9ca1469";
    };
    aarch64-linux = {
      arch = "arm64";
      sha256 = "eebdeb528df727271635196188ed7d04a5dba2c61ccaded22f693ae501cf17f5";
    };
  };
  archive = archives.${pkgs.stdenv.hostPlatform.system};
  node = pkgs.stdenvNoCC.mkDerivation {
    pname = "nodejs-legacy-fixture";
    version = "12.22.12";
    src = pkgs.fetchurl {
      url = "https://nodejs.org/dist/v12.22.12/node-v12.22.12-linux-${archive.arch}.tar.xz";
      inherit (archive) sha256;
    };
    nativeBuildInputs = [ pkgs.autoPatchelfHook ];
    buildInputs = [ pkgs.stdenv.cc.cc.lib ];
    dontConfigure = true;
    dontBuild = true;
    installPhase = ''
      mkdir -p "$out"
      cp -r bin include lib share "$out/"
    '';
  };
  project = (buildYarnClassicProject.override {
    yarn = pkgs.yarn.override { nodejs = node; };
  }) {
    src = ./fixtures/legacy-node;
    inherit node;
    nativeBuildInputs = [ ];
  };
in
pkgs.runCommand "yarn-classic-legacy-node"
  { nativeBuildInputs = [ project.packages.legacy-app pkgs.python3 ]; }
  ''
    test "$(legacy-app)" = "42 on v12.22.12"
    test -e ${project.tests}/packages/app/built.txt
    test -e ${project.tests}/packages/app/tested.txt
    test -e ${project.release}/legacy-app.tgz
    test -e ${project.release}/legacy-greeting.tgz
    python - ${project.packages.legacy-app.projections.npm.catalog} <<'PY'
    import json, sys
    catalog = json.load(open(sys.argv[1]))
    assert catalog, 'legacy project must produce an outgoing native projection'
    PY
    touch "$out"
  ''
