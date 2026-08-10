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
  # `lib.version` is nixpkgs' release and must keep winning
  version-not-module-level =
    let
      moduleLevel = import (repoDir + "/lib/nixos/internal/module-level.nix") {
        lib = nixpkgs.lib;
        self = myLib;
      };
    in
    !(moduleLevel.moduleLevelLib myLib ? version);
}
