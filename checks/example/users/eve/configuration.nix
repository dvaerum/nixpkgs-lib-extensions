# System-only test fixture: a user directory with ONLY a configuration.nix
# (no home.nix) -- gets NixOS config but no home-manager config/bootstrap
{ ... }:
{
  users.groups.backup-operators = { };
}
