# Registry companion pinning a RESERVED uid (below 1000): `svc` is a
# system account, so normalUserModule must leave it entirely alone -- and
# it declares its own isSystemUser/group, as real system accounts do.
{ ... }:
{
  users.users.svc = {
    uid = 999;
    isSystemUser = true;
    group = "svc";
  };
  users.groups.svc = { };
}
