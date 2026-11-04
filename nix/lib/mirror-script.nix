# SPDX-License-Identifier: MIT
#
# The shell functions that `yarn-classic-purifier prefetch` and the `yarn`
# wrapper share.
#
# `rootsOf <purifier lockfile>` prints the directory of the
# garbage-collector roots, which lies beside the purifier lockfile:
# `.yarn-classic-purifier` in the directory that holds it.
#
# `checkJson <purifier lockfile>` stops the command when the file exists
# and is not valid JSON, with a message that names the fix. Nix cannot
# catch a JSON parse error, so the commands check before Nix reads the
# file.
#
# `buildMirror <yarn.lock> <purifier lockfile>` builds the offline mirror
# of nix/lib/interactive.nix at `mirror` in the roots directory, unless the
# mirror there was built from the same two lockfiles. The purifier lockfile
# may be absent. The file `lock.sha256` in the roots directory records the
# SHA-256 of the lockfiles the mirror was built from.
{
  # This flake's source, whose `lib.purifier` output is the shared purifier
  # library.
  flake,
  # nixpkgs, and the system to build for.
  nixpkgs,
  system,
  node,
  yarn,
}:
''
  rootsOf() {
    printf '%s/.yarn-classic-purifier\n' "$(dirname "$1")"
  }

  checkJson() {
    if [ -f "$1" ] && ! jq -e . "$1" > /dev/null 2>&1; then
      echo "yarn-classic-purifier: $1 is not valid JSON. Run \`yarn-classic-purifier lock\`." >&2
      exit 1
    fi
  }

  # Prints the SHA-256 of the lockfiles $1 and $2.
  stampOf() {
    {
      printf '%s\n' ${node} ${yarn} ${flake} ${nixpkgs}
      cat "$1"
      cat "$2" 2> /dev/null || true
    } | sha256sum | cut -d' ' -f1
  }

  buildMirror() {
    local roots stamp lockExpr
    roots="$(rootsOf "$2")"
    stamp="$(stampOf "$1" "$2")"
    if [ "$(cat "$roots/lock.sha256" 2> /dev/null || true)" = "$stamp" ] && [ -e "$roots/mirror" ]; then
      return
    fi
    checkJson "$2"
    echo "yarn-classic-purifier: building the tarballs of $1" >&2
    mkdir -p "$roots"
    lockExpr=null
    if [ -f "$2" ]; then
      lockExpr='/. + builtins.getEnv "YARN_CLASSIC_PURIFIER_PURIFIER_LOCK"'
    fi
    YARN_CLASSIC_PURIFIER_LOCK="$1" YARN_CLASSIC_PURIFIER_PURIFIER_LOCK="$2" \
      nix build --impure --out-link "$roots/mirror" --expr "
        import ${flake}/nix/lib/interactive.nix {
          purifier = (builtins.getFlake \"path:${flake}\").lib.purifier;
          pkgs = import ${nixpkgs} { system = \"${system}\"; };
          node = builtins.storePath \"${node}\";
          yarn = builtins.storePath \"${yarn}\";
          yarnLock = /. + builtins.getEnv \"YARN_CLASSIC_PURIFIER_LOCK\";
          lockFile = $lockExpr;
        }
      "
    printf '%s\n' "$stamp" > "$roots/lock.sha256"
  }
''
