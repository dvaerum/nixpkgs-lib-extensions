# Registry companion pinning the first NON-reserved uid: `meg` stays a
# normal account, so normalUserModule must still contribute isNormalUser
# and the private primary group.
{ ... }:
{
  users.users.meg.uid = 1000;
}
