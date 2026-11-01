# SPDX-License-Identifier: MIT
#
# The flake's checks. Every one builds in the sandbox; the only network
# access is the fixed-output fetches of locked tarballs.
{
  pkgs,
  # The flake's default package overlay, which adds buildYarnClassicProject.
  overlay,
  # The `purifier` namespace of the shared library, from the flake's
  # library.
  purifier,
}:
let
  inherit (pkgs) lib;

  # Every fixture builds the way a consumer's package does: through
  # buildYarnClassicProject of a package set the overlay applies to.
  withOverlay = pkgs.extend overlay;
  inherit (withOverlay) buildYarnClassicProject;

  # One package with a build script, a test script, a command, a
  # dependency and a dev dependency.
  app = buildYarnClassicProject {
    src = ./fixtures/app;
    doCheck = true;
  };

  # A root that declares workspaces, a library workspace with a scoped
  # name and a command-line workspace that depends on it. The root's
  # postinstall script runs the command of its dev dependency semver, whose
  # interpreter line is `#!/usr/bin/env node`, so the build only passes
  # when the install patches interpreters before it runs scripts.
  workspaces = buildYarnClassicProject { src = ./fixtures/workspaces; };

  # Reads a yarn.lock written inline.
  readLock =
    text: purifierLock:
    import ../nix/lib/lock.nix {
      inherit lib;
      lockFile = builtins.toFile "yarn.lock" text;
      purifierLockFile =
        if purifierLock == null then
          null
        else
          builtins.toFile "yarn-classic-purifier.lock.json" (builtins.toJSON purifierLock);
    };

  # A lockfile check passes when `assertion` holds; it fails with
  # `message` otherwise.
  evalCheck =
    name: assertion: message:
    if assertion then
      pkgs.runCommand name { } "touch $out"
    else
      throw "yarn-classic-purifier check ${name}: ${message}";

  integrity = "sha512-dKlgKLTrnih8yfGKBozBsVcGe0mS1/aKhCGPevK47XUNBMB+L0qk6zFw3YQnOFqH8dWqP9KNw9V+g1oOw4ew2g==";

  # Builds the git-prepare project, whose git dependency is the directory
  # `repository`, and runs its command. `extra` adds fields to the
  # dependency's entry in the purifier lockfile.
  gitPrepareCheck =
    name: repository: extra:
    let
      purifierLock = builtins.toFile "yarn-classic-purifier.lock.json" (
        builtins.toJSON {
          format = 1;
          packages = [
            (
              {
                resolved = "git+https://git.example.invalid/prepared-dependency.git#0123456789abcdef0123456789abcdef01234567";
                hash = lib.fakeHash;
                prepare = true;
                downloads =
                  (import ../nix/lib/lock.nix {
                    inherit lib;
                    lockFile = ./fixtures/git-prepare/repository/yarn.lock;
                  }).downloads;
              }
              // extra
            )
          ];
        }
      );
      project = buildYarnClassicProject {
        src = ./fixtures/git-prepare/project;
        purifierLockFile = purifierLock;
        fetchgit = _: repository;
      };
    in
    pkgs.runCommand name { nativeBuildInputs = [ project.packages.uses-prepared-dependency ]; } ''
      uses-prepared-dependency | grep -qx 'prepared with semver output 2.0.0'
      touch $out
    '';
