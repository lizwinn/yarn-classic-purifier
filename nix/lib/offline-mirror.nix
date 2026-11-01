# SPDX-License-Identifier: MIT
#
# Yarn's offline mirror for the downloads of nix/lib/lock.nix: a tree of
# links, each at the file name Yarn looks the package up by.
#
# The shared purifier library fetches the entries. A file entry is a
# locked tarball. A git entry becomes the tarball Yarn's GitFetcher would have written to the
# mirror. For a repository without a `prepare` script, that is a tar of the
# commit's files at the archive root, as `git archive` writes it. For a
# repository with one, Yarn installs the repository with its
# devDependencies, which runs the `prepare` script, and packs the result;
# here the install runs offline against the mirror of the repository's own
# yarn.lock, which the git entry carries in `downloads`. Yarn reads a tar
# whose entries lie at the root as an unpacked package, so the packed
# package goes into the mirror with the `package/` directory of `yarn pack`
# removed.
#
# Yarn Classic clones a git dependency without its submodules, so the
# checkouts leave them out too.
{
  lib,
  pkgs,
  stdenv,
  callPackage,
  runCommand,
  # The `purifier` namespace of the shared library.
  purifier,
  # Replaces fetchers of the purifier library; its fetchEntry and tree take
  # it unchanged.
  fetchers ? { },
  gnutar,
  nodejs,
  yarn,
  python3,
  node-gyp,
  # The download entries.
  downloads,
  # The Node.js that runs Yarn in the builds of git dependencies.
  node ? nodejs,
  # The name of the mirror in the store.
  name ? "yarn-offline-mirror",
}:
let
  steps = import ./yarn-install.nix { inherit lib node; };

  files = purifier.tree (
    fetchers
    // {
      inherit pkgs;
      name = "${name}-files";
      entries = builtins.filter (d: !(d ? git)) downloads;
    }
  );

  checkout = purifier.fetchEntry (fetchers // { inherit pkgs; });

  # Writes the files of directory $1 at the root of tar file $2, in a
  # fixed order and with fixed owners and times. The files come from the
  # read-only store, and Yarn cannot write into a directory it extracts
  # without write permission, so the entries get the owner's write
  # permission, as in what `git archive` writes.
  tarRoot = ''
    tarRoot() {
      (cd "$1" && find . -mindepth 1 -printf '%P\n' | LC_ALL=C sort \
        | tar --no-recursion --owner=0 --group=0 --numeric-owner --mtime=@1 --mode=u+w -cf "$2" -T -)
    }
  '';

  archive =
    d:
    runCommand d.path { nativeBuildInputs = [ gnutar ]; } ''
      ${tarRoot}
      tarRoot ${checkout d} "$out"
    '';

  prepared =
    d:
    stdenv.mkDerivation {
      name = d.path;
      src = checkout d;
      nativeBuildInputs = [
        node
        yarn
        gnutar
        python3
        node-gyp
      ];
      dontConfigure = true;
      passAsFile = lib.optional (d ? yarnLock) "yarnLock";
      yarnLock = d.yarnLock or null;
      buildPhase = ''
        runHook preBuild
        ${lib.optionalString (d ? yarnLock) ''cp "$yarnLockPath" yarn.lock''}
        ${steps.setup (
          callPackage ./offline-mirror.nix {
            inherit (d) downloads;
            inherit
              node
              fetchers
              purifier
              ;
          }
        )}
        ${steps.install [ ]}
        runHook postBuild
      '';
      installPhase = ''
        runHook preInstall
        ${tarRoot}
        yarn pack --offline --silent --filename "$TMPDIR/package.tgz"
        mkdir "$TMPDIR/package"
        tar -xzf "$TMPDIR/package.tgz" -C "$TMPDIR/package" --strip-components=1
        tarRoot "$TMPDIR/package" "$out"
        runHook postInstall
      '';
      dontFixup = true;
    };

  gitTarball = d: if d.prepare then prepared d else archive d;
  gits = builtins.filter (d: d ? git) downloads;
in
runCommand name
  {
    preferLocalBuild = true;
    allowSubstitutes = false;
    passAsFile = [ "links" ];
    links = lib.concatMapStrings (d: "${d.path}\t${gitTarball d}\n") gits;
  }
  ''
    mkdir -p "$out"
    cp -rs --no-preserve=mode ${files}/. "$out"
    while IFS=$'\t' read -r path target; do
      ln -s "$target" "$out/$path"
    done < "$linksPath"
  ''
