# NixOS-level config for dennis in this fixture -- mirrors
# home-manager-config's users/dvv/configuration.nix, which imports a
# sibling user's configuration.nix via `rootPath`. A `configuration.nix`
# needs the SAME loginContext override home.nix already gets: without
# it, `rootPath` here resolves to the CONSUMING flake's own tree, not
# this fixture's -- a bug the original loginContext feature (58e6f23)
# never covered, since `userNixosConfigs` (mk-system.nix) is a
# completely separate code path from the per-user home-manager
# submodule `imports` this file's `home.nix` sibling exercises.
{ rootPath, ... }:
{
  imports = [ (rootPath + /marker/nixos-marker.nix) ];
}
