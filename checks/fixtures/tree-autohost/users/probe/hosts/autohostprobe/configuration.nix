# Auto-detected per-host override for the `autohost-user` "@*" entry --
# picked up ONLY when the host is `autohostprobe`, merged alongside
# ../../configuration.nix rather than replacing it.
{ ... }:
{
  users.groups.autohost-override = { };
}