in
{
  # The package's command prints what its build script wrote, and its dev
  # dependency stays out of the installed package.
  app =
    pkgs.runCommand "app-check"
      {
        nativeBuildInputs = [ app.packages.hello-yarn ];
      }
      ''
        hello-yarn | grep -q 'hello-yarn: built by the build script (3 is odd: true)'
        if [ -e ${app.packages.hello-yarn}/lib/node_modules/is-odd ]; then
          echo "the dev dependency is-odd is installed" >&2
          exit 1
        fi
        tar -xzOf ${app.packages.hello-yarn.tarball}/package.tgz package/dist/message.js \
          | grep -q 'built by the build script'
        touch $out
      '';

  # The command-line workspace finds the library workspace; the library
  # installs on its own.
  workspaces =
    pkgs.runCommand "workspaces-check"
      {
        nativeBuildInputs = [
          workspaces.packages.fixture-app
          pkgs.nodejs
        ];
      }
      ''
        fixture-app nix | grep -qx 'hello Nix'
        NODE_PATH=${
          workspaces.packages."@fixture/greet"
        }/lib/node_modules node -e 'console.log(require("@fixture/greet")("you"))' \
          | grep -qx 'hello You'
        touch $out
      '';

  # A workspace root without commands is no package of its own.
  workspaces-root = evalCheck "workspaces-root" (
    !(workspaces.packages ? classic-fixture)
  ) "the workspace root is a package";

  # Yarn names a scoped registry tarball <scope>-<file> in its offline
  # mirror, also when the scope's slash is encoded, and any other tarball
  # after the last segment of its path.
  mirror-names =
    let
      lock = readLock ''
        # yarn lockfile v1


        "@babel/code-frame@^7.0.0":
          version "7.0.0"
          resolved "https://registry.yarnpkg.com/@babel/code-frame/-/code-frame-7.0.0.tgz#06e2ab19bdb535385559aabb5ba59729482800f8"
          integrity ${integrity}

        "@scope/encoded@^1.0.0":
          version "1.0.0"
          resolved "https://registry.example.com/@scope%2fencoded/-/encoded-1.0.0.tgz"
          integrity ${integrity}

        lodash@^4.0.0:
          version "4.17.21"
          resolved "https://registry.yarnpkg.com/lodash/-/lodash-4.17.21.tgz#679591c564c3bffaae8454cf0b3df370c3d6911c"
          integrity ${integrity}

        "other@https://example.com/files/other.tgz?token=1":
          version "1.0.0"
          resolved "https://example.com/files/other.tgz?token=1"
          integrity ${integrity}
      '' null;
    in
    evalCheck "mirror-names" (
      lib.sort (a: b: a < b) (map (d: d.path) lock.downloads) == [
        "@babel-code-frame-7.0.0.tgz"
        "@scope-encoded-1.0.0.tgz"
        "lodash-4.17.21.tgz"
        "other.tgz"
      ]
    ) "the mirror names are ${builtins.toJSON (map (d: d.path) lock.downloads)}";

  # A tarball from Yarn's registry has the same path on npm's registry as
  # its mirror, and the other way round.
  registry-mirrors =
    let
      lock = readLock ''
        lodash@^4.0.0:
          version "4.17.21"
          resolved "https://registry.yarnpkg.com/lodash/-/lodash-4.17.21.tgz"
          integrity ${integrity}

        "@babel/code-frame@^7.0.0":
          version "7.0.0"
          resolved "https://registry.npmjs.org/@babel/code-frame/-/code-frame-7.0.0.tgz"
          integrity ${integrity}
      '' null;
      mirrorsOf = path: (lib.findFirst (d: d.path == path) null lock.downloads).mirrors;
    in
    evalCheck "registry-mirrors" (
      mirrorsOf "lodash-4.17.21.tgz" == [ "https://registry.npmjs.org/lodash/-/lodash-4.17.21.tgz" ]
      &&
        mirrorsOf "@babel-code-frame-7.0.0.tgz" == [
          "https://registry.yarnpkg.com/@babel/code-frame/-/code-frame-7.0.0.tgz"
        ]
    ) "the registry tarballs have the mirrors ${builtins.toJSON (map (d: d.mirrors) lock.downloads)}";

  # An entry without an integrity takes the SHA-1 in the fragment of its
  # `resolved`, which older versions of Yarn Classic wrote.
  sha1-fragment =
    let
      lock = readLock ''
        lodash@^4.0.0:
          version "4.17.21"
          resolved "https://registry.yarnpkg.com/lodash/-/lodash-4.17.21.tgz#679591c564c3bffaae8454cf0b3df370c3d6911c"
      '' null;
    in
    evalCheck "sha1-fragment" (
      (builtins.head lock.downloads).hash == "sha1-Z5WRxWTDv/quhFTPCz3zcMPWkRw="
    ) "the hash is ${(builtins.head lock.downloads).hash}";

  # A tarball without a hash in yarn.lock is missing until the purifier
  # lockfile records it.
  purifier-lock =
    let
      text = ''
        "left-pad@https://codeload.github.com/left-pad/left-pad/tar.gz/2fca6157f8ea5d1c3a0b3e8d2a1c5c3e5d6e7f80":
          version "1.3.0"
          resolved "https://codeload.github.com/left-pad/left-pad/tar.gz/2fca6157f8ea5d1c3a0b3e8d2a1c5c3e5d6e7f80"
      '';
      resolved = "https://codeload.github.com/left-pad/left-pad/tar.gz/2fca6157f8ea5d1c3a0b3e8d2a1c5c3e5d6e7f80";
      without = readLock text null;
      with' = readLock text {
        format = 1;
        packages = [
          {
            inherit resolved;
            url = resolved;
            hash = integrity;
          }
        ];
      };
    in
    evalCheck "purifier-lock" (
      without.missing == [
        {
          inherit resolved;
          url = resolved;
        }
      ]
      && without.downloads == [ ]
      && with'.missing == [ ]
      &&
        with'.downloads == [
          {
            path = "2fca6157f8ea5d1c3a0b3e8d2a1c5c3e5d6e7f80";
            url = resolved;
            mirrors = [ ];
            hash = integrity;
          }
        ]
    ) "the purifier lockfile does not supply the missing hash";

  # A git dependency is missing until the purifier lockfile records it. Its
  # entry fetches the https URL of a forge's ssh address, and its mirror
  # name is the repository's last path segment and the commit.
  git-dependency =
    let
      text = ''
        "left-pad@git+ssh://git@github.com/left-pad/left-pad.git#2fca6157f8ea5d1c3a0b3e8d2a1c5c3e5d6e7f80":
          version "1.3.0"
          resolved "git+ssh://git@github.com/left-pad/left-pad.git#2fca6157f8ea5d1c3a0b3e8d2a1c5c3e5d6e7f80"
      '';
      resolved = "git+ssh://git@github.com/left-pad/left-pad.git#2fca6157f8ea5d1c3a0b3e8d2a1c5c3e5d6e7f80";
      git = {
        url = "https://github.com/left-pad/left-pad.git";
        rev = "2fca6157f8ea5d1c3a0b3e8d2a1c5c3e5d6e7f80";
      };
      without = readLock text null;
      with' = readLock text {
        format = 1;
        packages = [
          {
            inherit resolved;
            hash = "sha256-T0cZnKaHGTIbJxos2zxdLgcv5JIWx+l0inzHUBZYW1Y=";
            prepare = false;
          }
        ];
      };
    in
    evalCheck "git-dependency"
      (
        without.missing == [ { inherit resolved git; } ]
        &&
          with'.downloads == [
            {
              path = "left-pad.git-2fca6157f8ea5d1c3a0b3e8d2a1c5c3e5d6e7f80";
              git = git // {
                submodules = false;
                leaveDotGit = false;
                commitObject = null;
              };
              hash = "sha256-T0cZnKaHGTIbJxos2zxdLgcv5JIWx+l0inzHUBZYW1Y=";
              prepare = false;
            }
          ]
      )
      "the git dependency reads as ${builtins.toJSON without.missing} and ${builtins.toJSON with'.downloads}";

  # A git dependency whose repository has a prepare script: Yarn installs
  # the repository with its devDependencies, runs the script and packs the
  # result. Here the repository is the fixture directory, which `fetchgit`
  # returns in place of a clone, and the purifier lockfile carries the
  # mirror of its yarn.lock, as `yarn-classic-purifier lock` writes it. The
  # prepare script runs the command of the devDependency semver.
  git-prepare = gitPrepareCheck "git-prepare" ./fixtures/git-prepare/repository { };

  # The same repository without its own yarn.lock: the purifier lockfile
  # carries the yarn.lock that the lock command resolved for it.
  git-prepare-generated-lock = gitPrepareCheck "git-prepare-generated-lock" (lib.cleanSourceWith {
    src = ./fixtures/git-prepare/repository;
    filter = path: _: baseNameOf path != "yarn.lock";
  }) { yarnLock = builtins.readFile ./fixtures/git-prepare/repository/yarn.lock; };

  # The wrapper evaluates nix/lib/interactive.nix for a project; the mirror
  # it builds is the one the sandboxed build of the project uses.
  interactive =
    let
      mirror = import ../nix/lib/interactive.nix {
        inherit purifier;
        inherit pkgs;
        lockFile = ./fixtures/app/yarn.lock;
      };
    in
    evalCheck "interactive" (
      mirror.outPath == app.dependencies.outPath
    ) "the mirror the wrapper builds differs from the mirror the build uses";

  # A git dependency and a GitHub dependency, which Yarn fetches from
  # codeload.github.com, with the purifier lockfile that
  # `yarn-classic-purifier lock` wrote for them.
  remote =
    let
      project = buildYarnClassicProject { src = ./fixtures/remote; };
    in
    pkgs.runCommand "remote-check" { nativeBuildInputs = [ project.packages.remote-dependencies ]; } ''
      remote-dependencies | grep -qx '..git ..tarball'
      touch $out
    '';

  # A `file:` directory, a `link:` and a `file:` tarball come from the
  # project source, and the installed package holds copies of all three.
  local-paths =
    let
      project = buildYarnClassicProject { src = ./fixtures/local-paths; };
    in
    pkgs.runCommand "local-paths-check" { nativeBuildInputs = [ project.packages.local-paths ]; } ''
      local-paths | grep -qx 'directory link tarball'
      touch $out
    '';

  # `yarn-classic-purifier publish` builds the tarball nix/lib/publish.nix
  # names, which is the package's tarball output.
  publish-tarball =
    let
      tarball = import ../nix/lib/publish.nix {
        inherit purifier;
        pkgs = withOverlay;
        src = ./fixtures/app;
        package = "hello-yarn";
      };
    in
    evalCheck "publish-tarball" (
      tarball.outPath == (buildYarnClassicProject { src = ./fixtures/app; })
      .packages.hello-yarn.tarball.outPath
    ) "the tarball the publish command builds differs from the package's tarball";

  # `yarn publish` of that tarball, as the publish command runs it, uploads
  # the tarball byte for byte. The registry is a local server.
  publish =
    pkgs.runCommand "publish-check"
      {
        nativeBuildInputs = [
          pkgs.yarn
          pkgs.nodejs
          pkgs.jq
        ];
      }
      ''
        export HOME="$TMPDIR/home"
        mkdir -p "$HOME"
        node ${./registry.js} "$TMPDIR/port" "$TMPDIR/body" &
        while [ ! -s "$TMPDIR/port" ]; do sleep 0.1; done
        registry="http://127.0.0.1:$(cat "$TMPDIR/port")/"
        echo "//127.0.0.1:$(cat "$TMPDIR/port")/:_authToken=token" > "$HOME/.npmrc"
        # The publish command runs Yarn at the project root, whose
        # package.json Yarn reads even when it publishes a tarball.
        cd "$TMPDIR"
        cp ${./fixtures/app/package.json} package.json
        yarn publish ${app.packages.hello-yarn.tarball}/package.tgz --non-interactive --registry "$registry"
        jq -r '._attachments[].data' "$TMPDIR/body" | base64 -d > uploaded.tgz
        cmp uploaded.tgz ${app.packages.hello-yarn.tarball}/package.tgz
        touch $out
      '';

  # A real-world project, pinned: immer, built and tested from its own
  # yarn.lock, with no purifier lockfile. Its tests include Flow, whose
  # package ships a prebuilt Linux binary that the install patches.
  immer =
    let
      project = buildYarnClassicProject {
        src = pkgs.fetchFromGitHub {
          owner = "immerjs";
          repo = "immer";
          rev = "75a290e44ba14bd723c8ef8546b6559c8ef3ae88";
          hash = "sha256-XOeu1biJRgglGW0Zz2cVPt14e4Rh1N2h87wtC6XQLEE=";
        };
        doCheck = true;
      };
    in
    pkgs.runCommand "immer-check"
      {
        nativeBuildInputs = [ pkgs.nodejs ];
      }
      ''
        NODE_PATH=${project.packages.immer}/lib/node_modules node -e '
          const { produce } = require("immer");
          const next = produce({ a: 1 }, (draft) => { draft.a = 2; });
          if (next.a !== 2) process.exit(1);
        '
        touch $out
      '';

  # The wrapper and the lock command build.
  yarn = withOverlay.yarn-classic-purifier.yarn;
  yarn-classic-purifier = withOverlay.yarn-classic-purifier.yarn-classic-purifier;
}
