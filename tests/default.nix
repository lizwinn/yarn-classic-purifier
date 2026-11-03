# SPDX-License-Identifier: MIT
#
# The flake's checks. Every one builds in the sandbox; the only network
# access is the fixed-output fetches of locked tarballs and the
# fixed-output relock of conformance-relock.
{
  pkgs,
  # The flake's default package overlay, which adds the yarn wrapper and the
  # yarn-classic-purifier command.
  overlay,
  # The `purifier` namespace of the shared library, from the flake's
  # library.
  purifier,
  # The `yarn-classic-purifier` namespace of the flake's library.
  yarn-classic-purifier,
}:
let
  inherit (pkgs) lib;

  withOverlay = pkgs.extend overlay;
  wrapper = withOverlay.yarn-classic-purifier.yarn;
  command = withOverlay.yarn-classic-purifier.yarn-classic-purifier;

  # Every fixture builds the way a consumer's package does: through
  # `buildYarnClassicProject` of a package set that the overlay applies to.
  inherit (withOverlay.yarn-classic-purifier) buildYarnClassicProject;

  # One package with a build script, a test script, a command, a
  # dependency and a dev dependency.
  app = buildYarnClassicProject { src = ./fixtures/app; };

  # A root that declares workspaces, a library workspace with a scoped
  # name and a command-line workspace that depends on it. The root's
  # postinstall script runs the command of its dev dependency semver, whose
  # interpreter line is `#!/usr/bin/env node`, so the build only passes
  # when the install patches interpreters before it runs scripts.
  workspaces = buildYarnClassicProject { src = ./fixtures/workspaces; };

  sha256 =
    s:
    builtins.convertHash {
      hash = builtins.hashString "sha256" s;
      hashAlgo = "sha256";
      toHashFormat = "sri";
    };

  # A purifier lockfile with the given packages, for the yarn.lock with the
  # given text, as `yarn-classic-purifier lock` writes it.
  lockFor =
    yarnLockText: packages:
    let
      body = {
        version = 1;
        inputsHash = sha256 yarnLockText;
        inherit packages;
      };
    in
    body // { contentHash = sha256 (builtins.toJSON body); };

  toLockFile = lock: builtins.toFile "yarn-classic-purifier.lock.json" (builtins.toJSON lock);

  # Reads a yarn.lock written inline, with a purifier lockfile that holds
  # the given packages, or with none.
  readLock =
    text: packages:
    import ../nix/lib/lock.nix {
      inherit lib;
      yarnLock = builtins.toFile "yarn.lock" text;
      lockFile = if packages == null then null else toLockFile (lockFor text packages);
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

  # The offline mirror of a project's lockfiles, as
  # `yarn-classic-purifier prefetch` builds it.
  mirrorOf =
    yarnLock: lockFile:
    import ../nix/lib/interactive.nix {
      inherit
        pkgs
        purifier
        yarnLock
        lockFile
        ;
    };
  appMirror = mirrorOf ./fixtures/app/yarn.lock null;

  # Builds the git-prepare project, whose git dependency is the directory
  # `repository`, and runs its command. `extra` adds fields to the
  # dependency's entry in the purifier lockfile.
  gitPrepareCheck =
    name: repository: extra:
    let
      project = buildYarnClassicProject {
        src = ./fixtures/git-prepare/project;
        lockFile = toLockFile (
          lockFor (builtins.readFile ./fixtures/git-prepare/project/yarn.lock) [
            (
              {
                resolved = "git+https://git.example.invalid/prepared-dependency.git#0123456789abcdef0123456789abcdef01234567";
                hash = lib.fakeHash;
                prepare = true;
                downloads =
                  (import ../nix/lib/lock.nix {
                    inherit lib;
                    yarnLock = ./fixtures/git-prepare/repository/yarn.lock;
                  }).downloads;
              }
              // extra
            )
          ]
        );
        fetchers.fetchgit = _: repository;
      };
    in
    pkgs.runCommand name { nativeBuildInputs = [ project.packages.uses-prepared-dependency ]; } ''
      uses-prepared-dependency | grep -qx 'prepared with semver output 2.0.0'
      touch $out
    '';

  # The remote fixture's purifier lockfile, and whether reading the remote
  # fixture's yarn.lock with another purifier lockfile fails evaluation.
  remoteYarnLock = builtins.readFile ./fixtures/remote/yarn.lock;
  remoteLock = lib.importJSON ./fixtures/remote/yarn-classic-purifier.lock.json;
  # A lock in memory is unusable when it has problems, and each problem
  # names the command that fixes it.
  namesTheFix =
    problems:
    problems != [ ] && builtins.all (lib.hasInfix "Run `yarn-classic-purifier lock`") problems;
  lockFails =
    lock:
    namesTheFix
      (yarn-classic-purifier.readLock {
        src = ./fixtures/remote;
        lockFile = toLockFile lock;
      }).problems;
in
{
  composition-producer = workspaces.packages."@fixture/greet";
  npm-projection =
    pkgs.runCommand "yarn-classic-npm-projection"
      {
        nativeBuildInputs = [
          pkgs.nodejs
          pkgs.python3
        ];
      }
      ''
        export HOME="$TMPDIR/home"
        mkdir -p "$HOME"
        python ${./npm-projection.py} ${workspaces.packages."@fixture/greet".projections.npm} \
          ${workspaces.packages."@fixture/greet".projections.npm.catalog} ${pkgs.nodejs}/bin
        touch "$out"
      '';

  # A purifier lockfile written for another yarn.lock fails evaluation,
  # naming `yarn-classic-purifier lock`.
  conformance-stale = evalCheck "conformance-stale" (lockFails (
    lockFor "# another yarn.lock\n" remoteLock.packages
  )) "a purifier lockfile for another yarn.lock evaluated";

  # A purifier lockfile whose content changed after the lock command wrote
  # it, here the hash of one package, fails evaluation.
  conformance-tampered = evalCheck "conformance-tampered" (
    !(lockFails remoteLock)
    && lockFails (
      remoteLock
      // {
        packages = map (p: p // { hash = lib.fakeHash; }) remoteLock.packages;
      }
    )
  ) "a purifier lockfile with a changed hash evaluated, or the committed one did not";

  # A project whose git dependency the purifier lockfile does not record
  # fails evaluation, naming `yarn-classic-purifier lock`.
  conformance-missing =
    let
      result =
        builtins.tryEval
          (buildYarnClassicProject {
            src = ./fixtures/remote;
            lockFile = null;
          }).release.drvPath;
    in
    evalCheck "conformance-missing" (
      !result.success
      &&
        namesTheFix
          (yarn-classic-purifier.readLock {
            src = ./fixtures/remote;
            lockFile = null;
          }).problems
    ) "a project with an unrecorded git dependency evaluated";

  # The lock in memory has the shape of the purifier contract, and the
  # remote fixture's names its package and its locked entries.
  read-lock =
    let
      lock = purifier.checkLock (yarn-classic-purifier.readLock { src = ./fixtures/remote; });
    in
    evalCheck "read-lock" (
      lock.purifier == "yarn-classic-purifier"
      && builtins.attrNames lock.outputs == [ "remote-dependencies" ]
      && builtins.length lock.entries == 3
    ) "the lock in memory of the remote fixture is ${builtins.toJSON (map (e: e.path) lock.entries)}";

  # Malformed purifier lockfiles fail evaluation, naming
  # `yarn-classic-purifier lock`: one that holds no object, one without its
  # contentHash, one of another version, one without its packages, and one
  # with a package without a hash.
  conformance-malformed =
    let
      relabel =
        lock:
        lockFor remoteYarnLock [ ]
        // removeAttrs lock [ "contentHash" ]
        // {
          contentHash = sha256 (builtins.toJSON (removeAttrs lock [ "contentHash" ]));
        };
    in
    evalCheck "conformance-malformed" (
      lockFails [ ]
      && lockFails (removeAttrs remoteLock [ "contentHash" ])
      && lockFails (relabel (remoteLock // { version = 2; }))
      && lockFails (relabel (removeAttrs remoteLock [ "packages" ]))
      && lockFails (
        lockFor remoteYarnLock [
          {
            resolved = "git+https://github.com/stevemao/left-pad.git#ff8e7ba8b4122829cf66125ca8445cac7f073bce";
            prepare = false;
          }
        ]
      )
    ) "a malformed purifier lockfile evaluated";

  # `yarn-classic-purifier lock` of the relock fixture reproduces its
  # committed purifier lockfile byte for byte. The lock run needs the
  # network, so the check is a fixed-output build with an empty output.
  # Nix builds a fixed-output derivation once per name, so the name
  # carries a digest of the command and the fixture, and the check runs
  # again when either changes.
  conformance-relock =
    let
      digest = builtins.hashString "sha256" (
        lib.concatMapStrings builtins.readFile [
          ../pkgs/yarn-classic-purifier/default.nix
          ../nix/lib/lock.nix
          ./fixtures/relock/package.json
          ./fixtures/relock/yarn.lock
          ./fixtures/relock/yarn-classic-purifier.lock.json
        ]
      );
    in
    pkgs.runCommand "conformance-relock-${builtins.substring 0 16 digest}"
      {
        nativeBuildInputs = [
          command
          pkgs.nix
          pkgs.cacert
        ];
        outputHashMode = "flat";
        outputHashAlgo = "sha256";
        outputHash = builtins.hashString "sha256" "";
      }
      ''
        export HOME="$TMPDIR/home"
        mkdir -p "$HOME"
        export SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
        # The lock command evaluates the lockfile reader, which reads files
        # and builds nothing.
        export NIX_CONFIG=$'experimental-features = nix-command\nstore = dummy://'
        cp -r ${./fixtures/relock} project
        chmod -R u+w project
        rm project/yarn-classic-purifier.lock.json
        cd project
        yarn-classic-purifier lock
        if ! cmp yarn-classic-purifier.lock.json ${./fixtures/relock/yarn-classic-purifier.lock.json}; then
          diff ${./fixtures/relock/yarn-classic-purifier.lock.json} yarn-classic-purifier.lock.json >&2
          exit 1
        fi
        cd ..
        # With both lockfiles outside the project, lock starts the tool
        # lockfile from the project's own yarn.lock, writes both outside,
        # and leaves the project as it is.
        cp -r ${./fixtures/relock} external
        chmod -R u+w external
        rm external/yarn-classic-purifier.lock.json
        cd external
        yarn-classic-purifier lock --lockfile ../out/lock.json --tool-lockfile ../out/yarn.lock
        cmp ../out/lock.json ${./fixtures/relock/yarn-classic-purifier.lock.json}
        cmp ../out/yarn.lock ${./fixtures/relock/yarn.lock}
        cmp yarn.lock ${./fixtures/relock/yarn.lock}
        test ! -e yarn-classic-purifier.lock.json
        touch $out
      '';

  # `yarn-classic-purifier update` of the update fixture, which pins kleur
  # 4.0.0 within the range ^4.0.0, moves kleur past 4.0.0 in yarn.lock and
  # relocks the purifier lockfile against it, so that reading both
  # lockfiles reports no problem. The update needs the network, so the
  # check is a fixed-output build with an empty output, named after a
  # digest of the command and the fixture.
  conformance-update =
    let
      digest = builtins.hashString "sha256" (
        lib.concatMapStrings builtins.readFile [
          ../pkgs/yarn-classic-purifier/default.nix
          ../nix/lib/lock.nix
          ../nix/lib/read-lock.nix
          ./fixtures/update/package.json
          ./fixtures/update/yarn.lock
          ./fixtures/update/yarn-classic-purifier.lock.json
        ]
      );
    in
    pkgs.runCommand "conformance-update-${builtins.substring 0 16 digest}"
      {
        nativeBuildInputs = [
          command
          pkgs.nix
          pkgs.cacert
        ];
        outputHashMode = "flat";
        outputHashAlgo = "sha256";
        outputHash = builtins.hashString "sha256" "";
      }
      ''
        export HOME="$TMPDIR/home"
        mkdir -p "$HOME"
        export SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
        export NIX_CONFIG=$'experimental-features = nix-command\nstore = dummy://'
        cp -r ${./fixtures/update} project
        chmod -R u+w project
        cd project
        yarn-classic-purifier update
        if grep -q 'kleur-4.0.0.tgz' yarn.lock; then
          echo "the update left kleur at 4.0.0" >&2
          exit 1
        fi
        problems="$(nix eval --impure --json --expr '
          (import ${../nix/lib}/read-lock.nix { lib = import ${pkgs.path}/lib; } {
            src = /. + builtins.getEnv "PWD";
          }).problems
        ')"
        if [ "$problems" != "[]" ]; then
          echo "the updated lockfiles have problems: $problems" >&2
          exit 1
        fi
        touch $out
      '';

  # The installed package of the app fixture. CI builds it a second time
  # with `nix build --rebuild`, which fails when the output differs.
  conformance-rebuild = app.packages.hello-yarn;

  # After `yarn-classic-purifier prefetch`, the development loop works with no
  # network. The sandbox has none; the project gets the state prefetch
  # leaves, from the same derivation, and the yarn wrapper installs and
  # builds the app fixture from it without running Nix.
  conformance-offline = pkgs.runCommand "conformance-offline" { nativeBuildInputs = [ wrapper ]; } ''
    export HOME="$TMPDIR/home"
    mkdir -p "$HOME"
    cp -r ${./fixtures/app} project
    chmod -R u+w project
    cd project
    mkdir .yarn-classic-purifier
    ln -s ${appMirror} .yarn-classic-purifier/mirror
    cat yarn.lock | sha256sum | cut -d' ' -f1 > .yarn-classic-purifier/lock.sha256
    yarn install --frozen-lockfile
    yarn run build
    yarn run test
    touch $out
  '';

  # A fixture whose source holds the build tool's own files, including
  # yarn.lock, and no purifier lockfile builds from a purifier lockfile
  # kept outside it, as a packaging flake does. A fixture whose own
  # yarn.lock is stale also builds, with the yarn.lock that the caller
  # passes in its place.
  conformance-external =
    let
      project = buildYarnClassicProject {
        src = lib.cleanSourceWith {
          src = ./fixtures/remote;
          filter = path: _: baseNameOf path != "yarn-classic-purifier.lock.json";
        };
        lockFile = ./fixtures/remote/yarn-classic-purifier.lock.json;
      };
      replaced = buildYarnClassicProject {
        src = ./fixtures/external-stale;
        yarnLock = ./fixtures/remote/yarn.lock;
        lockFile = ./fixtures/remote/yarn-classic-purifier.lock.json;
      };
    in
    pkgs.runCommand "conformance-external"
      {
        nativeBuildInputs = [
          project.packages.remote-dependencies
          replaced.packages.remote-dependencies
        ];
      }
      ''
        remote-dependencies | grep -qx '..git ..tarball'
        touch $out
      '';

  # A project whose source holds no lockfiles at all builds from a yarn.lock
  # and a purifier lockfile kept outside it.
  external-yarn-lock =
    let
      project = buildYarnClassicProject {
        src = lib.cleanSourceWith {
          src = ./fixtures/remote;
          filter =
            path: _:
            !(builtins.elem (baseNameOf path) [
              "yarn.lock"
              "yarn-classic-purifier.lock.json"
            ]);
        };
        yarnLock = ./fixtures/remote/yarn.lock;
        lockFile = ./fixtures/remote/yarn-classic-purifier.lock.json;
      };
    in
    pkgs.runCommand "external-yarn-lock-check"
      { nativeBuildInputs = [ project.packages.remote-dependencies ]; }
      ''
        remote-dependencies | grep -qx '..git ..tarball'
        touch $out
      '';

  # A purifier lockfile that is not JSON at all cannot become a problem,
  # because Nix cannot catch a parse error. Reading it fails evaluation with
  # an error context that names the command, and the commands check the
  # file before Nix reads it.
  conformance-malformed-json =
    pkgs.runCommand "conformance-malformed-json"
      {
        nativeBuildInputs = [
          command
          pkgs.nix
        ];
      }
      ''
        export HOME="$TMPDIR/home"
        mkdir -p "$HOME"
        export NIX_CONFIG=$'experimental-features = nix-command\nstore = dummy://'
        cp -r ${./fixtures/remote} project
        chmod -R u+w project
        cd project
        echo 'this is not JSON' > yarn-classic-purifier.lock.json
        if yarn-classic-purifier prefetch 2> prefetch.log; then
          echo "prefetch accepted a lockfile that is not JSON" >&2
          exit 1
        fi
        grep -q 'is not valid JSON. Run `yarn-classic-purifier lock`' prefetch.log
        if nix eval --impure --expr '
          (import ${../nix/lib}/read-lock.nix { lib = import ${pkgs.path}/lib; } {
            src = /. + builtins.getEnv "PWD";
          }).problems
        ' 2> eval.log; then
          echo "readLock accepted a lockfile that is not JSON" >&2
          exit 1
        fi
        grep -q 'is not valid JSON. Run `yarn-classic-purifier lock`' eval.log
        touch $out
      '';

  # The URL each git dependency is cloned from: the ssh URL of a public
  # forge becomes its https URL, an scp-style address becomes an ssh URL,
  # and every other URL stays as yarn.lock has it.
  git-urls =
    let
      rev = "0123456789abcdef0123456789abcdef01234567";
      resolved = [
        "git+ssh://git@github.com/owner/a.git#${rev}"
        "git+ssh://git@gitlab.com/group/b.git#${rev}"
        "git+ssh://git@git.example.com/c.git#${rev}"
        "git@git.example.com:org/d.git#${rev}"
        "git+https://codeberg.org/owner/e.git#${rev}"
      ];
      lock =
        readLock
          (lib.concatImapStrings (i: r: ''
            p${toString i}@${r}:
              version "1.0.0"
              resolved "${r}"

          '') resolved)
          (
            map (r: {
              resolved = r;
              hash = lib.fakeHash;
              prepare = false;
            }) resolved
          );
    in
    evalCheck "git-urls" (
      lib.sort lib.lessThan (map (d: d.git.url) lock.downloads) == [
        "https://codeberg.org/owner/e.git"
        "https://github.com/owner/a.git"
        "https://gitlab.com/group/b.git"
        "ssh://git@git.example.com/c.git"
        "ssh://git@git.example.com/org/d.git"
      ]
    ) "the git dependencies clone from other URLs";

  # The install fails when a tarball in the offline mirror differs from the
  # locked one. Yarn compares each tarball with the integrity in yarn.lock,
  # discards the one that differs, and tries to download it, which the
  # offline install refuses.
  tampered-file = pkgs.runCommand "tampered-file-check" { nativeBuildInputs = [ pkgs.yarn ]; } ''
    export HOME="$TMPDIR/home" YARN_CACHE_FOLDER="$TMPDIR/yarn-cache"
    export YARN_YARN_OFFLINE_MIRROR="$PWD/mirror"
    mkdir -p "$HOME"
    cp -rL ${appMirror} mirror
    chmod -R u+w mirror
    set -- $(find mirror -name '*.tgz' | sort)
    cp "$2" "$1"
    tampered="$(basename "$1")"
    cp -r ${./fixtures/app} project
    chmod -R u+w project
    cd project
    if yarn install --offline --frozen-lockfile --ignore-scripts > "$TMPDIR/install.log" 2>&1; then
      echo "the install succeeded" >&2
      exit 1
    fi
    if ! grep "in offline mode" "$TMPDIR/install.log" | grep -qF "/$tampered"; then
      cat "$TMPDIR/install.log" >&2
      exit 1
    fi
    touch $out
  '';

  # The package's command prints what its build script wrote, its dev
  # dependency stays out of the installed package, and the release holds
  # the built file.
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
        tar -xzOf ${app.release}/hello-yarn.tgz package/dist/message.js \
          | grep -q 'built by the build script'
        touch $out
      '';

  # The app fixture's test script passes in the sandbox.
  app-tests = app.tests;

  # The fetched entries are the purifier library entries of the app
  # fixture's yarn.lock.
  fetches = evalCheck "fetches" (
    map (e: e.path) app.fetches == map (e: e.path)
      (import ../nix/lib/lock.nix {
        inherit lib;
        yarnLock = ./fixtures/app/yarn.lock;
      }).downloads
    && app.fetches != [ ]
  ) "the fetches of the app fixture differ from its yarn.lock";

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
      with' = readLock text [
        {
          inherit resolved;
          hash = integrity;
        }
      ];
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
      with' = readLock text [
        {
          inherit resolved;
          hash = "sha256-T0cZnKaHGTIbJxos2zxdLgcv5JIWx+l0inzHUBZYW1Y=";
          prepare = false;
        }
      ];
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

  # `yarn-classic-purifier publish` uploads the package's tarball from the
  # release, which nix/lib/publish.nix links as package.tgz.
  publish-tarball =
    let
      tarball = import ../nix/lib/publish.nix {
        pkgs = withOverlay;
        src = ./fixtures/app;
        package = "hello-yarn";
      };
    in
    pkgs.runCommand "publish-tarball-check" { } ''
      cmp ${tarball}/package.tgz ${app.release}/hello-yarn.tgz
      touch $out
    '';

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
        yarn publish ${app.release}/hello-yarn.tgz --non-interactive --registry "$registry"
        jq -r '._attachments[].data' "$TMPDIR/body" | base64 -d > uploaded.tgz
        cmp uploaded.tgz ${app.release}/hello-yarn.tgz
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
        # immer's `test` script ends with Flow, and the flow-bin 0.123 that
        # immer pins has no binary for aarch64-linux. There the tests are
        # the other two parts of `test`: the source tests and the tests of
        # the built package.
        testScripts =
          if pkgs.stdenv.hostPlatform.isx86_64 then
            [ "test" ]
          else
            [
              "test:src"
              "test:build"
            ];
      };
    in
    pkgs.runCommand "immer-check"
      {
        nativeBuildInputs = [ pkgs.nodejs ];
        tests = project.tests;
      }
      ''
        NODE_PATH=${project.packages.immer}/lib/node_modules node -e '
          const { produce } = require("immer");
          const next = produce({ a: 1 }, (draft) => { draft.a = 2; });
          if (next.a !== 2) process.exit(1);
        '
        touch $out
      '';

  # The wrapper and the command build.
  yarn = wrapper;
  yarn-classic-purifier = command;
}
