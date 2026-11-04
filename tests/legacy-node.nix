# SPDX-License-Identifier: MIT
# An EOL target runtime, independent of the purifier's metadata tooling.
{
  pkgs,
  buildYarnClassicProject,
  version ? "12.22.12",
  abi ? "72",
}:
let
  node = import ./node-fixture.nix { inherit pkgs version; };
  managerNode =
    if version == "0.12.18" then
      import ./node-fixture.nix {
        inherit pkgs;
        version = "4.9.1";
      }
    else
      node;
  yarn = (pkgs.yarn.override { nodejs = managerNode; }).overrideAttrs (
    pkgs.lib.optionalAttrs (version == "4.9.1" || version == "0.12.18") {
      version = "1.10.1";
      src = pkgs.fetchurl {
        url = "https://github.com/yarnpkg/yarn/releases/download/v1.10.1/yarn-v1.10.1.tar.gz";
        sha256 = "97bf147cb28229e66e4e3c5733a93c851bbcb0f10fbc72696ed011774f4c6f1b";
      };
    }
  );
  project =
    (buildYarnClassicProject.override {
      inherit yarn;
    })
      {
        src = ./fixtures/legacy-node;
        inherit node;
        nativeBuildInputs = [ ];
      };
in
pkgs.runCommand "yarn-classic-node-${version}"
  {
    passthru = { inherit (project) release runtimeGraph; };
    nativeBuildInputs = [
      project.packages.legacy-app
      pkgs.python3
    ];
  }
  ''
    test "$(legacy-app)" = "42 on v${version}"
    test -e ${project.tests}
    test -e ${project.release}/legacy-app.tgz
    test -e ${project.release}/legacy-greeting.tgz
    test "$(tar -xOf ${project.release}/legacy-app.tgz package/built.txt)" = v${version}
    python - ${project.runtimeGraph}/graph.json <<'PY'
    import json, sys
    graph = json.load(open(sys.argv[1]))
    assert graph['nodeVersion'] == '${version}'
    ${
      if abi == null then
        "assert str(graph['nodeAbi']).isdigit()"
      else
        "assert graph['nodeAbi'] == '${abi}'"
    }
    assert graph['targetRuntime']['version'] != graph['helperRuntime']['version']
    assert graph['os'] == 'linux'
    PY
    python - ${project.packages.legacy-app.projections.npm.catalog} <<'PY'
    import json, sys
    catalog = json.load(open(sys.argv[1]))
    assert catalog, 'legacy project must produce an outgoing native projection'
    PY
    touch "$out"
  ''
