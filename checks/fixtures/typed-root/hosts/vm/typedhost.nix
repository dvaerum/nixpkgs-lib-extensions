# Host config for the `group`/`hostFolder` tests: found via the typed
# convention hosts/<segment>/<hostname>.nix (here: segment = "vm")
{ ... }:
{
  users.groups.typed-host-marker = { };
}
