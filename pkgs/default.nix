# SPDX-License-Identifier: MIT
{ callPackage, ... }:
{
  # Yarn Classic that reads the locked tarballs through Nix, offline, in a
  # project with a yarn.lock.
  yarn = callPackage ./yarn { };
  # Records the hashes that yarn.lock lacks.
  yarn-classic-purifier = callPackage ./yarn-classic-purifier { };
}
