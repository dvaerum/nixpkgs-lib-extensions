# A NixOS-level module reachable ONLY through THIS tree's own
# `rootPath` -- checks/builders/tests/login-context.nix imports it via
# `(rootPath + /marker/nixos-marker.nix)` from dennis's configuration.nix,
# mirroring home-manager-config's users/dvv/configuration.nix, which
# imports a SIBLING user's configuration.nix the same way.
{ ... }:
{
  users.groups.source-rootpath-nixos-marker = { };
}
