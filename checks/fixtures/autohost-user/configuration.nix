# The "<user>@*" entry for the auto-detected `hosts/<hostname>` tests
# (checks/builders/tests/registry.nix). Applies on every host; the
# `hosts/autohostprobe/` sibling directory merges in ADDITIONALLY on that
# one host, the same way an explicit "<user>@autohostprobe" entry would.
{ ... }:
{
  users.groups.autohost-base = { };
}
