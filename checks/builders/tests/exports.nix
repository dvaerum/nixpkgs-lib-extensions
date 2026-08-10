# The lib's public surface: what is exported and what stays internal.
{
  lib,
  myLib,
  nixpkgs,
  repoDir,
  ...
}:
{
  all-functions-exported = builtins.all (n: builtins.isFunction myLib.${n}) [
    "mkNixosSystem"
    "buildConfigurations"
    "buildNixosConfigurations"
    "buildHomeConfigurations"
    "mkHomeConfiguration"
    "homeManagerBootstrapModule"
    "normalUserModule"
    "importIfNix"
    "importIfNixOr"
  ];
  internal-helpers-hidden = !(myLib ? mkContext) && !(myLib ? resolveUser);
  fixed-point-assembles = myLib ? stringToTitle;

  # pre-1.0: the pre-rename builder names are simply ABSENT -- no
  # tombstones, no compatibility machinery, flat and namespaced alike
  old-builder-names-absent =
    !(myLib ? nixosConfigurationsBuilder)
    && !(myLib ? homeConfigurationsBuilder)
    && !(myLib.nixos ? nixosConfigurationsBuilder)
    && !(myLib.nixos ? homeConfigurationsBuilder);

  # `lib.version` is this library's release string ...
  version-exported = builtins.match "[0-9]+\\.[0-9]+\\.[0-9]+" myLib.version != null;
  # ... and stays OUT of the module-level half: inside modules,
  # `lib.version` is nixpkgs' release and must keep winning -- and the
  # loader's `_paths` introspection list stays out with it
  version-not-module-level =
    let
      moduleLevel = import (repoDir + "/lib/nixos/internal/module-level.nix") {
        lib = nixpkgs.lib;
        self = myLib;
      };
      moduleLib = moduleLevel.moduleLevelLib myLib;
    in
    !(moduleLib ? version) && !(moduleLib ? _paths);

  # The loader's explicit path list and gen-docs' `find` over lib/ must
  # enumerate the SAME files: a file dropped into lib/ but missing from
  # the loader list would be DOCUMENTED yet unreachable through the lib
  # (and a stale list entry would document nothing). Both directions,
  # compared as sorted path strings; internal/ files and the loader
  # itself (lib/default.nix) are out of scope on both sides, exactly as
  # in scripts/gen-docs.sh.
  loader-list-matches-lib-tree =
    let
      libDir = repoDir + "/lib";
      onDisk = builtins.filter (
        p:
        lib.hasSuffix ".nix" (toString p)
        && !(lib.hasInfix "/internal/" (toString p))
        && toString p != toString (libDir + "/default.nix")
      ) (lib.filesystem.listFilesRecursive libDir);
    in
    lib.sort lib.lessThan (map toString onDisk) == lib.sort lib.lessThan (map toString myLib._paths);
}
