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
# or the file that YARN_CLASSIC_PURIFIER_LOCKFILE names, and the yarn.lock is
# the one beside it or the file that YARN_CLASSIC_PURIFIER_TOOL_LOCKFILE names.
#
# The commands that change the lockfile (add, upgrade, upgrade-interactive,
# remove, import) resolve against the registry, as Yarn does without the
# wrapper. YARN_CLASSIC_PURIFIER=0 turns the wrapper off for any command.
{
  lib,
  purifier,
  writeShellApplication,
  writeShellScript,
  runtimeShell,
  nodejs,
  node-gyp,
  python3,
  pkgs,
  coreutils,
  jq,
  path,
  stdenv,
  # Yarn Classic from nixpkgs. Inside this flake's package scope the name
  # `yarn` is this wrapper, so the argument has another name.
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
  name = "yarn";
  # Package scripts run `node`; they get the Node.js that runs Yarn. Install
  # scripts that build native addons get node-gyp and Python.
  runtimeInputs = [
    coreutils
    jq
    nodejs
    node-gyp
    python3
  ];
  text = ''
    if [ "''${YARN_CLASSIC_PURIFIER_REENTER:-0}" != 1 ]; then
      exec ${python3}/bin/python ${../../tools}/composition.py \
        --mode tool --inner "$0" --native-yarn ${lib.getExe yarnClassic} \
        --flake ${../..} --nixpkgs ${path} --system ${stdenv.hostPlatform.system} \
        --tools ${purifier.projectInputsTool} -- "$@"
    fi

    yarn=${lib.getExe yarnClassic}
    if [ "''${YARN_CLASSIC_PURIFIER_NATIVE_CONTEXT:-0}" = 1 ]; then
      exec "$yarn" --offline "$@"
    fi

    if [ "''${YARN_CLASSIC_PURIFIER:-1}" = 0 ]; then
      exec "$yarn" "$@"
    fi
    export YARN_SCRIPT_SHELL=${scriptShell}

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
    # The project root is the nearest directory upwards with a lockfile.
    dir="$PWD"
    marker=yarn.lock
    if [ -n "''${YARN_CLASSIC_PURIFIER_TOOL_LOCKFILE:-}" ] && [ -f "$YARN_CLASSIC_PURIFIER_TOOL_LOCKFILE" ]; then
      marker=package.json
    fi
    while [ ! -f "$dir/$marker" ]; do
      if [ "$dir" = / ]; then
        echo "yarn-classic-purifier: warning: no yarn.lock found; running yarn impurely. Run \`yarn-classic-purifier lock\` to use Nix-resolved dependencies." >&2
        exec "$yarn" "$@"
      fi
      dir="$(dirname "$dir")"
    done

    case "$command" in
      add | upgrade | upgrade-interactive | remove | import | generate-lock-entry)
        exec "$yarn" "$@"
        ;;
    esac

    ${import ../../nix/lib/mirror-script.nix {
      flake = ../..;
      nixpkgs = path;
      node = nodejs;
      yarn = yarnClassic;
      inherit (stdenv.hostPlatform) system;
    }}

    lockfile="''${YARN_CLASSIC_PURIFIER_LOCKFILE:-$dir/yarn-classic-purifier.lock.json}"
    toolLock="''${YARN_CLASSIC_PURIFIER_TOOL_LOCKFILE:-$dir/yarn.lock}"
    buildMirror "$toolLock" "$lockfile"

    export YARN_YARN_OFFLINE_MIRROR
    YARN_YARN_OFFLINE_MIRROR="$(rootsOf "$lockfile")/mirror"
    export YARN_YARN_OFFLINE_MIRROR_PRUNING=false
    export YARN_DISABLE_SELF_UPDATE_CHECK=true
    # node-gyp takes the headers of the Node.js that runs it rather than
    # downloading them.
    export npm_config_nodedir=${nodejs}
    mirror="$(cd "$dir" && "$yarn" config get yarn-offline-mirror --offline --silent)"
    if [ "$mirror" != "$YARN_YARN_OFFLINE_MIRROR" ] && [ "$mirror" != undefined ]; then
      echo "yarn-classic-purifier: the project sets its own offline mirror ($mirror), which Yarn reads instead of the locked tarballs" >&2
    fi
    if [ "''${YARN_CLASSIC_PURIFIER_INPUT_VIEWS:-[]}" != "[]" ] || [ "$toolLock" != "$dir/yarn.lock" ]; then
      exec ${python3}/bin/python ${../../tools}/native.py --root "$dir" \
        --tool-lock "$toolLock" --views "''${YARN_CLASSIC_PURIFIER_INPUT_VIEWS:-[]}" \
        -- "$yarn" --offline "$@"
    fi
    exec "$yarn" --offline "$@"
  '';
}
