# NixOS companion for the `frank@laptop` entry: host-specific EXTRA
# config that MERGES with (does not replace) the frank@* wildcard entry
{ ... }:
{
  users.groups.scanner = { };
  users.users.frank.extraGroups = [ "scanner" ];
}
