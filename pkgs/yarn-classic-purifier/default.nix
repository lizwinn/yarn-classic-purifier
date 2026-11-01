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
# The command reads yarn.lock with the reader a build uses
# (nix/lib/lock.nix), and removes the file when nothing needs it.
#
# `yarn-classic-purifier publish <package> [yarn publish options]` builds
# the tarball of a package of the project in the Nix sandbox and publishes
# that tarball with `yarn publish`.
{
  lib,
  writeShellApplication,
  coreutils,
  jq,
  nix-prefetch-git,
  nodejs,
  pkgs,
  path,
  stdenv,
  # Yarn Classic from nixpkgs. Inside this flake's package scope the name
  # `yarn` is the offline wrapper, so the argument has another name.
  yarnClassic ? pkgs.yarn,
}:
writeShellApplication {
  name = "yarn-classic-purifier";
  runtimeInputs = [
    coreutils
    jq
    nix-prefetch-git
    nodejs
  ];
  text = ''
    # A failure inside a command substitution stops the command too.
    shopt -s inherit_errexit

    usage() {
      echo "usage: yarn-classic-purifier lock" >&2
      echo "       yarn-classic-purifier publish <package> [yarn publish options]" >&2
      exit 2
    }
    [ "$#" -ge 1 ] || usage

    dir="$PWD"
    while [ ! -f "$dir/yarn.lock" ]; do
      if [ "$dir" = / ]; then
        echo "yarn-classic-purifier: no yarn.lock in $PWD or above it" >&2
        exit 1
      fi
      dir="$(dirname "$dir")"
    done
    out="$dir/yarn-classic-purifier.lock.json"
    pkgs='import ${path} { system = "${stdenv.hostPlatform.system}"; }'

    # Prints attribute $2 of what nix/lib/lock.nix reads from lockfile $1,
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
            lockFile = /. + builtins.getEnv \"YARN_CLASSIC_PURIFIER_LOCK\";
            purifierLockFile = $purifier;
          }).$2
        "
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
            jq -n --argjson packages "$nested" '{ format: 1, packages: $packages }' > "$nestedLock"
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
          hash="$(nix store prefetch-file --json --hash-type sha512 "$(jq -r .url <<< "$m")" | jq -r .hash)"
          entries="$(jq --arg resolved "$resolved" --arg url "$(jq -r .url <<< "$m")" --arg hash "$hash" \
            '. + [{ resolved: $resolved, url: $url, hash: $hash }]' <<< "$entries")"
        fi
      done < <(jq -c '.[]' <<< "$missing")
      printf '%s\n' "$entries"
    }

    case "$1" in
      lock)
        [ "$#" -eq 1 ] || usage
        entries="$(entriesFor "$dir")"
        if [ "$(jq length <<< "$entries")" = 0 ]; then
          if [ -f "$out" ]; then
            rm "$out"
            echo "yarn-classic-purifier: yarn.lock records everything; removed $out" >&2
          else
            echo "yarn-classic-purifier: yarn.lock records everything; no purifier lockfile is needed" >&2
          fi
          exit 0
        fi
        jq -n --argjson packages "$entries" '{ format: 1, packages: $packages }' > "$out"
        echo "yarn-classic-purifier: wrote $out" >&2
        ;;
      publish)
        [ "$#" -ge 2 ] || usage
        package="$2"
        shift 2
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
              purifierLockFile = $purifier;
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
