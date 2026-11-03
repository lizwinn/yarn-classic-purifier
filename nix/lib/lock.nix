# SPDX-License-Identifier: MIT
#
# Reads a Yarn Classic yarn.lock (yarn lockfile v1) at evaluation time.
# It returns
#
#   downloads   one entry per file in Yarn's offline mirror, keyed by its
#               `path`, the file's name in the mirror. A tarball is a file
#               entry { path, url, mirrors, hash }: `url` is the lock's
#               `resolved` without its `#` fragment, `mirrors` lists other
#               URLs that serve the same file, and `hash` is an SRI hash. A
#               git
#               dependency is a git entry
#               { path, git = { url, rev, submodules }, hash, prepare }
#               with `hash` the SRI hash of the checkout as nix-prefetch-git
#               reports it; one whose repository has a `prepare` script also
#               carries `downloads`, the mirror of the repository's own
#               yarn.lock, and `yarnLock`, the text of that yarn.lock, when
#               the repository has none and the lock command resolved one.
#               nix/lib/offline-mirror.nix turns each git entry into the
#               tarball Yarn reads from the mirror.
#   missing     each locked package that needs an entry in the purifier
#               lockfile and has none, as { resolved, url } for a tarball
#               and { resolved, git = { url, rev } } for a git dependency
#
# yarn.lock records an SRI `integrity` for every registry tarball, and older
# lockfiles a SHA-1 in the `#` fragment of `resolved`. A tarball from
# another URL, such as a GitHub dependency that Yarn fetches from
# codeload.github.com, carries no hash in yarn.lock, and neither does a git
# dependency. The purifier lockfile (yarn-classic-purifier.lock.json,
# written by `yarn-classic-purifier lock`) records them, keyed by
# `resolved`. It holds its format `version`, the `inputsHash` of the
# yarn.lock it was written for, and the `contentHash` of its own content:
# the SHA-256 of its JSON without `contentHash`, with keys sorted and no
# whitespace, which is what builtins.toJSON prints.
{
  lib,
  # The project's yarn.lock.
  yarnLock,
  # The purifier lockfile, or null when the project has none.
  lockFile ? null,
  providedNames ? [ ],
  providedVersions ? [ ],
}:
let
  text = builtins.readFile yarnLock;

  sha256 =
    s:
    builtins.convertHash {
      hash = builtins.hashString "sha256" s;
      hashAlgo = "sha256";
      toHashFormat = "sri";
    };

  # Yarn writes one entry per block, with a blank line between blocks. The
  # first line of a block lists the specs that resolve to the entry; the
  # fields follow, indented by two spaces.
  blocks = map (
    block: builtins.filter (line: line != "" && !lib.hasPrefix "#" line) (lib.splitString "\n" block)
  ) (lib.splitString "\n\n" text);
  entries = builtins.filter (lines: lines != [ ]) blocks;

  field =
    name: lines:
    let
      values = lib.concatMap (
        line:
        let
          m = builtins.match "  ${name} \"?([^\"]*)\"?" line;
        in
        if m == null then [ ] else m
      ) lines;
    in
    if values == [ ] then null else builtins.head values;

  lockName = baseNameOf (toString lockFile);

  # Nix cannot catch a JSON parse error, so a file that is not JSON at all
  # fails evaluation, with an error context that names the fix. The
  # commands check the file before Nix reads it.
  purifierLock =
    if lockFile == null then
      null
    else
      builtins.addErrorContext "yarn-classic-purifier: ${lockName} is not valid JSON. Run `yarn-classic-purifier lock`." (
        lib.importJSON lockFile
      );

  # Why the purifier lockfile cannot be used, or null.
  lockProblem =
    let
      lock = purifierLock;
      name = lockName;
      # Each package records the `resolved` field of its yarn.lock entry
      # and the hash of its tarball or checkout.
      invalid = builtins.filter (
        p:
        !(
          builtins.isAttrs p && builtins.isString (p.resolved or null) && builtins.isString (p.hash or null)
        )
      ) lock.packages;
    in
    if lock == null then
      null
    else if !(builtins.isAttrs lock) then
      "yarn-classic-purifier: ${name} holds no JSON object. Run `yarn-classic-purifier lock`."
    else if lock.version or null != 1 then
      "yarn-classic-purifier: ${name} has version ${
        builtins.toJSON (lock.version or null)
      }; this version of yarn-classic-purifier reads version 1. Run `yarn-classic-purifier lock`."
    else if !(builtins.isString (lock.contentHash or null)) then
      "yarn-classic-purifier: ${name} lacks its `contentHash`. Run `yarn-classic-purifier lock`."
    else if lock.contentHash != sha256 (builtins.toJSON (removeAttrs lock [ "contentHash" ])) then
      "yarn-classic-purifier: ${name} was changed after `yarn-classic-purifier lock` wrote it: its content does not match its contentHash. Run `yarn-classic-purifier lock`."
    else if lock.inputsHash or null != sha256 text then
      "yarn-classic-purifier: yarn.lock changed since ${name} was written. Run `yarn-classic-purifier lock`."
    else if !(builtins.isList (lock.packages or null)) then
      "yarn-classic-purifier: ${name} lacks its `packages` list. Run `yarn-classic-purifier lock`."
    else if invalid != [ ] then
      "yarn-classic-purifier: ${name} has a malformed package entry for ${
        builtins.toJSON ((builtins.head invalid).resolved or null)
      }. Run `yarn-classic-purifier lock`."
    else
      null;

  # The purifier lockfile's packages by `resolved`, or none when it cannot
  # be used.
  extra =
    if purifierLock == null || lockProblem != null then
      { }
    else
      lib.listToAttrs (map (e: lib.nameValuePair e.resolved e) purifierLock.packages);

  splitResolved =
    resolved:
    let
      parts = lib.splitString "#" resolved;
    in
    {
      url = builtins.head parts;
      fragment = if builtins.length parts > 1 then lib.last parts else null;
    };

  # The path part of a URL, without its query.
  pathname =
    url:
    let
      m = builtins.match "[a-z+]+://[^/]*(/[^?]*).*" url;
    in
    if m == null then "/" else builtins.head m;

  # Yarn's TarballFetcher names a registry tarball in the mirror after its
  # file name, prefixed with the package's scope for a scoped package
  # (RE_URL_NAME_MATCH in Yarn's source). Any other URL keeps the last
  # segment of its path.
  tarballMirrorName =
    url:
    let
      p = pathname url;
      m = builtins.match "(.*)/([^/]+)/(-|_attachments)/(@[^/]+/)?([^/]+)" p;
      before = builtins.elemAt m 0;
      name = builtins.elemAt m 1;
      file = builtins.elemAt m 4;
      lastBefore = lib.last (lib.splitString "/" before);
      encodedScope = builtins.match "(@[^/]+)%2[fF].*" name;
      scope =
        if lib.hasPrefix "@" lastBefore then
          lastBefore
        else if encodedScope != null then
          builtins.head encodedScope
        else
          null;
    in
    if m == null then
      lib.last (lib.splitString "/" p)
    else if scope != null then
      "${scope}-${file}"
    else
      file;

  # Yarn's GitFetcher names a git dependency in the mirror after the last
  # segment of the repository path and the commit.
  gitMirrorName = url: rev: lib.removePrefix ":" "${lib.last (lib.splitString "/" url)}-${rev}";

  # The URL fetchgit clones. An scp-style address becomes an ssh URL, and
  # the ssh URL of a public forge becomes its https URL, which serves the
  # same repository without credentials.
  cloneUrl =
    url:
    let
      plain = lib.removePrefix "git+" url;
      scp = builtins.match "([^/:@]+@)?([^/:]+):([^/].*)" plain;
      ssh =
        if scp != null && !(lib.hasInfix "://" plain) then
          "ssh://${toString (builtins.elemAt scp 0)}${builtins.elemAt scp 1}/${builtins.elemAt scp 2}"
        else
          plain;
      forge = builtins.match "ssh://([^@/]+@)?(github\\.com|gitlab\\.com|bitbucket\\.org)/(.*)" ssh;
    in
    if forge != null then "https://${builtins.elemAt forge 1}/${builtins.elemAt forge 2}" else ssh;

  # Yarn's registry and npm's registry serve the same tarballs at the same
  # paths, so a tarball from either has the other as its mirror.
  registryMirrors =
    url:
    let
      yarn = "https://registry.yarnpkg.com/";
      npm = "https://registry.npmjs.org/";
    in
    if lib.hasPrefix yarn url then
      [ (npm + lib.removePrefix yarn url) ]
    else if lib.hasPrefix npm url then
      [ (yarn + lib.removePrefix npm url) ]
    else
      [ ];

  # The strongest hash of an integrity that lists several.
  strongest =
    integrity:
    let
      hashes = lib.splitString " " integrity;
      rank =
        h:
        if lib.hasPrefix "sha512-" h then
          3
        else if lib.hasPrefix "sha384-" h then
          2
        else if lib.hasPrefix "sha256-" h then
          1
        else
          0;
    in
    builtins.head (lib.sort (a: b: rank a > rank b) hashes);

  isGit =
    url:
    lib.hasPrefix "git+" url
    || lib.hasPrefix "git://" url
    || lib.hasPrefix "git@" url
    || lib.hasSuffix ".git" (pathname url);

  gitEntry =
    resolved: url: rev: recorded:
    if recorded == null then
      {
        missing = {
          inherit resolved;
          git = {
            url = cloneUrl url;
            inherit rev;
          };
        };
      }
    else
      {
        download = {
          path = gitMirrorName url rev;
          git = {
            url = cloneUrl url;
            inherit rev;
            submodules = false;
            leaveDotGit = false;
            commitObject = null;
          };
          inherit (recorded) hash prepare;
        }
        // lib.optionalAttrs recorded.prepare { inherit (recorded) downloads; }
        // lib.optionalAttrs (recorded ? yarnLock) { inherit (recorded) yarnLock; };
      };

  entryDownload =
    lines:
    let
      names = lib.concatMap (
        selector:
        let
          plain = builtins.replaceStrings [ "\"" ] [ "" ] selector;
          matched = builtins.match "(@[^@]+|[^@]+)@(.*)" plain;
          alias =
            if matched == null then
              null
            else
              builtins.match "npm:(@[^@]+|[^@]+)@.*" (builtins.elemAt matched 1);
        in
        if matched == null then
          [ ]
        else
          [ (builtins.head matched) ] ++ lib.optional (alias != null) (builtins.head alias)
      ) (lib.splitString ", " (lib.removeSuffix ":" (builtins.head lines)));
      supplied = builtins.any (
        name:
        builtins.elem name providedNames
        || builtins.elem {
          inherit name;
          version = field "version" lines;
        } providedVersions
      ) names;
      resolved = field "resolved" lines;
      integrity = field "integrity" lines;
      inherit (splitResolved resolved) url fragment;
      recorded = extra.${resolved} or null;
      sha1 =
        if fragment != null && builtins.match "[0-9a-f]{40}" fragment != null then fragment else null;
    in
    # A package without `resolved` is a `file:` directory, a `link:` or a
    # workspace, and a `file:` tarball resolves to a path; Yarn reads all of
    # them from the project source.
    if supplied || resolved == null || lib.hasPrefix "file:" resolved then
      null
    else if isGit url then
      if fragment == null then
        {
          problem = "yarn-classic-purifier: ${builtins.head lines} in yarn.lock resolves to ${resolved}, which names no commit. Run `yarn install` with Yarn Classic to write the commit into yarn.lock.";
        }
      else
        gitEntry resolved url fragment recorded
    else
      let
        hash =
          if integrity != null then
            strongest integrity
          else if sha1 != null then
            builtins.convertHash {
              hash = sha1;
              hashAlgo = "sha1";
              toHashFormat = "sri";
            }
          else if recorded != null then
            recorded.hash
          else
            null;
      in
      if hash == null then
        { missing = { inherit resolved url; }; }
      else
        {
          download = {
            path = tarballMirrorName url;
            inherit url hash;
            mirrors = registryMirrors url;
          };
        };

  results = builtins.filter (r: r != null) (map entryDownload entries);
  missing = lib.unique (map (r: r.missing) (builtins.filter (r: r ? missing) results));
in
{
  # Several entries can name the same file; the mirror holds it once.
  downloads = builtins.attrValues (
    lib.listToAttrs (
      map (r: lib.nameValuePair r.download.path r.download) (builtins.filter (r: r ? download) results)
    )
  );
  inherit missing;
  # Why the lockfiles cannot be used, each naming the command that fixes
  # it. A purifier lockfile that cannot be used makes every package it
  # would record missing, so its problem stands alone.
  problems =
    if lockProblem != null then
      [ lockProblem ]
    else
      map (r: r.problem) (builtins.filter (r: r ? problem) results)
      ++ lib.optional (missing != [ ]) ''
        yarn-classic-purifier: ${
          if lockFile == null then
            "the project has no yarn-classic-purifier.lock.json, and nothing records"
          else
            "${lockName} records nothing for"
        } these packages:
          ${lib.concatMapStringsSep "\n  " (m: m.resolved) missing}
        Run `yarn-classic-purifier lock` in the project to record them.'';
}
