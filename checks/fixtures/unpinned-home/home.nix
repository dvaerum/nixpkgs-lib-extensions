# A home.nix that deliberately does NOT pin home.stateVersion: the
# fixture behind the warn-on-default stateVersion tests
# (checks/builders/tests/homes.nix). Lives here rather than in the
# example, which doubles as the `nix flake init` template and must not
# warn on first use.
{ ... }: { }
