# The home-manager counterpart of ./valid.nix: the builder hands the same
# specialArgs to both mechanisms, so both sides of the imports-list case
# are worth pinning.
{ lib, ... }:
{
  home.sessionVariables.FROM_IMPORT_IF_NIX = "1";
}
