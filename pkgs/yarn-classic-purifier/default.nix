# SPDX-License-Identifier: MIT
#
# The `yarn-classic-purifier` command.
#
# `yarn-classic-purifier lock` writes yarn-classic-purifier.lock.json at the
# project root. The file records what yarn.lock leaves out: the hash of
# each tarball that yarn.lock gives no hash for, such as a GitHub
# dependency that Yarn fetches from codeload.github.com, and for each git
# dependency the hash of its checkout and whether its repository has a
# `prepare` script. Yarn installs such a repository with its own
# devDependencies before it packs it, so for those the file also records
# the offline mirror of the repository's own yarn.lock, found the same way.
# The file also holds its format `version`, the `inputsHash` of yarn.lock
# and its own `contentHash`. The command reads yarn.lock with the reader a
# build uses (nix/lib/lock.nix), and removes the file when nothing needs it.
#
# `yarn-classic-purifier update [<package>...]` re-resolves the named
# packages, or all of them, with `yarn upgrade`, within the ranges that
# package.json declares, and then writes the purifier lockfile for the new
# yarn.lock as `lock` does. `lock` keeps Yarn's resolution as it is.
#
# `yarn-classic-purifier prefetch` builds the offline mirror of the
# project's lockfiles and keeps it, and the `yarn` wrapper with the
# Node.js, Yarn, node-gyp and Python it runs, alive with garbage-collector
# roots under .yarn-classic-purifier. After it, the `yarn` wrapper works
# with no network.
#
# `yarn-classic-purifier publish <package> [yarn publish options]` builds
# the project's release in the Nix sandbox and publishes the package's
# tarball from it with `yarn publish`.
#
# Every subcommand takes `--lockfile <path>` for a purifier lockfile kept
# elsewhere than the project root, and `--tool-lockfile <path>` for a
# yarn.lock kept elsewhere. The variables YARN_CLASSIC_PURIFIER_LOCKFILE and
# YARN_CLASSIC_PURIFIER_TOOL_LOCKFILE name the same files. With a tool
# lockfile, `lock` and `update` write the yarn.lock there and leave the
# project's own copy as it is, starting from that copy when the tool
# lockfile does not exist yet.
{
  lib,
  purifier,
  writeShellApplication,
  writeShellScript,
  runtimeShell,
  coreutils,
  curl,
  gnutar,
  gzip,
  jq,
  nix-prefetch-git,
  nodejs,
  python3,
  pkgs,
  path,
  stdenv,
  # The offline wrapper of this flake's package scope.
  yarn,
  # Yarn Classic from nixpkgs. Inside this flake's package scope the name
  # `yarn` is the offline wrapper, so the argument has another name.
  yarnClassic ? pkgs.yarn,
}:
let
  scriptShell = writeShellScript "yarn-project-script-shell" ''
    export PATH=${nodejs}/bin:"$PATH"
    export NODE=${nodejs}/bin/node
    export npm_node_execpath=${nodejs}/bin/node
    exec ${runtimeShell} "$@"
  '';
