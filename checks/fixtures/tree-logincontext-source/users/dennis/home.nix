# A fixture that plays the role of a REAL cross-flake `loginFlakeRef`
# source (like home-manager-config) for checks/builders/tests/
# login-context.nix. Mirrors home-manager-config's OWN shape: home.nix
# imports a SIBLING file by a plain relative path (never rootPath --
# that resolves at parse time, same tree, always correct), and THAT
# file is the one using rootPath/specialArgs -- one level of nesting
# deeper than home.nix itself, which is exactly how the real repo is
# built and is NOT something a shallow "wrap the top file" fix reaches.
{ ... }:
{
  imports = [ ./imports.nix ];
  home.username = "dennis";
  home.homeDirectory = "/home/dennis";
  home.stateVersion = "24.05";
}
