# SPDX-License-Identifier: MIT
#
# The shell function that `yarn-classic-purifier prefetch` and the `yarn`
# wrapper share. `buildMirror <yarn.lock> <purifier lockfile>` builds the
# offline mirror of nix/lib/interactive.nix for the project at
# <project>/.yarn-classic-purifier/mirror, a garbage-collector root, unless
# the mirror there was built from the same two lockfiles. The purifier
# lockfile may be absent. The file
# <project>/.yarn-classic-purifier/lock.sha256 records the SHA-256 of the
# lockfiles the mirror was built from.
{
  # This flake's source, whose `lib.purifier` output is the shared purifier
  # library.
  flake,
  # nixpkgs, and the system to build for.
  nixpkgs,
  system,
}:
''
  # Prints the directory of the project's garbage-collector roots.
  rootsOf() {
    printf '%s/.yarn-classic-purifier\n' "$(dirname "$1")"
  }

  # Prints the SHA-256 of the lockfiles $1 and $2.
  stampOf() {
    {
      cat "$1"
      cat "$2" 2> /dev/null || true
    } | sha256sum | cut -d' ' -f1
  }

  buildMirror() {
    local roots stamp lockExpr
    roots="$(rootsOf "$1")"
    stamp="$(stampOf "$1" "$2")"
    if [ "$(cat "$roots/lock.sha256" 2> /dev/null || true)" = "$stamp" ] && [ -e "$roots/mirror" ]; then
      return
    fi
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
          yarnLock = /. + builtins.getEnv \"YARN_CLASSIC_PURIFIER_LOCK\";
          lockFile = $lockExpr;
        }
      "
    printf '%s\n' "$stamp" > "$roots/lock.sha256"
  }
''
