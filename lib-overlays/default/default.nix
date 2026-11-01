# SPDX-License-Identifier: MIT
#
# The `yarn-classic-purifier` library namespace. It holds nothing: the
# builder needs a package set, so it is the package
# `buildYarnClassicProject` that the default package overlay adds.
{ ... }:
{

  overlay = final: prev: {
    yarn-classic-purifier = prev.yarn-classic-purifier or { };
  };

}
