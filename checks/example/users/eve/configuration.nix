# eve is a SYSTEM-ONLY user: her directory has only a configuration.nix
# and no home.nix, so she gets an account and this NixOS config, but no
# home-manager configuration and no login bootstrap.
{ ... }:
{
  users.groups.backup-operators = { };
}
