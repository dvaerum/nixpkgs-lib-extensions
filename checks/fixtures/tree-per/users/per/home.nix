# per's home-manager configuration -- exists so the multi-tree trust
# tests (checks/builders/tests/multi-tree.nix) can prove an untrusted
# source's home.nix still applies (trust only ever gates configuration.nix).
{ ... }:
{
  home.stateVersion = "26.11";
}
