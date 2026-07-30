# Eval-time tests for lib/disko.declareZfsRootDisk, run by `nix flake check`.
#
# The function returns a NixOS module (normally used via `imports`); here it
# is applied directly with pkgs/lib and a minimal config stub, and the
# resulting disko layout is asserted on.
{ pkgs, myLib }:
let
  lib = pkgs.lib;

  buildWith =
    systemdInitrd: args:
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
        config.boot.initrd.systemd.enable = systemdInitrd;
      };
  build = buildWith true;

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
    args: select: !(builtins.tryEval (builtins.deepSeq (select (build args)) true)).success;

  # The three places that write the encryption key file. Their BEHAVIOR is
  # tested in checks/zfs-key-file.nix; these eval-only assertions catch the
  # drift that once happened (a here-string appending a newline where the
  # others wrote none) without building anything.
  encrypted = build { };
  keyWriters = [
    encrypted.disko.devices.zpool."zroot-testhost".preCreateHook
    encrypted.boot.initrd.systemd.content.services.zfs-key-file-setup.script
    encrypted.boot.initrd.postDeviceCommands.content
  ];
  # Comment lines dropped first: the snippet's own comment NAMES the banned
  # forms ("printf, never `echo -n` ..."), so a substring search over the
  # whole script would match the warning against writing them.
  keyWritersCode = map (
    w:
    builtins.concatStringsSep "\n" (
      builtins.filter (l: builtins.match "[[:space:]]*#.*" l == null) (lib.splitString "\n" w)
    )
  ) keyWriters;

  assertions = {
    pool-named-after-hostname = plain.disko.devices.zpool ? zroot-testhost;

    # every writer uses the ONE shared snippet ...
    key-writers-use-printf = builtins.all (w: lib.hasInfix "printf '%s' \"$KEY\"" w) keyWritersCode;
    # ... and none of the newline-appending forms it replaced
    key-writers-add-no-newline = builtins.all (
      w: !(lib.hasInfix "cat <<<" w) && !(lib.hasInfix "echo -n" w)
    ) keyWritersCode;
    # a writer only exists when encryption is on
    no-key-writer-without-encryption = plain.disko.devices.zpool."zroot-testhost".preCreateHook == "";

    # WHICH initrd flavour gets which writer. The assertions above read the
    # `mkIf` structures through `.content`, which discards `.condition` --
    # so swapping these two conditions (systemd-initrd systems getting
    # postDeviceCommands and vice versa) would leave every one of them green
    # while no machine unlocks its pool. Assert the conditions themselves,
    # in BOTH flavours.
    systemd-initrd-gets-the-service =
      let
        m = buildWith true { };
      in
      m.boot.initrd.systemd.condition && !m.boot.initrd.postDeviceCommands.condition;
    script-initrd-gets-the-legacy-hooks =
      let
        m = buildWith false { };
      in
      m.boot.initrd.postDeviceCommands.condition && m.boot.initrd.postResumeCommands.condition;
    # ... and neither flavour writes a key at all without encryption
    no-initrd-writer-without-encryption =
      let
        a = buildWith true { enableEncryption = false; };
        b = buildWith false { enableEncryption = false; };
      in
      !a.boot.initrd.systemd.condition && !b.boot.initrd.postDeviceCommands.condition;

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
    encryption-on-by-default =
      (build { }).disko.devices.zpool."zroot-testhost".rootFsOptions.encryption == "on";
    no-encryption-when-disabled =
      !(plain.disko.devices.zpool."zroot-testhost".rootFsOptions ? encryption);

    # the attrset form's `mountpoint` is optional: the guard in
    # gen_zfs_user_folder said so while the code above it read the attribute
    # unconditionally, so the guard was dead and `{ username = "x"; }` died
    # with a bare "attribute 'mountpoint' missing"
    user-attrset-mountpoint-optional =
      let
        datasets =
          (build {
            enableEncryption = false;
            listOfUsernames = [ { username = "solo"; } ];
          }).disko.devices.zpool."zroot-testhost".datasets;
      in
      datasets ? "HOME/solo" && !(datasets."HOME/solo".options ? mountpoint);

    # a repeated user silently collapsed into whichever entry came last --
    # including two entries with DIFFERENT mountpoints
    duplicate-user-throws = buildThrows {
      enableEncryption = false;
      listOfUsernames = [
        "dup"
        {
          username = "dup";
          mountpoint = "/srv/dup";
        }
      ];
    } (r: r.disko.devices.zpool."zroot-testhost".datasets);

    # encryption keeps a recovery path: the key file comes from the
    # motherboard UUID, so a board swap or a restored pool must still be
    # able to ASK for the passphrase rather than hang on sysroot.mount
    encryption-keeps-passphrase-fallback =
      !((build { }).boot.zfs.requestEncryptionCredentials.condition or false);

    # argument validation throws
    invalid-encryption-throws = buildThrows { enableEncryption = "yes"; } (
      r: r.disko.devices.zpool."zroot-testhost".rootFsOptions
    );
    invalid-swap-size-throws = buildThrows {
      enableEncryption = false;
      swapSize = -1;
    } (r: r.disko.devices.disk.main.content.partitions);
    invalid-extra-datasets-throws = buildThrows {
      enableEncryption = false;
      extraDatasets = 42;
    } (r: r.disko.devices.zpool."zroot-testhost".datasets);
  };

  runner = import ./run-assertions.nix { inherit pkgs; };
in
runner.run "zfs-root-disk-tests" assertions
