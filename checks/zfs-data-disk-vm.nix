# Real-boot VM test for declareZfsDataDisk's key-writer + migration units,
# run by `nix flake check`. Verifies what only a real boot can: that NixOS's
# own `zfs-import-<pool>.service` really does auto-unlock the pool using the
# key our writer produces, and that a real `zfs change-key` genuinely
# migrates the pool and survives further reboots.
#
# No disko involved (same reasoning as checks/zfs-passphrase-newline.nix):
# this repo does not depend on disko at all -- declareZfsDataDisk's
# `disko.devices` output is exercised structurally in checks/zfs-data-disk.nix
# instead. Here, only the function's `systemd.services`/`boot.zfs.*` output
# is spliced into the VM node directly, and the pool itself is created
# against a file-backed vdev, matching what disko would otherwise do.
{
  pkgs,
  myLib,
}:
let
  lib = pkgs.lib;

  poolName = "zdata-testpool";
  migratedKeyFilePath = "/etc/zdata-testpool.key";

  # `keySourceCommand` bypasses the hardware-identity dispatch entirely --
  # this test is about boot SEQUENCING and MIGRATION, not the
  # dmidecode/cpuinfo dispatch itself (already covered by
  # checks/zfs-key-file.nix and checks/zfs-data-key-file.nix), so a fixed,
  # deterministic key needs no dmidecode stub inside the VM at all.
  dataModule =
    (myLib.declareZfsDataDisk {
      name = "testpool";
      vdevs = [
        {
          mode = null;
          devicePaths = [ "/var/lib/pool.img" ];
        }
      ];
      keyFilePath = migratedKeyFilePath;
      keySourceCommand = "KEY=fixed-test-key";
    })
      {
        inherit pkgs lib;
        config.boot.zfs.package = pkgs.zfs;
      };
