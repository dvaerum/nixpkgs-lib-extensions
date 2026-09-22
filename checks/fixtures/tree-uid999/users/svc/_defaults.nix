# Declares svc a SYSTEM account: normalUserModule must leave it entirely
# alone -- see accounts.nix's uid-999-registry-pin-stays-system.
{
  isSystemUser = true;
}
