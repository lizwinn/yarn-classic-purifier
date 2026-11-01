# yarn-classic-purifier

A Nix builder and a Yarn wrapper for projects that use Yarn Classic (Yarn 1)
and its `yarn.lock`. Nix builds the project in its sandbox from what
`yarn.lock` records, and the project needs no Nix files of its own.

For Yarn 2 and later, use
[yarn-berry-purifier](https://github.com/nix-purifiers/yarn-berry-purifier).

## Quickstart

Lock the project once, in its root:

```zsh
nix run github:nix-purifiers/yarn-classic-purifier#yarn-classic-purifier -- lock
```

The command writes `yarn-classic-purifier.lock.json` only when `yarn.lock`
leaves something out, and we recommend committing it with `yarn.lock`. A
project whose packages all come from a registry has no such file.

Build the project with the flake's library:

```nix
{
  inputs.yarn-classic-purifier.url = "github:nix-purifiers/yarn-classic-purifier";
  inputs.nixpkgs.follows = "yarn-classic-purifier/nixpkgs";

  outputs = { nixpkgs, yarn-classic-purifier, ... }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      project = yarn-classic-purifier.lib.yarn-classic-purifier.buildYarnClassicProject {
        inherit pkgs;
        src = ./.;
      };
    in
    {
      packages.${system}.my-app = project.packages.my-app;
      checks.${system}.tests = project.tests;
    };
}
```

`buildYarnClassicProject` returns these attributes:

- `packages.<name>` is package `<name>` of the project, installed with its
  production dependencies under `lib/node_modules`, with its commands in
  `bin/`. The project's packages are the root and the workspaces that the
  root's `workspaces` globs name.
- `tests` is the project after `yarn install`, its build scripts and its
  test scripts, run in the sandbox.
- `release` holds one tarball per package, made by `yarn pack` after the
  build scripts. `yarn-classic-purifier publish` uploads these files.
- `fetches` lists the entries of the
  [purifier](https://github.com/nix-purifiers/purifier) library that the
  build fetches, for tools that read what a build downloads.

Its arguments are `pkgs`, `src` and `fetchers`, and the arguments that
`nix/lib/build-yarn-classic-project.nix` documents: `yarnLock`,
`lockFile`, `buildScripts` (`[ "build" ]` by default), `testScripts`
(`[ "test" ]` by default), `node`, `nativeBuildInputs`, `buildInputs` and
`srcFilter`. `fetchers` replaces fetchers of the purifier library, such as
`fetchurl` with one that sends credentials to a company mirror.

`lib.yarn-classic-purifier.readLock { src, yarnLock ? ..., lockFile ? ... }`
reads `yarn.lock` and the purifier lockfile into the lock in memory of the
purifier contract: `entries` (the library's download entries), `outputs`
(the project's packages), and `problems` (why the lockfiles cannot be
used, each naming the command that fixes it). The builder checks it with
the library's `checkLock`, and tools that read what every purifier
downloads, such as an SBOM generator, can call it directly.

A packaging flake can build a project it does not change. It keeps the
purifier lockfile in its own tree and passes it as `lockFile`, and passes
`yarnLock` too when the project has no `yarn.lock`. A file given this way
replaces any copy in `src`. Every command takes `--lockfile <path>` for
such a file.

## Everyday loop

The everyday loop is Yarn itself, through the flake's `yarn` wrapper:
`yarn install`, `yarn run build` and `yarn test`.
`nix develop github:nix-purifiers/yarn-classic-purifier` gives a shell with
the wrapper, the `yarn-classic-purifier` command and Node.js.

In a project with a `yarn.lock`, the wrapper builds the same offline mirror
that a sandboxed build uses, through Nix, under `.yarn-classic-purifier` in
the project, and runs Yarn offline against it. It rebuilds the mirror when a
lockfile changes. The commands that change `yarn.lock` (`add`, `upgrade`,
`upgrade-interactive`, `remove` and `import`) resolve against the registry,
as Yarn does without the wrapper; run `yarn-classic-purifier lock`
afterwards.

`yarn-classic-purifier update [<package>...]` updates both lockfiles in one
run. It re-resolves the named packages, or all of them, with
`yarn upgrade`, within the ranges that `package.json` declares, and then
locks the purifier lockfile against the new `yarn.lock`.
`yarn-classic-purifier lock` keeps Yarn's resolution as it is.

`YARN_CLASSIC_PURIFIER=0` turns the wrapper off. The purifier lockfile lies
beside `yarn.lock` by default. For a lockfile kept elsewhere, the commands
take `--lockfile <path>` or the environment variable
`YARN_CLASSIC_PURIFIER_LOCKFILE`, the wrapper takes the variable, and the
flag takes precedence over the variable. The dev shell of a flake that
passes `lockFile` to the builder can set the variable to the same path.

The install runs the dependencies' install scripts and the project's own
lifecycle scripts, as `yarn install` does. In the sandbox it first patches
the interpreters of scripts and the dynamic loader of prebuilt Linux
binaries in packages, such as Flow's, because the sandbox has neither
`/usr/bin/env` nor `/lib64/ld-linux`. node-gyp builds native addons
against the headers of the Node.js that runs Yarn. A library that a native
addon links against goes in `buildInputs`.

## Offline work

`yarn-classic-purifier prefetch` builds the offline mirror of the project's
lockfiles and keeps it alive with a garbage-collector root at
`.yarn-classic-purifier/mirror`, in the directory that holds the purifier
lockfile. It also roots the `yarn` wrapper with the Node.js, Yarn, node-gyp
and Python it runs, at `.yarn-classic-purifier/toolchain`. After a prefetch, the `yarn` wrapper
installs, builds and tests the project with the network cut off, until a
lockfile changes. We recommend adding `.yarn-classic-purifier` to
`.gitignore`.

## Editor

Editors read a JavaScript project's tools from its `node_modules`: the
TypeScript server, ESLint and Prettier are dependencies of the project, and
`yarn install` through the wrapper puts them there from the locked
tarballs. After a prefetch, the editor works offline too.

## Errors and fixes

Each error names the command that fixes it.

| Error | Cause | Fix |
| --- | --- | --- |
| `yarn.lock changed since yarn-classic-purifier.lock.json was written` | `yarn.lock` changed after the last lock. | Run `yarn-classic-purifier lock`. |
| `... records nothing for these packages` | A git dependency or a tarball without a hash in `yarn.lock` has no entry in the purifier lockfile. | Run `yarn-classic-purifier lock`. |
| `... was changed after yarn-classic-purifier lock wrote it` | The purifier lockfile was edited by hand, so its content no longer matches its `contentHash`. | Run `yarn-classic-purifier lock`. |
| `... has version ...`, `... holds no JSON object`, `... lacks its contentHash`, `... has a malformed package entry` | The purifier lockfile is not one this version reads. | Run `yarn-classic-purifier lock`. |
| `... is not valid JSON` | The purifier lockfile is not JSON at all. Nix cannot catch a parse error, so the commands check the file first and evaluation fails with this message. | Run `yarn-classic-purifier lock`. |
| `hash mismatch in fixed-output derivation` | A tarball at a locked URL changed. | Check the source, then run `yarn-classic-purifier lock`. |
| `Can't make a request in offline mode` for a tarball | A tarball in the offline mirror differs from the integrity in `yarn.lock`, and Yarn tried to download it. | Run `yarn-classic-purifier prefetch`; if it persists, the mirror was altered. |

## Sources supported and refused

`yarn.lock` records the URL of every tarball the install fetches, and for a
registry tarball an SRI `integrity`, or in older lockfiles a SHA-1 in the
`#` fragment of the URL. Nix reads `yarn.lock` directly at evaluation time,
so its entries are not copied anywhere. The purifier lockfile records only
what `yarn.lock` cannot:

- the hash of a tarball from another URL, such as a GitHub dependency that
  Yarn fetches from `codeload.github.com`;
- for a git dependency, the hash of its checkout and whether its repository
  has a `prepare` script;
- for a repository with a `prepare` script, the entries of the repository's
  own `yarn.lock`, which Yarn installs before it packs the repository, and
  that `yarn.lock` itself when the repository has none.

The sources:

- A registry package is fetched by the hash in `yarn.lock`. A tarball from
  `registry.yarnpkg.com` is also fetched from `registry.npmjs.org` when the
  first fails, and the other way round.
- A tarball from any other URL is fetched by the hash in the purifier
  lockfile.
- Yarn Classic stores a git dependency in its mirror as the `git archive` of
  the locked commit, cloned without submodules. The purifier builds the same
  tarball from a checkout. For a repository with a `prepare` script, a build
  runs the repository's install offline against its recorded entries and
  packs the result.
- Yarn reads `file:` directories, `file:` tarballs and `link:` paths from the
  project source. They have to lie inside `src`, because the sandbox sees
  nothing else.

Limitations:

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

## Examples

CI builds these projects from their own `yarn.lock`, as examples of what
the purifier handles. They are not a full list of the projects that work.

- immer at `75a290e44ba14bd723c8ef8546b6559c8ef3ae88` needs no purifier
  lockfile, because its `yarn.lock` records every tarball. A flake check
  builds it and runs its tests on both systems. On x86_64-linux the tests
  are vitest, the tests of the built package and Flow. The flow-bin 0.123
  that immer pins has no aarch64-linux binary, so on aarch64-linux the tests
  leave Flow out. Flow's prebuilt binary is why the install patches
  binaries.
- `tests/fixtures/remote` locks a git dependency and a GitHub tarball, and
  `tests/fixtures/git-prepare` locks a git dependency whose repository has
  a `prepare` script. CI relocks the first and builds both.

## Credits

yarn-classic-purifier follows the design of
[sbt-nix-backend](https://github.com/nix-purifiers/sbt-purifier): the build
tool keeps planning the build, a lockfile records every download, and Nix
fetches the downloads and runs the build offline in its sandbox. The shared
library of the nix-purifiers,
[purifier](https://github.com/nix-purifiers/purifier), fetches the locked
tarballs and git checkouts.

yarn-classic-purifier is licensed under the MIT license.
