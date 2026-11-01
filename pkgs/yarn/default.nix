# SPDX-License-Identifier: MIT
#
# Yarn Classic, wrapped so that in a project with a yarn.lock it installs
# the locked tarballs from the Nix store, offline. The wrapper builds the
# lockfile's tarballs into an offline mirror through Nix
# (nix/lib/interactive.nix), under $XDG_CACHE_HOME/yarn-classic-purifier,
# and runs Yarn offline against that mirror. It rebuilds the mirror when a
# lockfile changes.
#
# The commands that change the lockfile (add, upgrade, upgrade-interactive,
# remove, import) resolve against the registry, as Yarn does without the
# wrapper. YARN_CLASSIC_PURIFIER=0 turns the wrapper off for any command.
{
  lib,
  writeShellApplication,
  nodejs,
  pkgs,
  coreutils,
  path,
  stdenv,
  # Yarn Classic from nixpkgs. Inside this flake's package scope the name
  # `yarn` is this wrapper, so the argument has another name.
  yarnClassic ? pkgs.yarn,
}:
let
  yarn = yarnClassic;
in
writeShellApplication {
  name = "yarn";
  # Package scripts run `node`; they get the Node.js that runs Yarn.
  runtimeInputs = [
    coreutils
    nodejs
  ];
  text = ''
    yarn=${lib.getExe yarn}

    if [ "''${YARN_CLASSIC_PURIFIER:-1}" = 0 ]; then
      exec "$yarn" "$@"
    fi

    # The first argument that is not an option is Yarn's command.
    command=
    for arg in "$@"; do
      case "$arg" in
        -*) ;;
        *)
          command="$arg"
          break
          ;;
      esac
    done
    case "$command" in
      add | upgrade | upgrade-interactive | remove | import | generate-lock-entry)
        exec "$yarn" "$@"
        ;;
    esac

    # The project root is the nearest directory upwards with a lockfile.
    dir="$PWD"
    while [ ! -f "$dir/yarn.lock" ]; do
      if [ "$dir" = / ]; then
        exec "$yarn" "$@"
      fi
      dir="$(dirname "$dir")"
    done
    lock="$dir/yarn.lock"
    purifierLock="$dir/yarn-classic-purifier.lock.json"

    cache="''${XDG_CACHE_HOME:-$HOME/.cache}/yarn-classic-purifier/$(printf '%s' "$lock" | sha256sum | cut -c1-32)"
    stamp="$({
      cat "$lock"
      cat "$purifierLock" 2> /dev/null || true
    } | sha256sum | cut -d' ' -f1)"
    if [ "$(cat "$cache/lock.sha256" 2> /dev/null || true)" != "$stamp" ]; then
      echo "yarn-classic-purifier: building the tarballs of $lock" >&2
      mkdir -p "$cache"
      purifierLockExpr=null
      if [ -f "$purifierLock" ]; then
        purifierLockExpr='/. + builtins.getEnv "YARN_CLASSIC_PURIFIER_PURIFIER_LOCK"'
      fi
      YARN_CLASSIC_PURIFIER_LOCK="$lock" YARN_CLASSIC_PURIFIER_PURIFIER_LOCK="$purifierLock" \
        nix build --impure --out-link "$cache/mirror" --expr "
          import ${../../nix/lib}/interactive.nix {
            pkgs = import ${path} { system = \"${stdenv.hostPlatform.system}\"; };
            lockFile = /. + builtins.getEnv \"YARN_CLASSIC_PURIFIER_LOCK\";
            purifierLockFile = $purifierLockExpr;
          }
        "
      printf '%s\n' "$stamp" > "$cache/lock.sha256"
    fi

    export YARN_YARN_OFFLINE_MIRROR="$cache/mirror"
    export YARN_YARN_OFFLINE_MIRROR_PRUNING=false
    export YARN_DISABLE_SELF_UPDATE_CHECK=true
    mirror="$(cd "$dir" && "$yarn" config get yarn-offline-mirror --offline --silent)"
    if [ "$mirror" != "$YARN_YARN_OFFLINE_MIRROR" ] && [ "$mirror" != undefined ]; then
      echo "yarn-classic-purifier: the project sets its own offline mirror ($mirror), which Yarn reads instead of the locked tarballs" >&2
    fi
    exec "$yarn" --offline "$@"
  '';
}
