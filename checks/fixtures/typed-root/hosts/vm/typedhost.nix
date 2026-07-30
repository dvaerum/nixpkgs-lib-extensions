# Host config for the hostGroup test: found via the typed convention
# hosts/<hostGroup>/<hostname>.nix (here: hostGroup = "vm")
{ ... }:
{
  users.groups.typed-host-marker = { };
}
