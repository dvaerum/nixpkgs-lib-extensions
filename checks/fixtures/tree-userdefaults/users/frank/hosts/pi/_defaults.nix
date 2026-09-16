# Host-directory file with NO base users/frank/_defaults.nix -- the
# `alice@laptop`-style conflict check (cycle 8) is exercised against
# this user in checks/example/flake.nix-style host declarations by the
# test harness, which sets a CONTRADICTING host `system`.
{
  system = "aarch64-linux";
}
