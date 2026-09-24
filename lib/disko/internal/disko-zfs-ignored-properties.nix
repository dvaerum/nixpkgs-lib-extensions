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
# Guarded on `options.disko.zfs` actually existing: this module is imported
# unconditionally by both callers, but disko-zfs's own module may not be
# imported by every consumer, and `disko.zfs.settings.ignoredProperties`
# isn't a real option unless it is. `options ? disko && options.disko ? zfs`
# checks the option TREE (not `config`), so it never forces evaluation of
# anything -- true precisely when the consumer's own flake also imports
# disko-zfs's NixOS module.
{
  options,
  lib,
  ...
}:
lib.mkIf (options ? disko && options.disko ? zfs) {
  disko.zfs.settings.ignoredProperties = [
    "keylocation"
    "encryption"
    "keyformat"
    "nixos:*"
  ];
}
