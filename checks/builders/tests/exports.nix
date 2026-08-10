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

  # the singular builders were renamed in 1.0.0; the old names are
  # throwing tombstones (flat and namespaced alike), not silent absences
  renamed-builders-tombstoned =
    !(builtins.tryEval myLib.nixosConfigurationsBuilder).success
    && !(builtins.tryEval myLib.homeConfigurationsBuilder).success
    && !(builtins.tryEval myLib.nixos.nixosConfigurationsBuilder).success
    && !(builtins.tryEval myLib.nixos.homeConfigurationsBuilder).success;
  # tryEval discards the message, so pin the pointer at the source: each
  # tombstone must name its replacement
  renamed-builders-tombstones-name-replacement =
    lib.hasInfix "renamed to `mkNixosSystem`" (
      builtins.readFile (repoDir + "/lib/nixos/mk-nixos-system.nix")
    )
    && lib.hasInfix "renamed to `mkHomeConfiguration`" (
      builtins.readFile (repoDir + "/lib/nixos/mk-home-configuration.nix")
    );

  # `lib.version` is this library's release string (see CHANGELOG.md) ...
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
