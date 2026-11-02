# yarn-classic-purifier

yarn-classic-purifier keeps Yarn Classic's development workflow on locked,
Nix-resolved dependencies. Use the normal build and test commands in your
working tree; building the project itself in the Nix sandbox is an
optional next step.

For Yarn 2 and later, use
[yarn-berry-purifier](https://github.com/nix-purifiers/yarn-berry-purifier).

## Installation

Install the integration into your Nix profile once:

```sh
nix profile install \
  'github:nix-purifiers/yarn-classic-purifier#yarn' \
  'github:nix-purifiers/yarn-classic-purifier#yarn-classic-purifier'
```

This installs the `yarn` wrapper. Use it for the locked
development workflow below. The native lockfile can supply the complete
download record; a separate purifier lock is needed for the cases described
below. With no usable lockfile, the wrapper warns on standard error and
runs the ordinary tool with impure resolution.

`nix shell` makes an integration available temporarily instead of installing
it. Keep using the activation steps below where a project environment or
prefetched cache is required.

## Quickstart

Install Nix, then run the following from your existing project's root.
The setup prepares the locked dependencies and the integration that
Yarn Classic's normal commands use:

```zsh
nix develop github:nix-purifiers/yarn-classic-purifier
yarn-classic-purifier lock
yarn install
yarn run build
yarn test
```

Commit the lockfiles that the lock command writes, including the build
tool's own lockfile when it has one. Keep using the project's usual build,
test and editor commands with this setup. Nix provides the locked
dependencies; the development commands above run outside the Nix sandbox.
No project Nix files are needed for this workflow.

Sandboxed builds of the whole project are an optional
[next step](#building-the-project-with-nix).

## Development loop

The development loop is Yarn itself, through the flake's `yarn` wrapper:
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
`yarn-classic-purifier lock` keeps Yarn's resolution as `yarn.lock` holds
it, and writes a `yarn.lock` only for a project that has none, by running
`yarn install` without scripts.

Yarn Classic has no plugin mechanism, so `yarn-classic-purifier` is a
standalone command and the `yarn` wrapper is a script around Yarn.

`YARN_CLASSIC_PURIFIER=0` turns the wrapper off. The purifier lockfile lies
beside `yarn.lock` by default. For lockfiles kept outside the repository,
the commands take `--lockfile <path>` for the purifier lockfile and
`--tool-lockfile <path>` for `yarn.lock`, or the environment variables
`YARN_CLASSIC_PURIFIER_LOCKFILE` and `YARN_CLASSIC_PURIFIER_TOOL_LOCKFILE`.
The wrapper takes the variables, and a flag takes precedence over its
variable. The dev shell of a flake that passes `lockFile` and `yarnLock` to
the builder can set the variables to the same paths. With a tool lockfile,
`lock` and `update` write the `yarn.lock` there and leave the project's own
copy as it is, starting from that copy when the tool lockfile does not
exist yet. The development loop itself runs Yarn on the project's own
`yarn.lock`, so an external build suits a project that one packages without
developing it.

The install runs the dependencies' install scripts and the project's own
lifecycle scripts, as `yarn install` does. In the sandbox it first patches
the interpreters of scripts and the dynamic loader of prebuilt Linux
binaries in packages, such as Flow's, because the sandbox has neither
`/usr/bin/env` nor `/lib64/ld-linux`. node-gyp builds native addons
against the headers of the Node.js that runs Yarn. A library that a native
addon links against goes in `buildInputs`.

## Building the project with Nix

Once the native development workflow is working, you can also build and
test the whole project in the Nix sandbox. For this step, keep a flake or
another Nix build definition in the project's repository, or maintain an
external packaging repository that points at its sources and lockfiles.
The builder consumes the same lockfiles as the development workflow.

The flake's `overlays.default` adds one attribute to a package set: the
scope `yarn-classic-purifier`, made with `lib.makeScope`. The scope holds
the builder `buildYarnClassicProject`, the command `yarn-classic-purifier`
and the `yarn` wrapper.

A project whose authors want a flake can package itself with one. The flake
calls the builder directly, and it can live in the project's repository or
in another one:

```nix
{
  inputs.yarn-classic-purifier.url = "github:nix-purifiers/yarn-classic-purifier";
  inputs.nixpkgs.follows = "yarn-classic-purifier/nixpkgs";

  outputs =
    { nixpkgs, yarn-classic-purifier, ... }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        overlays = [ yarn-classic-purifier.overlays.default ];
      };
      project = pkgs.yarn-classic-purifier.buildYarnClassicProject {
        src = ./.;
      };
    in
    {
      packages.${system}.my-app = project.packages.my-app;
      checks.${system}.tests = project.tests;
    };
}
```

`yarn-classic-purifier.overrideScope` replaces what everything in the
scope shares, and `buildYarnClassicProject.override` replaces the packages
that the builder takes by name, such as `nodejs`. The builder returns these
attributes:

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

The builder takes `src`, the root of the project, `lockFile`, the purifier
lockfile, and `yarnLock`, Yarn's lockfile. The defaults are the files in
`src`. It also takes the arguments that
`nix/lib/build-yarn-classic-project.nix` documents: `buildScripts`
(`[ "build" ]` by default), `testScripts` (`[ "test" ]` by default), `node`,
`nativeBuildInputs`, `buildInputs` and `srcFilter`. The argument `fetchers`
replaces fetchers of the purifier library. A `fetchurl` that sends
credentials to a company mirror goes there.

`lib.yarn-classic-purifier.readLock { src, yarnLock ? ..., lockFile ? ... }`
reads `yarn.lock` and the purifier lockfile into the lock in memory of the
purifier contract: `entries` (the library's download entries), `outputs`
(the project's packages), and `problems` (why the lockfiles cannot be
used, each naming the command that fixes it). The builder checks it with
the library's `checkLock`, and tools that read what every purifier
downloads, such as an SBOM generator, can call it directly.

A build can also keep its lockfiles outside the repository, which is an
option for packaging a project that one does not change. The flake that
calls the builder keeps the purifier lockfile in its own tree and passes it
as `lockFile`. It can also keep its own copy of `yarn.lock` and pass it as
`yarnLock`, which the build then uses in place of the copy in `src`. A file
given this way replaces any copy in `src`. The commands take
`--lockfile <path>` for the purifier lockfile and `--tool-lockfile <path>`
for `yarn.lock`; the Development loop section describes them.

### One-off builds without a project Nix file

For an ad hoc build, the builder can also be evaluated directly from the
project root. Replace the example package name with one from your project:

```zsh
nix build --impure --expr 'let
  purifier = builtins.getFlake "github:nix-purifiers/yarn-classic-purifier";
  pkgs = import purifier.inputs.nixpkgs {
    system = builtins.currentSystem;
    overlays = [ purifier.overlays.default ];
  };
in
(pkgs.yarn-classic-purifier.buildYarnClassicProject {
  src = ./.;
}).packages.my-app'
```

This uses the purifier's pinned nixpkgs, matching the lock command above.
To build with ambient `<nixpkgs>` from your Nix search path instead,
replace `import purifier.inputs.nixpkgs` with `import <nixpkgs>`.
Both forms need no Nix files in your project. The build tool and language
versions must match the lockfile; with ambient nixpkgs, lock with the
purifier from that package set or pass a compatible toolchain to the builder.

## Working offline

`yarn-classic-purifier prefetch` builds the offline mirror of the project's
lockfiles and keeps it alive with a garbage-collector root at
`.yarn-classic-purifier/mirror`, in the directory that holds the purifier
lockfile. It also roots the `yarn` wrapper with the Node.js, Yarn, node-gyp
and Python it runs, at `.yarn-classic-purifier/toolchain`. After a
prefetch, the `yarn` wrapper installs, builds and tests the project with
the network cut off, until a lockfile changes. We recommend adding `.yarn-classic-purifier` to
`.gitignore`.

## Editor

Editors read a JavaScript project's tools from its `node_modules`: the
TypeScript server, ESLint and Prettier are dependencies of the project, and
`yarn install` through the wrapper puts them there from the locked
tarballs. After a prefetch, the editor works offline too.

## Troubleshooting

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

## Supported language repositories

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
  No entry of the lock in memory carries `systems` for that reason.
- A project whose `.yarnrc` or `.npmrc` sets `yarn-offline-mirror` gets the
  locked tarballs in that directory during a build. The wrapper leaves such a
  project's mirror alone and warns that Yarn reads it.
- A git dependency over ssh from a host other than GitHub, GitLab or
  Bitbucket needs credentials that the sandbox does not have. The purifier
  fetches the https URL for those three hosts.
- A package that ships a prebuilt binary only for some systems fails on the
  others. Leave the script that runs it out of `buildScripts` and
  `testScripts` on those systems. For example, old versions of the Flow type
  checker have no aarch64-linux binary.

## Examples

For day-to-day work on these projects, use the native-tool setup and
commands in [Quickstart](#quickstart) and [Development loop](#development-loop).
The Nix expressions below show optional sandboxed packaging of those
projects.

### immer

[immer](https://github.com/immerjs/immer) is a TypeScript library that
builds with Yarn Classic. To work on it with the locked downloads, clone it
and lock it:

```zsh
git clone https://github.com/immerjs/immer
cd immer
nix run \
  'github:nix-purifiers/yarn-classic-purifier#yarn-classic-purifier' -- lock
```

immer's `yarn.lock` records every tarball, so the command reports that no
purifier lockfile is needed and writes none. Build the library from the
clone:

```zsh
nix build --impure --expr 'let
  purifier = builtins.getFlake "github:nix-purifiers/yarn-classic-purifier";
  pkgs = import purifier.inputs.nixpkgs {
    system = builtins.currentSystem;
    overlays = [ purifier.overlays.default ];
  };
in
(pkgs.yarn-classic-purifier.buildYarnClassicProject {
  src = ./.;
}).packages.immer'
```

To work on it, fetch everything that development needs, and use Yarn as
usual from the dev shell:

```zsh
nix run \
  'github:nix-purifiers/yarn-classic-purifier#yarn-classic-purifier' -- prefetch
nix develop github:nix-purifiers/yarn-classic-purifier
yarn install
yarn build
yarn test:src
```

A packaging flake can build immer without changing it. It takes immer as a
source input and gives the builder the scripts to run:

```nix
{
  inputs.yarn-classic-purifier.url = "github:nix-purifiers/yarn-classic-purifier";
  inputs.nixpkgs.follows = "yarn-classic-purifier/nixpkgs";
  inputs.immer = {
    url = "github:immerjs/immer";
    flake = false;
  };

  outputs =
    {
      nixpkgs,
      yarn-classic-purifier,
      immer,
      ...
    }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        overlays = [ yarn-classic-purifier.overlays.default ];
      };
      project = pkgs.yarn-classic-purifier.buildYarnClassicProject {
        src = immer;
        testScripts = [
          "test:src"
          "test:build"
        ];
      };
    in
    {
      packages.${system}.immer = project.packages.immer;
      checks.${system}.tests = project.tests;
    };
}
```

`nix build` in the directory of that flake then builds the library, and
`nix flake check` runs its tests in the sandbox.

### A project whose `yarn.lock` leaves hashes out

A project with a GitHub or git dependency needs the purifier lockfile. In
the project, run the lock command and commit both lockfiles:

```zsh
nix run \
  'github:nix-purifiers/yarn-classic-purifier#yarn-classic-purifier' -- lock
git add yarn.lock yarn-classic-purifier.lock.json
```

### A packaging flake for a project one does not change

A flake that packages someone else's project can keep both lockfiles in its
own tree. In a clone of the project, run:

```zsh
nix run \
  'github:nix-purifiers/yarn-classic-purifier#yarn-classic-purifier' -- lock --lockfile ../packaging/my-project.lock.json --tool-lockfile ../packaging/my-project.yarn.lock
```

The clone's own `yarn.lock` stays as it is, and the new `yarn.lock` starts
from it. Then pass both files to the builder with
`lockFile = ./my-project.lock.json;` and `yarnLock = ./my-project.yarn.lock;`.
Later `update` and `prefetch` runs take the same flags, or the variables
`YARN_CLASSIC_PURIFIER_LOCKFILE` and `YARN_CLASSIC_PURIFIER_TOOL_LOCKFILE`.

## Credits

The purifier idea was inspired by nixcloud's
[cargo (libnix)](https://github.com/nixcloud/cargo).

Released under the MIT license; see [LICENSE](LICENSE).
