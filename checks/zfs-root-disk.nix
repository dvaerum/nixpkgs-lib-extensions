# Eval-time tests for lib/disko.declareZfsRootDisk, run by `nix flake check`.
#
# The function returns a NixOS module (normally used via `imports`); here it
# is applied directly with pkgs/lib and a minimal config stub, and the
# resulting disko layout is asserted on.
{ pkgs, myLib }:
let
  lib = pkgs.lib;

  build =
    args:
    (myLib.declareZfsRootDisk (
      {
        devicePath = "/dev/disk/by-id/test-disk";
        hostname = "testhost";
        listOfUsernames = [
          "alice"
          {
            username = "bob";
            mountpoint = "/srv/bob";
          }
        ];
      }
      // args
    ))
      {
        inherit pkgs lib;
        config.boot.initrd.systemd.enable = true;
      };

  plain = build { enableEncryption = false; };
  plainDatasets = plain.disko.devices.zpool."zroot-testhost".datasets;

  withExtra =
    (build {
      enableEncryption = false;
      extraDatasets = {
        "DATA" = {
          type = "zfs_fs";
          options.mountpoint = "none";
        };
        "DATA/media" = {
          type = "zfs_fs";
          mountpoint = "/srv/media";
          options.mountpoint = "legacy";
        };
        # override a generated dataset
        "VAR" = {
          type = "zfs_fs";
          mountpoint = "/var";
          options = {
            mountpoint = "legacy";
            atime = "on";
          };
        };
      };
    }).disko.devices.zpool."zroot-testhost".datasets;

  # does forcing the selected part of the layout with these arguments throw?
  buildThrows =
    args: select:
    !(builtins.tryEval (builtins.deepSeq (select (build args)) true)).success;

  assertions = {
    pool-named-after-hostname = plain.disko.devices.zpool ? zroot-testhost;

    # per-user HOME datasets, string and { username; mountpoint; } forms
    user-datasets-created = plainDatasets ? "HOME/alice" && plainDatasets ? "HOME/bob";
    user-mountpoint-honored = plainDatasets."HOME/bob".options.mountpoint == "/srv/bob";

    # extraDatasets are merged in ...
    extra-dataset-added = withExtra."DATA/media".mountpoint == "/srv/media";
    # ... last, so they can override a generated dataset
    extra-dataset-overrides = withExtra."VAR".options.atime == "on";
    # and the default (no extraDatasets) stays untouched
    no-extra-datasets-by-default =
      !(plainDatasets ? "DATA/media") && !(plainDatasets."VAR".options ? atime);

    # swap partition present by default, gone with swapSize = 0
    swap-by-default = plain.disko.devices.disk.main.content.partitions ? SWAP;
    no-swap-when-zero =
      !(
        (build {
          enableEncryption = false;
          swapSize = 0;
        }).disko.devices.disk.main.content.partitions ? SWAP
      );

    # encryption is on by default and reaches the pool root options
    encryption-on-by-default = (build { }).disko.devices.zpool."zroot-testhost".rootFsOptions.encryption == "on";
    no-encryption-when-disabled = !(plain.disko.devices.zpool."zroot-testhost".rootFsOptions ? encryption);

    # argument validation throws
    invalid-encryption-throws = buildThrows { enableEncryption = "yes"; } (
      r: r.disko.devices.zpool."zroot-testhost".rootFsOptions
    );
    invalid-swap-size-throws =
      buildThrows
        {
          enableEncryption = false;
          swapSize = -1;
        }
        (r: r.disko.devices.disk.main.content.partitions);
    invalid-extra-datasets-throws =
      buildThrows
        {
          enableEncryption = false;
          extraDatasets = 42;
        }
        (r: r.disko.devices.zpool."zroot-testhost".datasets);
  };

  failed = lib.attrNames (lib.filterAttrs (_: ok: ok != true) assertions);
in
if failed == [ ] then
  pkgs.runCommand "zfs-root-disk-tests" { } "touch $out"
else
  throw "declareZfsRootDisk tests failed: ${lib.concatStringsSep ", " failed}"
