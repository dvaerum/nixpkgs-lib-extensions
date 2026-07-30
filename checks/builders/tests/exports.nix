# The lib's public surface: what is exported and what stays internal.
{ myLib, ... }:
{
  all-functions-exported = builtins.all (n: builtins.isFunction myLib.${n}) [
    "nixosConfigurationsBuilder"
    "buildConfigurations"
    "buildNixosConfigurations"
    "buildHomeConfigurations"
    "homeConfigurationsBuilder"
    "homeManagerBootstrapModule"
    "normalUserModule"
    "importIfNix"
    "importIfNixOr"
  ];
  internal-helpers-hidden = !(myLib ? mkContext) && !(myLib ? resolveUser);
  fixed-point-assembles = myLib ? stringToTitle;
}
