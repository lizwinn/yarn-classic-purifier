# SPDX-License-Identifier: MIT
#
# Yarn Classic, wrapped so that in a project with a yarn.lock it installs
# the locked tarballs from the Nix store, offline. The wrapper builds the
# lockfile's tarballs into an offline mirror through Nix
# (nix/lib/interactive.nix), under .yarn-classic-purifier in the project,
# and runs Yarn offline against that mirror. It rebuilds the mirror when a
# lockfile changes; after `yarn-classic-purifier prefetch` it needs no
# network.
#
# The purifier lockfile is yarn-classic-purifier.lock.json beside yarn.lock,
# or the file that YARN_CLASSIC_PURIFIER_LOCKFILE names.
#
# The commands that change the lockfile (add, upgrade, upgrade-interactive,
# remove, import) resolve against the registry, as Yarn does without the
# wrapper. YARN_CLASSIC_PURIFIER=0 turns the wrapper off for any command.
{
  lib,
  writeShellApplication,
  nodejs,
  node-gyp,
  python3,
  pkgs,
  coreutils,
  path,
  stdenv,
  # Yarn Classic from nixpkgs. Inside this flake's package scope the name
  # `yarn` is this wrapper, so the argument has another name.
  yarnClassic ? pkgs.yarn,
}:
writeShellApplication {
  name = "yarn";
  # Package scripts run `node`; they get the Node.js that runs Yarn. Install
  # scripts that build native addons get node-gyp and Python.
  runtimeInputs = [
    coreutils
    nodejs
    node-gyp
    python3
  ];
  text = ''
    yarn=${lib.getExe yarnClassic}

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

    ${import ../../nix/lib/mirror-script.nix {
      flake = ../..;
      nixpkgs = path;
      inherit (stdenv.hostPlatform) system;
    }}

    buildMirror "$dir/yarn.lock" "''${YARN_CLASSIC_PURIFIER_LOCKFILE:-$dir/yarn-classic-purifier.lock.json}"

    export YARN_YARN_OFFLINE_MIRROR
    YARN_YARN_OFFLINE_MIRROR="$(rootsOf "$dir/yarn.lock")/mirror"
    export YARN_YARN_OFFLINE_MIRROR_PRUNING=false
    export YARN_DISABLE_SELF_UPDATE_CHECK=true
    # node-gyp takes the headers of the Node.js that runs it rather than
    # downloading them.
    export npm_config_nodedir=${nodejs}
    mirror="$(cd "$dir" && "$yarn" config get yarn-offline-mirror --offline --silent)"
    if [ "$mirror" != "$YARN_YARN_OFFLINE_MIRROR" ] && [ "$mirror" != undefined ]; then
      echo "yarn-classic-purifier: the project sets its own offline mirror ($mirror), which Yarn reads instead of the locked tarballs" >&2
    fi
    exec "$yarn" --offline "$@"
  '';
}
