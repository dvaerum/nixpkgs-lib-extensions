# resolveUserRegistry auto-discovery integration fixture
# (checks/builders/tests/registry.nix): a flake root shaped like a real
# consumer's, with a users/ directory discoverUserRegistry can scan when
# userRegistry is OMITTED ENTIRELY.
{ ... }:
{
  users.groups.auto-discovered-pat = { };
}
