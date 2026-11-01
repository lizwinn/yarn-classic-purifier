# yarn-classic-purifier

A Nix builder and a Yarn wrapper for projects that use Yarn Classic (Yarn 1)
and its `yarn.lock`. Nix builds the project in its sandbox from what
`yarn.lock` records, and the project needs no Nix files of its own.

For Yarn 2 and later, use
[yarn-berry-purifier](https://github.com/nix-purifiers/yarn-berry-purifier).

yarn-classic-purifier follows the design of
[sbt-nix-backend](https://github.com/nix-purifiers/sbt-purifier): the build
tool keeps planning the build, a lockfile records every download, and Nix
fetches the downloads and runs the build offline in its sandbox. Yarn
Classic already writes most of that lockfile itself. The shared library
of the nix-purifiers,
[purifier](https://github.com/nix-purifiers/purifier), fetches the
locked tarballs and git checkouts.

## How it works

`yarn.lock` records the URL of every tarball the install fetches, and for a
registry tarball it records a hash too: an SRI `integrity`, or in older
lockfiles a SHA-1 in the `#` fragment of the URL. Nix reads `yarn.lock` at
evaluation time and fetches each tarball as a fixed-output download. It lays
the tarballs out as a Yarn offline mirror, under the file names Yarn gives
them, and runs `yarn install --offline --frozen-lockfile` against that mirror
in the sandbox.

`yarn.lock` records no hash for a tarball from another URL, such as a GitHub
dependency that Yarn fetches from `codeload.github.com`, or for a git
dependency. `yarn-classic-purifier lock` records them in
`yarn-classic-purifier.lock.json` at the project root. Commit that file with
`yarn.lock`. A project whose packages all come from a registry has no such
file.

The project's own packages come from its `package.json` files: the root, and
the workspaces that the root's `workspaces` globs name.

### Dependency sources

- A registry package is fetched by the hash in `yarn.lock`.
- A tarball from any other URL, including a GitHub dependency, is fetched by
  the hash in the purifier lockfile.
- Yarn Classic stores a git dependency in its mirror as the `git archive` of
  the locked commit, cloned without submodules. The purifier builds the same
  tarball from a `fetchgit` checkout. When the repository has a `prepare`
  script, Yarn installs the repository with its devDependencies, runs the
  script and packs the result. The lock command records the downloads of the
  repository's own `yarn.lock` for this, and a build runs that install
  offline against them. For a repository without a `yarn.lock`, the lock
  command resolves one once, and the purifier lockfile records its text.
- Yarn reads `file:` directories, `file:` tarballs and `link:` paths from the
  project source. They have to lie inside `src`, because the sandbox sees
  nothing else.
- The workspaces are the directories that the root's `workspaces` names.

## Use

The flake's `overlays.default` adds `buildYarnClassicProject` to a package
set, and a package written for `callPackage` takes it by name:

```nix
# package.nix
{ buildYarnClassicProject }:
(buildYarnClassicProject { src = ./.; }).packages.my-app
```

```nix
{
  inputs.yarn-classic-purifier.url = "github:nix-purifiers/yarn-classic-purifier";
  inputs.nixpkgs.follows = "yarn-classic-purifier/nixpkgs";

  outputs = { nixpkgs, yarn-classic-purifier, ... }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        overlays = [
          yarn-classic-purifier.overlays.default
          (final: prev: { my-app = final.callPackage ./package.nix { }; })
        ];
      };
    in
    {
      packages.${system}.my-app = pkgs.my-app;
    };
}
```

`buildYarnClassicProject` returns these attributes:

- `packages.<name>` is package `<name>` of the project, installed with its
  production dependencies under `lib/node_modules`, with its commands in
  `bin/`. Its `tarball` output holds `package.tgz`, the file `yarn publish`
  uploads.
- `build` is the project after `yarn install`, its build scripts and
  `yarn pack`, as one tarball per package.
- `productionModules` holds the production dependencies
  (`yarn install --production`).
- `dependencies` is the offline mirror.

`nix/lib/build-yarn-classic-project.nix` documents the arguments, among them
`buildScripts` (the scripts that build the project, `[ "build" ]` by
default), `doCheck` (runs the `test` script), `node`, `nativeBuildInputs`,
`buildInputs` and `srcFilter`.

The install runs the dependencies' install scripts and the project's own
lifecycle scripts, as `yarn install` does. Before they run, it patches the
interpreters of scripts and the dynamic loader of prebuilt Linux binaries
in packages, such as Flow's, because the sandbox has neither
`/usr/bin/env` nor `/lib64/ld-linux`. node-gyp builds native addons
against the headers of the Node.js that runs the build. A library that a
native addon links against goes in `buildInputs`.

### The commands

`nix develop github:nix-purifiers/yarn-classic-purifier` gives a shell with
the `yarn` wrapper, the `yarn-classic-purifier` command and Node.js.

- `yarn` runs Yarn offline in a project with a `yarn.lock`, against the
  offline mirror that a build uses, which Nix builds under
  `$XDG_CACHE_HOME/yarn-classic-purifier`. The commands that change
  `yarn.lock` (`add`, `upgrade`, `upgrade-interactive`, `remove` and
  `import`) resolve against the registry, as Yarn does without the wrapper.
  `YARN_CLASSIC_PURIFIER=0` turns the wrapper off.
  `nix run github:nix-purifiers/yarn-classic-purifier -- install` runs it
  without the shell.
- `yarn-classic-purifier lock` writes `yarn-classic-purifier.lock.json`, and
  removes it when `yarn.lock` records everything.
- `yarn-classic-purifier publish <package> [options]` builds the package's
  tarball in the sandbox and runs `yarn publish` on it, with the options
  given. Nothing is compiled outside the sandbox.

## Limitations

- Yarn Classic fetches every locked package before it checks which packages
  fit the platform, and `yarn.lock` does not record a package's platforms.
  The mirror therefore holds the optional packages of every platform, such as
  all of esbuild's per-platform binaries, and it is the same on every system.
- A project whose `.yarnrc` or `.npmrc` sets `yarn-offline-mirror` gets the
  locked tarballs in that directory during a build. The wrapper leaves such a
  project's mirror alone and warns that Yarn reads it.
- A git dependency over ssh from a host other than GitHub, GitLab or
  Bitbucket needs credentials that the sandbox does not have. The purifier
  fetches the https URL for those three hosts.

## Projects tried

- immer at `75a290e44ba14bd723c8ef8546b6559c8ef3ae88` (1,278 locked
  tarballs, no purifier lockfile needed) builds and passes its whole test
  suite in the sandbox: vitest, the tests of the built package and Flow. A
  flake check builds it. Flow's prebuilt binary is why the install patches
  binaries.

## License

MIT
