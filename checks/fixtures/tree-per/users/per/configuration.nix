# Marker for the multi-tree trust tests
# (checks/builders/tests/multi-tree.nix): a distinct group name proves
# whether THIS configuration.nix was imported (source trusted via
# `allowNixosConfig = true`) or dropped (the default, untrusted).
{ ... }:
{
  users.groups.per-marker-group = { };
}
