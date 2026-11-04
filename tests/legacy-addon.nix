# SPDX-License-Identifier: MIT
{ pkgs, buildYarnClassicProject }:
let
  node = import ./node-fixture.nix {
    inherit pkgs;
    version = "12.22.12";
  };
  yarn = pkgs.yarn.override { nodejs = node; };
  project = (buildYarnClassicProject.override { inherit yarn; }) {
    src = ./fixtures/legacy-addon;
    inherit node;
    nativeBuildInputs = [ pkgs.stdenv.cc ];
  };
  repository = project.projections.npm;
in
pkgs.runCommand "yarn-classic-legacy-native-addon"
  {
    nativeBuildInputs = [
      node
      pkgs.python3
    ];
  }
  ''
    test -e ${project.tests}
    node -e 'if(require(process.argv[1]).answer !== 42) process.exit(1)' \
      ${project.packages.legacy-addon}/lib/node_modules/legacy-addon/addon.node
    python - ${project.runtimeGraph}/graph.json ${repository.catalog} ${repository} <<'PY'
    import json, sys
    from pathlib import Path
    graph = json.load(open(sys.argv[1]))
    assert graph['nodeAbi'] == '72' and graph['nodeVersion'] == '12.22.12'
    assert graph['nodes'][graph['primaries']['legacy-addon']]['native'] == 'node-addon'
    catalog = json.load(open(sys.argv[2]))
    module = catalog['modules'][0]
    Path('archive-path').write_text(str(Path(sys.argv[3]) / module['archive']))
    PY
    export HOME="$TMPDIR/home"
    export npm_config_cache="$TMPDIR/cache"
    export npm_config_registry=http://127.0.0.1:9
    mkdir -p "$HOME" consumer
    archive="$(cat archive-path)"
    cd consumer
    printf '%s' '{"name":"ordinary-consumer","version":"1.0.0"}' > package.json
    npm install --offline --ignore-scripts --no-audit "$archive"
    node -e 'if(require("legacy-addon").answer !== 42) process.exit(1)'
    touch "$out"
  ''
