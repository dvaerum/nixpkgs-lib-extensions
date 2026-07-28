# NixOS companion for the `frank@*` wildcard entry: applied on EVERY host
{ ... }:
{
  users.groups.vpn = { };
  users.users.frank.extraGroups = [ "vpn" ];
}
