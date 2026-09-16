# Fixture home for checks/builders/tests/user-defaults.nix -- content is
# irrelevant to what's tested; only its existence (and stateVersion, to
# avoid the unrelated pin warning) matters.
{ ... }:
{
  home.stateVersion = "26.11";
}
