# home-manager config for the `frank@*` wildcard entry; applies on every
# host (the checks verify frank's per-host homes include this file)
{ ... }:
{
  programs.git.enable = true;
  home.stateVersion = "26.11";
}
