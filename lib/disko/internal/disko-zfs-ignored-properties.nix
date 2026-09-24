# PRIVATE, imported by declare-zfs-root-disk.nix and declare-zfs-data-disk.nix.
#
# If the consumer has also enabled numtide/disko-zfs (re-applies disko's own
# declared datasets/properties on every switch and boot, not just at initial
# `disko format` time), these four properties must never be part of what it
# reconciles -- confirmed live against an encrypted, already-provisioned
# pool, via `nixos-rebuild dry-activate`, before ever letting it apply
# anything for real:
#
#   - keylocation: this repo's own migration (see declare-zfs-data-disk.nix's
#     "KEY MIGRATION" doc comment) moves a pool from its ephemeral,
#     hardware-derived install-time key onto a persistent one (e.g.
#     sops-managed) out-of-band, well after disko's own static declaration
#     is written. disko-zfs, seeing only that static declaration, proposed
#     reverting the migration.
#   - encryption / keyformat: ZFS forbids changing these after a dataset
#     already exists -- there is no code path where disko-zfs's attempt to
#     reconcile them can ever succeed, on any run, against any pool. Left
#     un-ignored it just logs the same unfixable error forever.
#   - nixos:*: NixOS's own zfs.nix bookkeeping (confirmed:
#     `nixos:shutdown-time`, set by the shutdown hook), never part of any
#     dataset declaration here. Left un-ignored, disko-zfs strips it via
#     `zfs inherit` on every switch, fighting NixOS's own tracking.
#
# Only imported when the caller passed `usingDiskoZfs = true` (see
# declareZfsRootDisk/declareZfsDataDisk) -- that is the caller's own
# promise that disko-zfs's NixOS module is present, so `disko.zfs` is a
# real, declared option here. Reading `config.disko.zfs.enable` (not
# `options`) to gate on it is safe: `options` is entangled in the same
# fixpoint this code contributes to (checking it caused a genuine
# infinite recursion, confirmed on a real host), but `config` behind a
# lazy `mkIf` is not.
{
  config,
  lib,
  ...
}:
lib.mkIf (config.disko.zfs.enable or false) {
  disko.zfs.settings.ignoredProperties = [
    "keylocation"
    "encryption"
    "keyformat"
    "nixos:*"
  ];
}
