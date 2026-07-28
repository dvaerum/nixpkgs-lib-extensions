# NixOS companion for the plain `grace` entry. Because `grace@*` exists,
# this plain entry is SHADOWED and never applied on any host -- the checks
# assert the `grace-legacy` group does NOT appear in a built system.
{ ... }:
{
  users.groups.grace-legacy = { };
}
