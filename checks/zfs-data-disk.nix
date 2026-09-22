# Eval-time tests for lib/disko.declareZfsDataDisk, run by `nix flake check`.
#
# Same approach as checks/zfs-root-disk.nix: the function returns a NixOS
# module, applied directly here with pkgs/lib and a minimal config stub, and
# the resulting disko layout / boot wiring is asserted on without building
# anything real (disko itself is not a flake input of this repo -- see
# lib/disko/README.md).
{
  pkgs,
  myLib,
}:
let
  lib = pkgs.lib;

  minimalConfig = {
    config.boot.zfs.package = pkgs.zfs;
  };

  build =
    args:
    (myLib.declareZfsDataDisk (
      {
        name = "bulk";
        vdevs = [
          {
            mode = "mirror";
            devicePaths = [
              "/dev/disk/by-id/d1"
              "/dev/disk/by-id/d2"
            ];
          }
        ];
      }
      // args
    ))
      ({ inherit pkgs lib; } // minimalConfig);

  # does forcing the selected part of the result with these arguments throw?
  buildThrows =
    args: select: !(builtins.tryEval (builtins.deepSeq (select (build args)) true)).success;

  plain = build { enableEncryption = false; };
  plainDevices = plain.disko.devices;
  plainZpool = plainDevices.zpool."zdata-bulk";

  # ── multi-vdev topology (two mirrors, RAID10-style) ──
  twoMirrors = build {
    enableEncryption = false;
    vdevs = [
      {
        mode = "mirror";
        devicePaths = [
          "/dev/disk/by-id/a1"
          "/dev/disk/by-id/a2"
        ];
      }
      {
        mode = "mirror";
        devicePaths = [
          "/dev/disk/by-id/b1"
          "/dev/disk/by-id/b2"
        ];
      }
    ];
  };
  twoMirrorsVdevs = twoMirrors.disko.devices.zpool."zdata-bulk".mode.topology.vdev;
  twoMirrorsDisks = twoMirrors.disko.devices.disk;

  # ── mixed modes (one mirror + one raidz2) in one pool -- allowed, no
  # restriction on consistency across vdevs ──
  mixedModes = build {
    enableEncryption = false;
    vdevs = [
      {
        mode = "mirror";
        devicePaths = [
          "/dev/disk/by-id/m1"
          "/dev/disk/by-id/m2"
        ];
      }
      {
        mode = "raidz2";
        devicePaths = [
          "/dev/disk/by-id/r1"
          "/dev/disk/by-id/r2"
          "/dev/disk/by-id/r3"
        ];
      }
    ];
  };

  withExtra = build {
    enableEncryption = false;
    extraDatasets = {
      "DATA/libvirt" = {
        type = "zfs_fs";
        options = { };
      };
      # override DATA itself
      "DATA" = {
        type = "zfs_fs";
        options = {
          mountpoint = "/data";
          atime = "on";
        };
      };
    };
  };

  assertions = {
    # ── naming: name/nameFn ──
    pool-named-after-name = plainDevices.zpool ? zdata-bulk;
    name-fn-overrides-default-naming =
      (build { nameFn = n: "storage-${n}"; }).disko.devices.zpool ? storage-bulk;

    # ── single vdev, mirror ──
    single-vdev-two-disks =
      (plainDevices.disk ? "zdata-bulk-vdev0-disk0") && (plainDevices.disk ? "zdata-bulk-vdev0-disk1");
    # `type = "topology"` is REQUIRED by disko's own subType dispatch --
    # a separate, freeform-typed mini-`evalModules` reads it from the
    # RAW input before the real `topology` submodule (whose OWN `type`
    # option happens to default to the same string) ever applies that
    # default. Omitting it throws "the option `type' was accessed but
    # has no value defined" against REAL disko -- confirmed directly,
    # not something this repo's own disko-independent tests would
    # otherwise catch (see lib/disko/README.md).
    topology-type-is-set = plainZpool.mode.topology.type == "topology";
    single-vdev-mode-is-mirror = (lib.head plainZpool.mode.topology.vdev).mode == "mirror";
    single-vdev-members-match-disk-attrs =
      (lib.head plainZpool.mode.topology.vdev).members == [
        "zdata-bulk-vdev0-disk0"
        "zdata-bulk-vdev0-disk1"
      ];

    # ── multi-vdev topology: two SEPARATE mirror vdevs, not one 4-way
    # mirror -- disko-real topology form, not the flat string form ──
    two-mirror-vdevs-produced = lib.length twoMirrorsVdevs == 2;
    two-mirror-vdevs-both-mirror-mode = builtins.all (v: v.mode == "mirror") twoMirrorsVdevs;
    two-mirror-vdevs-disk-attrs-scoped-by-vdev-index =
      (twoMirrorsDisks ? "zdata-bulk-vdev0-disk0")
      && (twoMirrorsDisks ? "zdata-bulk-vdev0-disk1")
      && (twoMirrorsDisks ? "zdata-bulk-vdev1-disk0")
      && (twoMirrorsDisks ? "zdata-bulk-vdev1-disk1");

    # ── mixed modes across vdevs in one pool: allowed ──
    mixed-vdev-modes-allowed =
      let
        vdev = mixedModes.disko.devices.zpool."zdata-bulk".mode.topology.vdev;
      in
      lib.length vdev == 2
      && (lib.elem "mirror" (map (v: v.mode) vdev))
      && (lib.elem "raidz2" (map (v: v.mode) vdev));

    # ── mode = null (independent single disk): exactly one devicePaths ──
    mode-null-single-disk-ok =
      !(buildThrows {
        vdevs = [
          {
            mode = null;
            devicePaths = [ "/dev/disk/by-id/solo" ];
          }
        ];
      } (r: r.disko.devices.zpool));
    mode-null-multi-disk-throws = buildThrows {
      vdevs = [
        {
          mode = null;
          devicePaths = [
            "/dev/disk/by-id/x1"
            "/dev/disk/by-id/x2"
          ];
        }
      ];
    } (r: r.disko.devices.zpool);

    # ── per-mode minimum devicePaths, disko itself does not enforce this ──
    mirror-one-disk-throws = buildThrows {
      vdevs = [
        {
          mode = "mirror";
          devicePaths = [ "/dev/disk/by-id/only1" ];
        }
      ];
    } (r: r.disko.devices.zpool);
    mirror-two-disks-ok =
      !(buildThrows {
        vdevs = [
          {
            mode = "mirror";
            devicePaths = [
              "/dev/disk/by-id/m1"
              "/dev/disk/by-id/m2"
            ];
          }
        ];
      } (r: r.disko.devices.zpool));
    raidz2-two-disks-throws = buildThrows {
      vdevs = [
        {
          mode = "raidz2";
          devicePaths = [
            "/dev/disk/by-id/r1"
            "/dev/disk/by-id/r2"
          ];
        }
      ];
    } (r: r.disko.devices.zpool);
    raidz2-three-disks-ok =
      !(buildThrows {
        vdevs = [
          {
            mode = "raidz2";
            devicePaths = [
              "/dev/disk/by-id/r1"
              "/dev/disk/by-id/r2"
              "/dev/disk/by-id/r3"
            ];
          }
        ];
      } (r: r.disko.devices.zpool));
    raidz3-three-disks-throws = buildThrows {
      vdevs = [
        {
          mode = "raidz3";
          devicePaths = [
            "/dev/disk/by-id/r1"
            "/dev/disk/by-id/r2"
            "/dev/disk/by-id/r3"
          ];
        }
      ];
    } (r: r.disko.devices.zpool);
    raidz3-four-disks-ok =
      !(buildThrows {
        vdevs = [
          {
            mode = "raidz3";
            devicePaths = [
              "/dev/disk/by-id/r1"
              "/dev/disk/by-id/r2"
              "/dev/disk/by-id/r3"
              "/dev/disk/by-id/r4"
            ];
          }
        ];
      } (r: r.disko.devices.zpool));
    invalid-mode-string-throws = buildThrows {
      vdevs = [
        {
          mode = "stripe";
          devicePaths = [ "/dev/disk/by-id/x1" ];
        }
      ];
    } (r: r.disko.devices.zpool);

    # ── vdevs shape guards ──
    vdevs-not-a-list-throws = buildThrows { vdevs = "bulk"; } (r: r.disko.devices.zpool);
    vdevs-empty-throws = buildThrows { vdevs = [ ]; } (r: r.disko.devices.zpool);
    vdev-not-an-attrset-throws = buildThrows { vdevs = [ "not-an-attrset" ]; } (
      r: r.disko.devices.zpool
    );
    vdev-missing-device-paths-throws = buildThrows { vdevs = [ { mode = null; } ]; } (
      r: r.disko.devices.zpool
    );
    vdev-device-paths-not-a-list-throws = buildThrows {
      vdevs = [
        {
          mode = null;
          devicePaths = "/dev/disk/by-id/d1";
        }
      ];
    } (r: r.disko.devices.zpool);

    # ── duplicate device path across vdevs ──
    duplicate-device-path-throws = buildThrows {
      vdevs = [
        {
          mode = null;
          devicePaths = [ "/dev/disk/by-id/dup" ];
        }
        {
          mode = null;
          devicePaths = [ "/dev/disk/by-id/dup" ];
        }
      ];
    } (r: r.disko.devices.disk);

    # ── poolMountpoint: default, custom, null ──
    pool-mountpoint-default-is-data = plainZpool.datasets.DATA.options.mountpoint == "/data";
    pool-mountpoint-custom =
      (build { poolMountpoint = "/srv/bulk"; })
      .disko.devices.zpool."zdata-bulk".datasets.DATA.options.mountpoint == "/srv/bulk";
    pool-mountpoint-null-is-none =
      (build { poolMountpoint = null; }).disko.devices.zpool."zdata-bulk".datasets.DATA.options.mountpoint
      == "none";

    # ── extraDatasets: merged, and can override DATA itself ──
    extra-dataset-added = withExtra.disko.devices.zpool."zdata-bulk".datasets ? "DATA/libvirt";
    extra-dataset-overrides-data =
      withExtra.disko.devices.zpool."zdata-bulk".datasets.DATA.options.atime == "on";

    # ── boot wiring: extraPools/forceImportAll, every pool contributes
    # its own name (list concatenates across multiple declareZfsDataDisk
    # calls automatically through the module system) ──
    extra-pools-contains-this-pool = plain.boot.zfs.extraPools == [ "zdata-bulk" ];
    force-import-all-defaulted-true = plain.boot.zfs.forceImportAll.content == true;
    # `requestEncryptionCredentials` is a SINGLE, host-wide option --
    # `declareZfsRootDisk` sets it to a plain `[ ]` to opt root's own
    # dataset out of a redundant boot-time prompt, which (a plain list
    # beating the option's own `true` default) silently disables
    # automatic key-loading for EVERY pool unless something ELSE asks
    # for its own pool explicitly. Confirmed on a real deployment (see
    # the commit this landed in): `zdata-bulk` imported but never
    # unlocked until this was added.
    request-encryption-credentials-contains-this-pool =
      (build { }).boot.zfs.requestEncryptionCredentials == [ "zdata-bulk" ];
    no-request-encryption-credentials-without-encryption =
      (build { enableEncryption = false; }).boot.zfs.requestEncryptionCredentials == [ ];

    # ── the ephemeral default key file must live under `/run`, not
    # `/tmp`: unlike `declareZfsRootDisk` (whose key-write and key-load
    # both happen inside the initrd's own throwaway /tmp), this
    # function's key-writer and NixOS's own automatic key-load happen in
    # the real, post-switch_root system, where /tmp can itself be a real
    # ZFS mount (`useZfsForTmp = true`) that mounts LATER in boot than
    # the key-writer runs -- confirmed on a real deployment: the key
    # file was written, then silently shadowed once the real /tmp
    # mounted on top of it, so the pool's automatic key-load found
    # nothing there and failed to unlock. /run is always tmpfs, mounted
    # essentially at the start of boot, so it carries no such race.
    ephemeral-default-key-under-run-not-tmp =
      let
        keylocation = (build { }).disko.devices.zpool."zdata-bulk".rootFsOptions.keylocation;
      in
      lib.hasPrefix "file:///run/" keylocation && !(lib.hasInfix "/tmp/" keylocation);

    # ── enableEncryption = false: no key units at all ──
    no-key-units-without-encryption = plain.systemd.services == { };
    # ── enableEncryption = true (default), keyFilePath left at the
    # default: only the key-writer exists -- the migrate unit is
    # skipped ENTIRELY (not just given an empty script): a `[Service]`
    # with no `ExecStart=` at all is not just an inert no-op, it is a
    # unit systemd itself rejects as "bad unit file setting" -- found
    # on the same real deployment above. ──
    key-writer-present-with-encryption = (build { }).systemd.services ? "zfs-data-key-zdata-bulk";
    no-migrate-unit-at-default-key-file-path =
      !((build { }).systemd.services ? "zfs-data-key-migrate-zdata-bulk");
    key-writer-ordered-before-import =
      let
        m = build { };
      in
      lib.elem "zfs-import-zdata-bulk.service" m.systemd.services."zfs-data-key-zdata-bulk".before;
    # a custom keyFilePath DOES produce the migrate unit, ordered after
    # import, with a real (non-empty) script
    migrate-unit-present-with-custom-key-file-path =
      let
        m = build { keyFilePath = "/run/secrets/zdata-bulk.key"; };
      in
      m.systemd.services ? "zfs-data-key-migrate-zdata-bulk";
    migrate-ordered-after-import =
      let
        m = build { keyFilePath = "/run/secrets/zdata-bulk.key"; };
      in
      lib.elem "zfs-import-zdata-bulk.service" m.systemd.services."zfs-data-key-migrate-zdata-bulk".after;
    migrate-script-nonempty-with-custom-key-file-path =
      let
        m = build { keyFilePath = "/run/secrets/zdata-bulk.key"; };
      in
      m.systemd.services."zfs-data-key-migrate-zdata-bulk".script != "";

    # ── two declareZfsDataDisk calls on one host: no collisions ──
    two-instances-no-disk-attr-collision =
      let
        a = build { name = "fast"; };
        b = build { name = "bulk"; };
        merged = a.disko.devices.disk // b.disko.devices.disk;
      in
      (lib.length (lib.attrNames merged)) == 4 # 2 disks each, all distinct names
      && merged ? "zdata-fast-vdev0-disk0"
      && merged ? "zdata-bulk-vdev0-disk0";
    two-instances-no-service-collision =
      let
        a = build { name = "fast"; };
        b = build { name = "bulk"; };
      in
      (a.systemd.services ? "zfs-data-key-zdata-fast")
      && (b.systemd.services ? "zfs-data-key-zdata-bulk")
      && !(a.systemd.services ? "zfs-data-key-zdata-bulk");
  };

  runner = import ./run-assertions.nix { inherit pkgs; };
in
runner.run "zfs-data-disk-tests" assertions