in
pkgs.testers.runNixOSTest {
  name = "zfs-data-disk-key-migration";

  nodes.machine = {
    boot.supportedFilesystems.zfs = true;
    # ZFS lags the newest kernel; the LTS one is always supported.
    boot.kernelPackages = pkgs.linuxPackages;
    networking.hostId = "deadbeef";
    virtualisation.memorySize = 2048;

    imports = [
      # Mimics `declareZfsRootDisk`'s own plain `boot.zfs.
      # requestEncryptionCredentials = [ ];` -- a SEPARATE module
      # contribution (not something spliced from `dataModule` by hand),
      # so the module system actually has to CONCATENATE two plain-list
      # definitions of this single, host-wide option. Skipping this and
      # relying on NixOS's own unrelated `true` default is exactly what
      # let the real regression this test guards against ship in the
      # first place: `declareZfsDataDisk`'s pool imported fine, but its
      # key was never requested, because nothing had asked for it by
      # name and this option's default no longer applied once another
      # module (like declareZfsRootDisk, on any real host that also has
      # a root disk) defined it as a plain, competing list.
      { boot.zfs.requestEncryptionCredentials = [ ]; }
    ];

    # Only the parts that do not depend on disko -- see the top-of-file
    # comment. `boot.zfs.forceImportAll` arrives already `lib.mkDefault`
    # wrapped from the function itself; splicing it in here as a plain
    # RHS still works, since the module system reads the tag on the
    # VALUE, not which module wrote it.
    inherit (dataModule) systemd;
    boot.zfs = {
      inherit (dataModule.boot.zfs)
        extraPools
        forceImportAll
        requestEncryptionCredentials
        ;
      # This VM test uses a FILE-backed vdev (no disko, no real disk --
      # see the top-of-file comment), so NixOS's own default search
      # directory for `zpool import -d` (/dev/disk/by-id) never finds
      # it; it needs to search wherever the file actually lives instead.
      # A real machine's real disks stay discoverable via the real
      # default, so this is a test-only override, not something
      # declareZfsDataDisk itself should ever set.
      devNodes = "/var/lib";
      # This VM's root filesystem is NOT zfs at all -- the test
      # framework's own qemu-vm module defaults this to false in that
      # case, which conflicts with `forceImportAll`'s own assertion
      # ("if you enable forceImportAll you must also enable
      # forceImportRoot"). Irrelevant either way here (there is no ZFS
      # root pool to import), just needs to be `true` to satisfy it.
      forceImportRoot = true;
    };
  };

  testScript = ''
    machine.start(allow_reboot=True)
    machine.wait_for_unit("multi-user.target")

    # ── first boot: the pool does not exist yet. The key-writer still
    # runs (nothing depends on the pool existing to write a key file),
    # the import unit fails harmlessly (retries, then gives up), and the
    # migrate unit no-ops (its own `zpool list` guard). ──
    machine.wait_for_unit("zfs-data-key-${poolName}.service")
    machine.succeed("test -f /run/zfs-data-disk-secrets/zpool.key")
    machine.succeed("[ \"$(cat /run/zfs-data-disk-secrets/zpool.key)\" = fixed-test-key ]")

    # ── create the pool against a file-backed vdev, keyed with EXACTLY
    # the file the writer already produced -- the disko-equivalent step
    # this test does not otherwise exercise. ──
    machine.succeed("truncate -s 256M /var/lib/pool.img")
    machine.succeed(
        "zpool create -f -O encryption=on -O keyformat=passphrase "
        "-O keylocation=file:///run/zfs-data-disk-secrets/zpool.key -O compression=lz4 "
        "-O canmount=off -O mountpoint=none ${poolName} /var/lib/pool.img"
    )
    machine.succeed("zpool export ${poolName}")

    # ── reboot 1: the pool now exists. NixOS's OWN automatic key-load
    # (requestEncryptionCredentials, default true) must unlock it using
    # nothing but the key-writer's freshly-regenerated ephemeral key --
    # no manual `zfs load-key` anywhere in this test. ──
    machine.reboot()
    machine.wait_for_unit("multi-user.target")
    machine.wait_until_succeeds("zpool list ${poolName}")
    assert (
        machine.succeed("zfs get -H -o value keystatus ${poolName}").strip() == "available"
    ), "the pool did not auto-unlock via the ephemeral hardware-derived key"
    assert (
        machine.succeed("zfs get -H -o value keylocation ${poolName}").strip()
        == "file:///run/zfs-data-disk-secrets/zpool.key"
    ), "keylocation should still be the ephemeral default before any migration"

    # ── the migration target now exists (simulating sops having been
    # provisioned since the last boot). Content does not need to match
    # the current key -- `zfs change-key` re-wraps an ALREADY-unlocked
    # pool's data key with whatever new key material it is given. ──
    machine.succeed("printf '%s' migrated-key > ${migratedKeyFilePath}")

    # ── reboot 2: the migrate unit should now fire, adopting the new
    # file as the pool's real key and repointing keylocation at it. ──
    machine.reboot()
    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("zfs-data-key-migrate-${poolName}.service")
    machine.wait_until_succeeds(
        "[ \"$(zfs get -H -o value keylocation ${poolName})\" = file://${migratedKeyFilePath} ]"
    )
    assert (
        machine.succeed("zfs get -H -o value keystatus ${poolName}").strip() == "available"
    ), "the pool should still be unlocked immediately after migration"

    # ── reboot 3: keylocation is now the migrated path, so NixOS's own
    # automatic key-load reads directly from it (a REGULAR file,
    # unlike the ephemeral default, so it survives across reboots on
    # its own -- no key-writer involvement needed at all this time).
    # The migrate unit runs again (it is `wantedBy` on every import),
    # but its OWN guard must no-op: keylocation no longer equals the
    # ephemeral default, so nothing should change. ──
    machine.reboot()
    machine.wait_for_unit("multi-user.target")
    machine.wait_until_succeeds("zpool list ${poolName}")
    assert (
        machine.succeed("zfs get -H -o value keystatus ${poolName}").strip() == "available"
    ), "the pool did not auto-unlock via the migrated keyFilePath"
    assert (
        machine.succeed("zfs get -H -o value keylocation ${poolName}").strip()
        == "file://${migratedKeyFilePath}"
    ), "a second reboot after migration must not touch keylocation again"
  '';
}
