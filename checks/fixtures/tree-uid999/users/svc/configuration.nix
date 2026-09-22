# A real system account: its sibling `_defaults.nix` (isSystemUser = true)
# tells normalUserModule to leave it entirely alone, so it declares its
# own uid, isSystemUser, and group here, as any system account must.
{ ... }:
{
  users.users.svc = {
    uid = 999;
    isSystemUser = true;
    group = "svc";
  };
  users.groups.svc = { };
}
