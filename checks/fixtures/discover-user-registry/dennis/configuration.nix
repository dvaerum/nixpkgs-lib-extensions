# discoverUserRegistry classification fixture: a directory WITH a
# configuration.nix is a "user" entry -- see checks/discover-user-registry.nix.
{ ... }:
{
  users.groups.discovered-dennis = { };
}
