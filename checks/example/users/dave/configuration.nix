# NixOS companion module for the `dave` test fixture: creates a group,
# the kind of system-level config a user directory ships alongside home.nix
{ ... }:
{
  users.groups.media = { };
}