in
writeShellApplication {
  name = "yarn-classic-purifier";
  runtimeInputs = [
    coreutils
    curl
    gnutar
    gzip
    jq
    nix-prefetch-git
    nodejs
  ];
  text = ''
    export YARN_SCRIPT_SHELL=${scriptShell}
    if [ "''${YARN_CLASSIC_PURIFIER_REENTER:-0}" != 1 ]; then
      exec ${python3}/bin/python ${../../tools}/composition.py \
        --mode cli --inner "$0" --native-yarn ${lib.getExe yarnClassic} \
        --flake ${../..} --nixpkgs ${path} --system ${stdenv.hostPlatform.system} \
        --tools ${purifier.projectInputsTool} -- "$@"
    fi

    # A failure inside a command substitution stops the command too.
    shopt -s inherit_errexit

    usage() {
      echo "usage: yarn-classic-purifier lock [--lockfile <path>] [--tool-lockfile <path>]" >&2
      echo "       yarn-classic-purifier update [--lockfile <path>] [--tool-lockfile <path>] [<package>...]" >&2
      echo "       yarn-classic-purifier prefetch [--lockfile <path>] [--tool-lockfile <path>]" >&2
      echo "       yarn-classic-purifier publish [--lockfile <path>] [--tool-lockfile <path>] <package> [yarn publish options]" >&2
      exit 2
    }
    [ "$#" -ge 1 ] || usage
    subcommand="$1"
    shift

    # The purifier lockfile is the flag --lockfile, else the variable
    # YARN_CLASSIC_PURIFIER_LOCKFILE, else the file beside yarn.lock. The
    # yarn.lock that the commands read and write is the flag
    # --tool-lockfile, else YARN_CLASSIC_PURIFIER_TOOL_LOCKFILE, else the
    # project's own.
    lockfileGiven="''${YARN_CLASSIC_PURIFIER_LOCKFILE:-}"
    toolLockGiven="''${YARN_CLASSIC_PURIFIER_TOOL_LOCKFILE:-}"
    while [ "$#" -ge 1 ]; do
      case "$1" in
        --lockfile)
          [ "$#" -ge 2 ] || usage
          lockfileGiven="$2"
          shift 2
          ;;
        --tool-lockfile)
          [ "$#" -ge 2 ] || usage
          toolLockGiven="$2"
          shift 2
          ;;
        *) break ;;
      esac
    done

    # The project root: the nearest directory upwards with a yarn.lock. A
    # tool lockfile that exists takes the place of the project's own
    # yarn.lock, so the project root is then the nearest directory with a
    # package.json.
    dir="$PWD"
    if [ -n "$toolLockGiven" ] && [ -f "$toolLockGiven" ]; then
      while [ ! -f "$dir/package.json" ] && [ "$dir" != / ]; do
        dir="$(dirname "$dir")"
      done
    else
      while [ ! -f "$dir/yarn.lock" ]; do
        if [ "$dir" = / ]; then
          if [ "$subcommand" = lock ] && [ -f "$PWD/package.json" ]; then
            # A project without a yarn.lock gets the one Yarn writes. The
            # lock command otherwise keeps Yarn's resolution as it is.
            echo "yarn-classic-purifier: no yarn.lock in $PWD or above it; running yarn install to write one" >&2
            (cd "$PWD" && ${lib.getExe yarnClassic} install --ignore-scripts --non-interactive --silent)
            dir="$PWD"
            break
          fi
          echo "yarn-classic-purifier: no yarn.lock in $PWD or above it. Run \`yarn-classic-purifier lock\` in a directory with a package.json to write one." >&2
          exit 1
        fi
        dir="$(dirname "$dir")"
      done
    fi
    out="$(realpath -m "''${lockfileGiven:-$dir/yarn-classic-purifier.lock.json}")"
    toolLock="$(realpath -m "''${toolLockGiven:-$dir/yarn.lock}")"
    pkgs='import ${path} { system = "${stdenv.hostPlatform.system}"; }'

    ${import ../../nix/lib/mirror-script.nix {
      flake = ../..;
      nixpkgs = path;
      node = nodejs;
      yarn = yarnClassic;
      inherit (stdenv.hostPlatform) system;
    }}

    # Prints attribute $2 of what nix/lib/lock.nix reads from yarn.lock $1,
    # with purifier lockfile $3 when it is given.
    readLock() {
      local purifier=null
      if [ -n "''${3:-}" ]; then
        purifier='/. + builtins.getEnv "YARN_CLASSIC_PURIFIER_PURIFIER_LOCK"'
      fi
      YARN_CLASSIC_PURIFIER_LOCK="$1" YARN_CLASSIC_PURIFIER_PURIFIER_LOCK="''${3:-}" \
        nix eval --impure --json --expr "
          (import ${../../nix/lib}/lock.nix {
            inherit ($pkgs) lib;
            yarnLock = /. + builtins.getEnv \"YARN_CLASSIC_PURIFIER_LOCK\";
            lockFile = $purifier;
          }).$2
        "
    }

    # Prints the SRI hash with algorithm $1 of standard input.
    sri() {
      node -e '
        const crypto = require("crypto");
        const fs = require("fs");
        const algorithm = process.argv[1];
        process.stdout.write(algorithm + "-" + crypto.createHash(algorithm).update(fs.readFileSync(0)).digest("base64"));
      ' "$1"
    }

    # Writes the purifier lockfile $3 for yarn.lock $1 with the packages $2,
    # a JSON list. `contentHash` is the SHA-256 of the file's JSON without
    # it, with keys sorted and no whitespace, as nix/lib/lock.nix computes
    # it.
    writeLock() {
      local body
      body="$(jq -n --argjson packages "$2" --arg inputsHash "$(sri sha256 < "$1")" \
        --argjson projectInputs "''${YARN_CLASSIC_PURIFIER_PROJECT_INPUTS:-[]}" \
        '{ version: 1, inputsHash: $inputsHash, packages: $packages } + (if $projectInputs == [] then {} else {projectInputs: $projectInputs} end)')"
      jq --arg contentHash "$(jq -cjS . <<< "$body" | sri sha256)" \
        '. + { contentHash: $contentHash }' <<< "$body" > "$3"
    }

    # Prints the SRI SHA-512 of the file at URL $1.
    hashUrl() {
      curl --fail --silent --show-error --location "$1" | sri sha512
    }

    # Prints the purifier lockfile entries for what the yarn.lock at path $1
    # leaves out, as a JSON list.
    entriesFor() {
      local missing entries m resolved prefetch hash checkout nested nestedLock downloads generated work
      missing="$(readLock "$1" missing)"
      entries="[]"
      while IFS= read -r m; do
        resolved="$(jq -r .resolved <<< "$m")"
        if jq -e 'has("git")' <<< "$m" > /dev/null; then
          echo "yarn-classic-purifier: fetching $resolved" >&2
          prefetch="$(nix-prefetch-git --quiet --url "$(jq -r .git.url <<< "$m")" --rev "$(jq -r .git.rev <<< "$m")")"
          hash="$(jq -r .hash <<< "$prefetch")"
          checkout="$(jq -r .path <<< "$prefetch")"
          if [ -f "$checkout/package.json" ] && jq -e '.scripts.prepare' "$checkout/package.json" > /dev/null; then
            # A repository without a yarn.lock gets one here, resolved once:
            # without it, Yarn resolves the repository's dependencies afresh
            # at every install. The entry records the lockfile's text, and a
            # build writes it into the checkout.
            generated=
            if [ ! -f "$checkout/yarn.lock" ]; then
              echo "yarn-classic-purifier: resolving the dependencies of $resolved, which has no yarn.lock" >&2
              work="$(mktemp -d)"
              cp -r --no-preserve=mode "$checkout/." "$work"
              (cd "$work" && ${lib.getExe yarnClassic} install --ignore-scripts --non-interactive --silent > /dev/null)
              checkout="$work"
              generated="$(cat "$work/yarn.lock")"
            fi
            nested="$(entriesFor "$checkout/yarn.lock")"
            nestedLock="$(mktemp)"
            writeLock "$checkout/yarn.lock" "$nested" "$nestedLock"
            downloads="$(readLock "$checkout/yarn.lock" downloads "$nestedLock")"
            rm "$nestedLock"
            if [ -n "$generated" ]; then
              entries="$(jq --arg resolved "$resolved" --arg hash "$hash" --argjson downloads "$downloads" \
                --arg yarnLock "$generated" \
                '. + [{ resolved: $resolved, hash: $hash, prepare: true, downloads: $downloads, yarnLock: $yarnLock }]' <<< "$entries")"
            else
              entries="$(jq --arg resolved "$resolved" --arg hash "$hash" --argjson downloads "$downloads" \
                '. + [{ resolved: $resolved, hash: $hash, prepare: true, downloads: $downloads }]' <<< "$entries")"
            fi
          else
            entries="$(jq --arg resolved "$resolved" --arg hash "$hash" \
              '. + [{ resolved: $resolved, hash: $hash, prepare: false }]' <<< "$entries")"
          fi
        else
          echo "yarn-classic-purifier: hashing $(jq -r .url <<< "$m")" >&2
          hash="$(hashUrl "$(jq -r .url <<< "$m")")"
          entries="$(jq --arg resolved "$resolved" --arg hash "$hash" \
            '. + [{ resolved: $resolved, hash: $hash }]' <<< "$entries")"
        fi
      done < <(jq -c '.[]' <<< "$missing")
      printf '%s\n' "$entries"
    }

    # A copy of the project without its installed packages, in a new
    # directory that this prints.
    projectCopy() {
      local work
      work="$(mktemp -d)"
      (cd "$dir" && tar --exclude=./node_modules --exclude=./.git --exclude=./.yarn-classic-purifier -cf - .) \
        | tar -xf - -C "$work"
      printf '%s\n' "$work"
    }

    # When the tool lockfile lies outside the project and does not exist
    # yet, starts it from the project's own yarn.lock, or from the one
    # that Yarn writes for a project that has none.
    startToolLock() {
      [ "$toolLock" != "$dir/yarn.lock" ] && [ ! -f "$toolLock" ] || return 0
      mkdir -p "$(dirname "$toolLock")"
      if [ -f "$dir/yarn.lock" ]; then
        cp "$dir/yarn.lock" "$toolLock"
      else
        local work
        work="$(projectCopy)"
        (cd "$work" && ${lib.getExe yarnClassic} install --ignore-scripts --non-interactive --silent)
        cp "$work/yarn.lock" "$toolLock"
        rm -rf "$work"
      fi
    }

    # Writes the purifier lockfile for the tool lockfile as it is, or
    # removes the purifier lockfile when yarn.lock records everything.
    lock() {
      local entries
      startToolLock
      if [ -n "''${YARN_CLASSIC_PURIFIER_INPUT_VIEWS_FILE:-}" ]; then
        ${python3}/bin/python ${../../tools}/npm_inputs.py normalize --file "$toolLock" \
          --views "$YARN_CLASSIC_PURIFIER_INPUT_VIEWS_FILE"
      fi
      entries="$(entriesFor "$toolLock")"
      if [ "$(jq length <<< "$entries")" = 0 ] && [ "''${YARN_CLASSIC_PURIFIER_PROJECT_INPUTS:-[]}" = "[]" ]; then
        if [ -f "$out" ]; then
          rm "$out"
          echo "yarn-classic-purifier: yarn.lock records everything; removed $out" >&2
        else
          echo "yarn-classic-purifier: yarn.lock records everything; no purifier lockfile is needed" >&2
        fi
        return
      fi
      writeLock "$toolLock" "$entries" "$out"
      echo "yarn-classic-purifier: wrote $out" >&2
    }

    case "$subcommand" in
      lock)
        [ "$#" -eq 0 ] || usage
        lock
        ;;
      update)
        # Yarn re-resolves the named packages, or all of them, within the
        # ranges package.json declares, and rewrites yarn.lock. Install
        # scripts do not run here; the next install through the yarn
        # wrapper runs them. A tool lockfile outside the project is updated
        # in a copy of the project, so the project's own yarn.lock stays as
        # it is.
        if [ "$toolLock" = "$dir/yarn.lock" ]; then
          (cd "$dir" && ${lib.getExe yarnClassic} upgrade "$@" --ignore-scripts --non-interactive)
        else
          startToolLock
          work="$(projectCopy)"
          cp "$toolLock" "$work/yarn.lock"
          (cd "$work" && ${lib.getExe yarnClassic} upgrade "$@" --ignore-scripts --non-interactive)
          cp "$work/yarn.lock" "$toolLock"
          rm -rf "$work"
        fi
        lock
        ;;
      prefetch)
        [ "$#" -eq 0 ] || usage
        checkJson "$out"
        buildMirror "$toolLock" "$out"
        nix-store --add-root "$(rootsOf "$out")/toolchain" --realise ${yarn} > /dev/null
        echo "yarn-classic-purifier: prefetched the downloads and the toolchain of $dir; the yarn wrapper now works offline" >&2
        if [ "$out" != "$dir/yarn-classic-purifier.lock.json" ]; then
          echo "yarn-classic-purifier: set YARN_CLASSIC_PURIFIER_LOCKFILE=$out for the yarn wrapper" >&2
        fi
        if [ "$toolLock" != "$dir/yarn.lock" ]; then
          echo "yarn-classic-purifier: set YARN_CLASSIC_PURIFIER_TOOL_LOCKFILE=$toolLock for the yarn wrapper" >&2
        fi
        ;;
      publish)
        [ "$#" -ge 1 ] || usage
        package="$1"
        shift
        checkJson "$out"
        purifier=null
        if [ -f "$out" ]; then
          purifier='/. + builtins.getEnv "YARN_CLASSIC_PURIFIER_PURIFIER_LOCK"'
        fi
        tarball="$(YARN_CLASSIC_PURIFIER_SRC="$dir" YARN_CLASSIC_PURIFIER_PURIFIER_LOCK="$out" \
          YARN_CLASSIC_PURIFIER_YARN_LOCK="$toolLock" \
          YARN_CLASSIC_PURIFIER_PACKAGE="$package" \
          nix build --impure --no-link --print-out-paths --expr "
            import ${../../nix/lib}/publish.nix {
              pkgs = import ${path} {
                system = \"${stdenv.hostPlatform.system}\";
                overlays = [ (builtins.getFlake \"path:${../..}\").overlays.default ];
              };
              src = /. + builtins.getEnv \"YARN_CLASSIC_PURIFIER_SRC\";
              yarnLock = /. + builtins.getEnv \"YARN_CLASSIC_PURIFIER_YARN_LOCK\";
              lockFile = $purifier;
              node = ${(import ../../nix/lib/sdk-expression.nix nodejs).shell};
              yarnClassic = ${(import ../../nix/lib/sdk-expression.nix yarnClassic).shell};
              package = builtins.getEnv \"YARN_CLASSIC_PURIFIER_PACKAGE\";
            }
          ")"
        echo "yarn-classic-purifier: publishing $tarball/package.tgz" >&2
        # Native Yarn reads package metadata from cwd even for a tarball.
        # Give it the selected package's built manifest rather than a private
        # workspace root, and contain any native version edits in staging.
        mkdir -p "$dir/.yarn-classic-purifier"
        publishStage="$(mktemp -d "$dir/.yarn-classic-purifier/publish.XXXXXX")"
        trap 'rm -rf "$publishStage"' EXIT
        publishArchive="$(realpath "$tarball/package.tgz")"
        tar -xzf "$publishArchive" -C "$publishStage"
        cd "$publishStage/package"
        ${lib.getExe yarnClassic} publish "$publishArchive" --non-interactive "$@"
        ;;
      *)
        usage
        ;;
    esac
  '';
}
