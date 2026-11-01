# SPDX-License-Identifier: MIT
#
# The shell steps that install a Yarn Classic project offline in the
# sandbox, shared by the project's builds and by the builds of git
# dependencies that have a `prepare` script.
{
  lib,
  # The Node.js whose headers node-gyp builds native addons against.
  node,
}:
{
  # Points Yarn at an offline mirror: a writable tree of links to the
  # mirror's files. Yarn reads the setting `yarn-offline-mirror` from the
  # environment first and from the project's .yarnrc and .npmrc after, so a
  # project that sets its own mirror gets the links in that directory
  # instead.
  setup = mirror: ''
    export HOME="$TMPDIR/home"
    export YARN_CACHE_FOLDER="$TMPDIR/yarn-cache"
    export YARN_YARN_OFFLINE_MIRROR="$TMPDIR/yarn-offline-mirror"
    export YARN_YARN_OFFLINE_MIRROR_PRUNING=false
    export YARN_DISABLE_SELF_UPDATE_CHECK=true
    # node-gyp takes the headers of the Node.js that runs it rather than
    # downloading them.
    export npm_config_nodedir=${node}
    mkdir -p "$HOME" "$YARN_YARN_OFFLINE_MIRROR"
    cp -rs --no-preserve=mode ${mirror}/. "$YARN_YARN_OFFLINE_MIRROR"
    mirror="$(yarn config get yarn-offline-mirror --offline --silent)"
    if [ "$mirror" != "$YARN_YARN_OFFLINE_MIRROR" ] && [ "$mirror" != undefined ]; then
      mkdir -p "$mirror"
      cp -rsn --no-preserve=mode ${mirror}/. "$mirror"
    fi
  '';

  # Installs the locked dependencies and runs the install scripts. The
  # sandbox has no /usr/bin/env, so a script that runs a dependency's
  # command needs that command's interpreter patched first. A first install
  # without scripts fills Yarn's cache, which holds the packages' files
  # that Yarn copies into node_modules; the interpreters are patched in the
  # cache and in the project, and the second install copies the patched
  # files and runs the scripts.
  install =
    flags:
    let
      args = lib.escapeShellArgs (
        [
          "--offline"
          "--frozen-lockfile"
          "--non-interactive"
          "--no-progress"
        ]
        ++ flags
      );
    in
    ''
      yarn install ${args} --ignore-scripts
      patchShebangs "$YARN_CACHE_FOLDER" > /dev/null
      while IFS= read -r -d "" dir; do
        rm -rf "$dir"
      done < <(find . -name node_modules -type d -prune -print0)
      patchShebangs . > /dev/null
      yarn install ${args}
    '';
}
