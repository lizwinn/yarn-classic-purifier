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
# elsewhere than the project root.
{
  lib,
  writeShellApplication,
  coreutils,
  curl,
  jq,
  nix-prefetch-git,
  nodejs,
  pkgs,
  path,
  stdenv,
  # The offline wrapper of this flake's package scope.
  yarn,
  # Yarn Classic from nixpkgs. Inside this flake's package scope the name
  # `yarn` is the offline wrapper, so the argument has another name.
  yarnClassic ? pkgs.yarn,
}:
writeShellApplication {
  name = "yarn-classic-purifier";
  runtimeInputs = [
    coreutils
    curl
    jq
    nix-prefetch-git
    nodejs
  ];
  text = ''
    # A failure inside a command substitution stops the command too.
    shopt -s inherit_errexit

    usage() {
      echo "usage: yarn-classic-purifier lock [--lockfile <path>]" >&2
      echo "       yarn-classic-purifier update [--lockfile <path>] [<package>...]" >&2
      echo "       yarn-classic-purifier prefetch [--lockfile <path>]" >&2
      echo "       yarn-classic-purifier publish [--lockfile <path>] <package> [yarn publish options]" >&2
      exit 2
    }
    [ "$#" -ge 1 ] || usage
    subcommand="$1"
    shift

    dir="$PWD"
    while [ ! -f "$dir/yarn.lock" ]; do
      if [ "$dir" = / ]; then
        echo "yarn-classic-purifier: no yarn.lock in $PWD or above it" >&2
        exit 1
      fi
      dir="$(dirname "$dir")"
    done
    out="$dir/yarn-classic-purifier.lock.json"
    if [ "''${1:-}" = --lockfile ]; then
      [ "$#" -ge 2 ] || usage
      out="$(realpath -m "$2")"
      shift 2
    fi
    pkgs='import ${path} { system = "${stdenv.hostPlatform.system}"; }'

    ${import ../../nix/lib/mirror-script.nix {
      flake = ../..;
      nixpkgs = path;
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
        '{ version: 1, inputsHash: $inputsHash, packages: $packages }')"
      jq --arg contentHash "$(jq -cjS . <<< "$body" | sri sha256)" \
        '. + { contentHash: $contentHash }' <<< "$body" > "$3"
    }

    # Prints the SRI SHA-512 of the file at URL $1.
    hashUrl() {
      curl --fail --silent --show-error --location "$1" | sri sha512
    }

    # Prints the purifier lockfile entries for what yarn.lock in directory
    # $1 leaves out, as a JSON list.
    entriesFor() {
      local missing entries m resolved prefetch hash checkout nested nestedLock downloads generated work
      missing="$(readLock "$1/yarn.lock" missing)"
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
            nested="$(entriesFor "$checkout")"
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

    # Writes the purifier lockfile for the project's yarn.lock as it is, or
    # removes it when yarn.lock records everything.
    lock() {
      local entries
      entries="$(entriesFor "$dir")"
      if [ "$(jq length <<< "$entries")" = 0 ]; then
        if [ -f "$out" ]; then
          rm "$out"
          echo "yarn-classic-purifier: yarn.lock records everything; removed $out" >&2
        else
          echo "yarn-classic-purifier: yarn.lock records everything; no purifier lockfile is needed" >&2
        fi
        return
      fi
      writeLock "$dir/yarn.lock" "$entries" "$out"
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
        # wrapper runs them.
        (cd "$dir" && ${lib.getExe yarnClassic} upgrade "$@" --ignore-scripts --non-interactive)
        lock
        ;;
      prefetch)
        [ "$#" -eq 0 ] || usage
        buildMirror "$dir/yarn.lock" "$out"
        nix-store --add-root "$(rootsOf "$dir/yarn.lock")/toolchain" --realise ${yarn} > /dev/null
        echo "yarn-classic-purifier: prefetched the downloads and the toolchain of $dir; the yarn wrapper now works offline" >&2
        if [ "$out" != "$dir/yarn-classic-purifier.lock.json" ]; then
          echo "yarn-classic-purifier: set YARN_CLASSIC_PURIFIER_LOCKFILE=$out for the yarn wrapper" >&2
        fi
        ;;
      publish)
        [ "$#" -ge 1 ] || usage
        package="$1"
        shift
        purifier=null
        if [ -f "$out" ]; then
          purifier='/. + builtins.getEnv "YARN_CLASSIC_PURIFIER_PURIFIER_LOCK"'
        fi
        tarball="$(YARN_CLASSIC_PURIFIER_SRC="$dir" YARN_CLASSIC_PURIFIER_PURIFIER_LOCK="$out" \
          YARN_CLASSIC_PURIFIER_PACKAGE="$package" \
          nix build --impure --no-link --print-out-paths --expr "
            import ${../../nix/lib}/publish.nix {
              purifier = (builtins.getFlake \"path:${../..}\").lib.purifier;
              pkgs = $pkgs;
              src = /. + builtins.getEnv \"YARN_CLASSIC_PURIFIER_SRC\";
              lockFile = $purifier;
              package = builtins.getEnv \"YARN_CLASSIC_PURIFIER_PACKAGE\";
            }
          ")"
        echo "yarn-classic-purifier: publishing $tarball/package.tgz" >&2
        cd "$dir"
        exec ${lib.getExe yarnClassic} publish "$tarball/package.tgz" --non-interactive "$@"
        ;;
      *)
        usage
        ;;
    esac
  '';
}
