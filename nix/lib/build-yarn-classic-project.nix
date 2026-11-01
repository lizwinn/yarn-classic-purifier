# SPDX-License-Identifier: MIT
#
# buildYarnClassicProject: sandboxed builds of a Yarn Classic (Yarn 1)
# project, from the yarn.lock at its root. The project needs no Nix files of
# its own: yarn.lock names every tarball the install fetches, with its
# hash, and the package.json files name the project's own packages (the
# root and its workspaces).
#
# The flake's library publishes it as
# `lib.yarn-classic-purifier.buildYarnClassicProject`:
#
#   (yarn-classic-purifier.lib.yarn-classic-purifier.buildYarnClassicProject {
#     inherit pkgs;
#     src = ./.;
#   }).packages.my-app
#
# The first argument set is what the library overlay passes. The builder
# returns
#
#   packages.<name>   package <name> of the project, installed with its
#                     production dependencies under lib/node_modules, with
#                     its commands in bin/
#   tests             the project after `yarn install`, its build scripts
#                     and its test scripts, run in the sandbox
#   release           the project after `yarn install`, its build scripts
#                     and `yarn pack`: one tarball per package of the
#                     project, the files `yarn-classic-purifier publish`
#                     uploads
#   fetches           the `entries` of the lock in memory: the entries of
#                     the purifier library that the build fetches; a git
#                     entry for a repository with a `prepare` script carries
#                     the entries of the repository's yarn.lock in
#                     `downloads`
{
  # The `purifier` namespace of the shared library.
  purifier,
}:
{
  # The package set the build takes its tools from.
  pkgs,
  # The root of the Yarn project.
  src,
  # Replaces fetchers of the purifier library, such as `fetchurl` with one
  # that sends credentials to a company mirror. The purifier library's
  # fetchEntry and tree take it unchanged.
  fetchers ? { },
  # Yarn's lockfile. A yarn.lock given outside `src` replaces the one in
  # `src` during the build.
  yarnLock ? src + "/yarn.lock",
  # The purifier lockfile, which records the hashes of the tarballs that
  # yarn.lock gives no hash for. The default is the one
  # `yarn-classic-purifier lock` writes at the project root, when it exists.
  # A packaging flake can keep it outside `src`.
  lockFile ?
    if builtins.pathExists (src + "/yarn-classic-purifier.lock.json") then
      src + "/yarn-classic-purifier.lock.json"
    else
      null,
  # The Node.js that runs Yarn and the project's scripts, and that the
  # packages' commands run on.
  node ? pkgs.nodejs,
  # The package scripts that build the project, run in order before the
  # packages are packed. A script the root package defines runs at the
  # root; otherwise it runs in each workspace that defines it.
  buildScripts ? [ "build" ],
  # The package scripts that `tests` runs the same way, after the build
  # scripts.
  testScripts ? [ "test" ],
  # Tools the build scripts and the dependencies' install scripts need.
  # Python and node-gyp are there for native addons.
  nativeBuildInputs ? [
    pkgs.python3
    pkgs.node-gyp
  ],
  # Libraries native addons link against.
  buildInputs ? [ ],
  # Filters the project root before it is copied into the store, as the
  # `filter` of builtins.path. The default leaves out installed
  # dependencies, version control and Nix result links.
  srcFilter ? null,
}:
let
  inherit (pkgs)
    lib
    stdenv
    callPackage
    yarn
    autoPatchelfHook
    ;

  # The lock in memory (nix/lib/read-lock.nix). checkLock fails evaluation
  # with its problems, each naming the command that fixes it.
  lock = purifier.checkLock (
    import ./read-lock.nix { inherit lib; } {
      inherit src yarnLock lockFile;
    }
  );
  downloads = purifier.entriesFor stdenv.hostPlatform.system lock;

  ownPackageSet = import ./workspaces.nix { inherit lib src; };
  ownPackages = builtins.attrValues ownPackageSet;

  defaultSrcFilter =
    path: type:
    let
      name = baseNameOf path;
    in
    !((type == "directory" && name == "node_modules") || name == ".git" || lib.hasPrefix "result" name);

  filteredSrc = builtins.path {
    path = src;
    name = "yarn-source";
    filter = if srcFilter != null then srcFilter else defaultSrcFilter;
  };

  dependencies = callPackage ./offline-mirror.nix {
    inherit
      downloads
      node
      purifier
      fetchers
      ;
  };

  # The file name of a package's tarball in `release`.
  tarballName = p: (builtins.replaceStrings [ "@" "/" ] [ "" "__" ] p.name) + ".tgz";

  steps = import ./yarn-install.nix { inherit lib node; };

  # Prebuilt Linux binaries in packages get their dynamic loader and
  # libraries from the store; the install steps patch them.
  binaryPatching = lib.optionals stdenv.hostPlatform.isLinux [ autoPatchelfHook ];
  binaryLibraries = lib.optionals stdenv.hostPlatform.isLinux [ stdenv.cc.cc.lib ];
  yarnSetup = steps.setup dependencies;
  yarnInstall = steps.install;

  # Runs package script $1 at the root when the root defines it, and in
  # every workspace that defines it otherwise.
  runScript = ''
    runScript() {
      if node -e 'process.exit(require("./package.json").scripts?.[process.argv[1]] ? 0 : 1)' "$1"; then
        yarn run "$1"
      else
        ${lib.concatMapStrings (p: ''
          if node -e 'process.exit(require(process.argv[2] + "/package.json").scripts?.[process.argv[1]] ? 0 : 1)' "$1" ./${lib.escapeShellArg p.dir}; then
            (cd ./${lib.escapeShellArg p.dir} && yarn run "$1")
          fi
        '') (builtins.filter (p: p.dir != "") ownPackages)}
        :
      fi
    }
  '';

  # The yarn.lock the build installs from, which replaces the one in the
  # source when it was given from outside it.
  useYarnLock = ''
    cp --no-preserve=mode ${yarnLock} yarn.lock
  '';

  # The project after `yarn install` and the package scripts `scripts`,
  # with `install` as its install phase.
  installed =
    {
      name,
      scripts,
      install,
    }:
    stdenv.mkDerivation {
      inherit name;
      src = filteredSrc;
      nativeBuildInputs = [
        node
        yarn
      ]
      ++ nativeBuildInputs
      ++ binaryPatching;
      buildInputs = buildInputs ++ binaryLibraries;
      autoPatchelfIgnoreMissingDeps = [ "*" ];
      dontConfigure = true;
      buildPhase = ''
        runHook preBuild
        ${useYarnLock}
        ${yarnSetup}
        ${yarnInstall [ ]}
        ${runScript}
        for script in ${lib.escapeShellArgs scripts}; do
          runScript "$script"
        done
        runHook postBuild
      '';
      installPhase = ''
        runHook preInstall
        ${install}
        runHook postInstall
      '';
      dontFixup = true;
    };

  # `yarn pack` runs the packages' prepack and postpack scripts, as
  # `yarn publish` does. The tarballs are what Yarn publishes, byte for
  # byte.
  build = installed {
    name = "yarn-project-release";
    scripts = buildScripts;
    install = ''
      mkdir -p "$out"
      ${lib.concatMapStrings (p: ''
        (cd ./${lib.escapeShellArg p.dir} && yarn pack --offline --silent --filename "$out"/${lib.escapeShellArg (tarballName p)})
      '') ownPackages}
    '';
  };

  productionModules = stdenv.mkDerivation {
    name = "yarn-project-production-modules";
    src = filteredSrc;
    nativeBuildInputs = [
      node
      yarn
    ]
    ++ nativeBuildInputs
    ++ binaryPatching;
    buildInputs = buildInputs ++ binaryLibraries;
    autoPatchelfIgnoreMissingDeps = [ "*" ];
    dontConfigure = true;
    # The project's own install scripts often run tools from its
    # devDependencies, which a production install leaves out. They build
    # nothing the production dependencies need, so they are removed from
    # the project's package.json files before the install.
    buildPhase = ''
      runHook preBuild
      ${useYarnLock}
      ${yarnSetup}
      for dir in ${lib.escapeShellArgs (map (p: if p.dir == "" then "." else p.dir) ownPackages)} .; do
        node -e '
          const fs = require("fs");
          const file = process.argv[1] + "/package.json";
          const manifest = JSON.parse(fs.readFileSync(file, "utf8"));
          for (const s of ["preinstall", "install", "postinstall", "prepublish", "preprepare", "prepare", "postprepare"]) {
            delete manifest.scripts?.[s];
          }
          fs.writeFileSync(file, JSON.stringify(manifest, null, 2));
        ' "$dir"
      done
      ${yarnInstall [ "--production" ]}
      # A `link:` dependency is a symlink into the project, which the
      # installed packages do not contain, so it becomes a copy of its
      # target.
      find . -path '*node_modules/*' -not -path '*/.bin/*' -type l -print0 \
        | while IFS= read -r -d "" link; do
            target="$(readlink -f "$link")"
            rm "$link"
            cp -r "$target" "$link"
          done
      runHook postBuild
    '';
    # Every node_modules directory of the tree, at its place: the one at
    # the root, and those Yarn put inside workspaces for versions that could
    # not be hoisted.
    installPhase = ''
      runHook preInstall
      mkdir -p "$out"
      find . -name node_modules -type d -prune -print0 | while IFS= read -r -d "" dir; do
        mkdir -p "$out/$(dirname "$dir")"
        cp -a "$dir" "$out/$dir"
      done
      runHook postInstall
    '';
    # The links to the workspaces dangle here; each package replaces them
    # with installed copies.
    dontFixup = true;
  };

  # Package p installed the way a global install lays out a package:
  # lib/node_modules/<name> holds the package's files, and its production
  # dependencies lie beside it, where Node.js resolves them. The project's
  # own packages lie there as installed copies too, so a workspace that
  # depends on another finds it.
  mkPackage =
    p:
    stdenv.mkDerivation {
      pname = builtins.replaceStrings [ "@" "/" ] [ "" "-" ] p.name;
      inherit (p) version;
      dontUnpack = true;
      dontConfigure = true;
      dontBuild = true;
      # The commands' interpreter is this Node.js.
      buildInputs = [ node ];
      installPhase = ''
        runHook preInstall
        modules="$out/lib/node_modules"
        mkdir -p "$modules"
        if [ -d ${productionModules}/node_modules ]; then
          cp -a ${productionModules}/node_modules/. "$modules/"
          chmod -R u+w "$modules"
          rm -rf "$modules/.bin" "$modules/.yarn-integrity"
        fi
        ${lib.concatMapStrings (o: ''
          rm -rf "$modules"/${lib.escapeShellArg o.name}
          mkdir -p "$modules"/${lib.escapeShellArg o.name}
          tar -xzf ${build}/${lib.escapeShellArg (tarballName o)} --strip-components=1 \
            -C "$modules"/${lib.escapeShellArg o.name}
          ${lib.optionalString (o.dir != "") ''
            if [ -d ${productionModules}/${lib.escapeShellArg o.dir}/node_modules ]; then
              cp -a ${productionModules}/${lib.escapeShellArg o.dir}/node_modules \
                "$modules"/${lib.escapeShellArg o.name}/node_modules
            fi
          ''}
        '') ownPackages}
        chmod -R u+w "$modules"
        ${lib.optionalString (p.bin != { }) ''mkdir -p "$out/bin"''}
        ${lib.concatStrings (
          lib.mapAttrsToList (command: file: ''
            target="$modules"/${lib.escapeShellArg p.name}/${lib.escapeShellArg file}
            chmod +x "$target"
            ln -s "$target" "$out/bin"/${lib.escapeShellArg command}
          '') p.bin
        )}
        runHook postInstall
      '';
      passthru = {
        inherit (p) name dir;
      };
      meta = lib.optionalAttrs (p.bin != { }) {
        mainProgram = builtins.head (builtins.attrNames p.bin);
      };
    };
in
{
  packages = lib.mapAttrs (_: mkPackage) ownPackageSet;
  tests = installed {
    name = "yarn-project-tests";
    scripts = buildScripts ++ testScripts;
    install = "touch $out";
  };
  release = build;
  fetches = lock.entries;
}
