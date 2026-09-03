# Deliberately the SAME username as checks/fixtures/tree-per/users/per --
# the fixture behind the cross-source collision test
# (checks/builders/tests/multi-tree.nix): combining this tree with
# tree-per in one loginFlakeRef list must throw, not silently pick one.
{ ... }:
{
  users.groups.collide-marker-group = { };
}
