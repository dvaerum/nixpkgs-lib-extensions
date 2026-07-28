# Host config for the systemType test: found via the typed convention
# hosts/<systemType>/<hostname>.nix (here: systemType = "vm")
{ ... }:
{
  users.groups.typed-host-marker = { };
}
