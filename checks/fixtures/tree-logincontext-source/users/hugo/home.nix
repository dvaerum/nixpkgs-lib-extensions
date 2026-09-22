# A second, dedicated user in this fixture -- kept SEPARATE from
# dennis (used by ~10 other login-context.nix assertions) so this
# user's own users/hugo/_defaults.nix can't interact with those.
{ ... }:
{
  home.username = "hugo";
  home.homeDirectory = "/home/hugo";
  home.stateVersion = "24.05";
}
