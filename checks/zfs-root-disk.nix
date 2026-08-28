# Eval-time tests for lib/disko.declareZfsRootDisk, run by `nix flake check`.
#
# The function returns a NixOS module (normally used via `imports`); here it
# is applied directly with pkgs/lib and a minimal config stub, and the
# resulting disko layout is asserted on.
{
  pkgs,
  nixpkgs,
  myLib,
}:
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

  # hybridMbr/enableLegacyBiosBoot are validated against a specific
  # platform (aarch64-linux/x86_64-linux respectively), regardless of which
  # platform this check itself is running under -- so, unlike `build`
  # above, these pin their OWN `pkgs` explicitly rather than using the
  # host system's.
  buildFor =
    system: args:
    (myLib.declareZfsRootDisk (
      {
        devicePath = "/dev/disk/by-id/test-disk";
        hostname = "testhost";
        listOfUsernames = [ "alice" ];
        enableEncryption = false;
      }
      // args
    ))
      {
        pkgs = nixpkgs.legacyPackages.${system};
        inherit lib;
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
    args: select: !(builtins.tryEval (builtins.deepSeq (select (build args)) true)).success;
  # ... and the buildFor equivalent, for the platform-pinned checks
  buildForThrows =
    system: args: select:
    !(builtins.tryEval (builtins.deepSeq (select (buildFor system args)) true)).success;

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
    # ... writing to the SAME path the ZFS `keylocation` property reads
    # from. The expected path is extracted from the module's own
    # keylocation (both interpolate one shared binding), not re-typed here.
    key-writers-match-keylocation =
      let
        keylocation = encrypted.disko.devices.zpool."zroot-testhost".rootFsOptions.keylocation;
        path = lib.removePrefix "file://" keylocation;
      in
      lib.hasPrefix "file://" keylocation
      && builtins.all (w: lib.hasInfix "KEY_FILE_PATH=\"${path}\"" w) keyWritersCode;
    # stage-1 destined scripts must be POSIX (busybox ash): no bashisms in
    # any writer or in either load-key loop
    key-code-is-posix =
      let
        loops = [
          encrypted.boot.initrd.systemd.content.services.zfs-load-encryption-keys.script
          # through mkIf and mkAfter, hence .content.content
          encrypted.boot.initrd.postResumeCommands.content.content
        ];
      in
      builtins.all (w: !(lib.hasInfix "[[" w) && !(lib.hasInfix "$'" w)) (keyWritersCode ++ loops);
    # both initrd flavors' load-key loops come from ONE snippet: the
    # script-initrd copy used to swallow failures with a bare `|| true`
    load-key-loops-identical =
      encrypted.boot.initrd.systemd.content.services.zfs-load-encryption-keys.script
      == encrypted.boot.initrd.postResumeCommands.content.content;
    # every key writer refuses empty/placeholder dmidecode output (behavior
    # covered in checks/zfs-key-file.nix; this pins that no writer loses
    # the guard)
    key-writers-validate-uuid = builtins.all (w: lib.hasInfix ''case "$KEY" in'' w) keyWritersCode;
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

    # ── defineBootPartitions: null / attrset / anything else ──
    # the escape hatch replaces the platform layout wholesale
    boot-partitions-escape-hatch =
      let
        parts =
          (build {
            enableEncryption = false;
            defineBootPartitions = {
              CUSTOMBOOT = {
                label = "CUSTOMBOOT";
                priority = 1;
                size = "1G";
              };
            };
          }).disko.devices.disk.main.content.partitions;
      in
      parts ? CUSTOMBOOT && !(parts ? ESP);
    # a non-null non-attrset value used to be SILENTLY ignored (platform
    # dispatch ran as if nothing had been passed)
    invalid-boot-partitions-throws = buildThrows {
      enableEncryption = false;
      defineBootPartitions = "esp";
    } (r: r.disko.devices.disk.main.content.partitions);

    # ── hybridMbr (aarch64-linux only): disko's native hybrid-MBR
    # mechanism on the FIRMWARE partition, for a Raspberry-Pi-style
    # bootrom that cannot read GPT at all ──
    hybrid-mbr-off-by-default =
      let
        content = (buildFor "aarch64-linux" { }).disko.devices.disk.main.content;
      in
      !(content ? efiGptPartitionFirst) && !(content.partitions.FIRMWARE ? hybrid);
    hybrid-mbr-sets-firmware-hybrid-and-efi-order =
      let
        content = (buildFor "aarch64-linux" { hybridMbr = true; }).disko.devices.disk.main.content;
      in
      content.efiGptPartitionFirst == false
      &&
        content.partitions.FIRMWARE.hybrid == {
          mbrPartitionType = "0x0c";
          mbrBootableFlag = true;
        };
    # meaningless outside the one layout it targets -- both throw rather
    # than silently doing nothing
    hybrid-mbr-on-x86_64-throws = buildForThrows "x86_64-linux" {
      hybridMbr = true;
    } (r: r.disko.devices.disk.main.content);
    hybrid-mbr-with-define-boot-partitions-throws = buildForThrows "aarch64-linux" {
      hybridMbr = true;
      defineBootPartitions = {
        X = {
          size = "100%";
          type = "8300";
        };
      };
    } (r: r.disko.devices.disk.main.content);
    hybrid-mbr-non-bool-throws = buildForThrows "aarch64-linux" {
      hybridMbr = "yes";
    } (r: r.disko.devices.disk.main.content);

    # ── enableLegacyBiosBoot (x86_64-linux only): a raw EF02 partition for
    # GRUB's BIOS+GPT boot embedding -- unrelated to hybridMbr above,
    # despite both existing to support "legacy" boot paths ──
    legacy-bios-boot-off-by-default =
      let
        partitions = (buildFor "x86_64-linux" { }).disko.devices.disk.main.content.partitions;
      in
      !(partitions ? EF02) && partitions.ESP.priority == 2;
    legacy-bios-boot-adds-ef02 =
      let
        partitions =
          (buildFor "x86_64-linux" { enableLegacyBiosBoot = true; })
          .disko.devices.disk.main.content.partitions;
      in
      partitions.EF02.priority == 1
      && partitions.EF02.type == "EF02"
      && partitions.EF02.size == "1M"
      && !(partitions.EF02 ? content)
      && partitions.ESP.priority == 2;
    # ESP.priority is 2 unconditionally (see the code comment on ESP for
    # why) -- pin that it is the SAME value on and off, not just "some
    # value both times"
    legacy-bios-boot-esp-priority-matches-default =
      (buildFor "x86_64-linux" { enableLegacyBiosBoot = true; })
      .disko.devices.disk.main.content.partitions.ESP.priority == (buildFor "x86_64-linux" { })
      .disko.devices.disk.main.content.partitions.ESP.priority;
    legacy-bios-boot-on-aarch64-throws = buildForThrows "aarch64-linux" {
      enableLegacyBiosBoot = true;
    } (r: r.disko.devices.disk.main.content);
    legacy-bios-boot-with-define-boot-partitions-throws = buildForThrows "x86_64-linux" {
      enableLegacyBiosBoot = true;
      defineBootPartitions = {
        X = {
          size = "100%";
          type = "8300";
        };
      };
    } (r: r.disko.devices.disk.main.content);
    legacy-bios-boot-non-bool-throws = buildForThrows "x86_64-linux" {
      enableLegacyBiosBoot = "yes";
    } (r: r.disko.devices.disk.main.content);
    # an unsupported system without defineBootPartitions throws (the module
    # reads the platform from pkgs, so a probe pkgs with a foreign system
    # double reaches the dispatch's else branch)
    unsupported-system-throws =
      let
        foreignPkgs = pkgs // {
          stdenv = pkgs.stdenv // {
            hostPlatform = pkgs.stdenv.hostPlatform // {
              system = "riscv64-linux";
            };
          };
        };
        m =
          (myLib.declareZfsRootDisk {
            devicePath = "/dev/disk/by-id/test-disk";
            hostname = "testhost";
            listOfUsernames = [ "alice" ];
            enableEncryption = false;
          })
            {
              pkgs = foreignPkgs;
              inherit lib;
              config.boot.initrd.systemd.enable = true;
            };
      in
      !(builtins.tryEval (builtins.deepSeq m.disko.devices.disk.main.content.partitions true)).success;

    # ── useZfsForTmp, both positions ──
    # zfs /tmp (the default): TMP dataset with the documented options, and
    # boot.tmp stays off tmpfs (values sit behind mkDefault, hence .content)
    zfs-tmp-dataset-and-boot-options =
      plainDatasets ? TMP
      && plainDatasets."TMP".options.sync == "disabled"
      && plainDatasets."TMP".options.setuid == "off"
      && plainDatasets."TMP".options.devices == "off"
      && !plain.boot.tmp.useTmpfs.content
      && plain.boot.tmp.cleanOnBoot.content;
    # tmpfs /tmp: no TMP dataset, boot.tmp flips both settings
    tmpfs-tmp-no-dataset-and-boot-options =
      let
        m = build {
          enableEncryption = false;
          useZfsForTmp = false;
        };
      in
      !(m.disko.devices.zpool."zroot-testhost".datasets ? TMP)
      && m.boot.tmp.useTmpfs.content
      && !m.boot.tmp.cleanOnBoot.content;

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

    # NixOS's own requestEncryptionCredentials default (true, blanket-scan
    # + interactive prompt) must NOT leak through: declareZfsRootDisk's own
    # loadKeysScript already makes the one attempt a file://-keyed dataset
    # gets, and an unwanted boot-time prompt would actively fight a
    # consumer's PAM-managed (login-unlocked) dataset. Plain `[ ]`, NOT
    # `lib.mkDefault [ ]`: this option's listOf-backed type concatenates
    # same-priority list definitions, so a plain `[ ]` here combines for
    # free with a consumer's own plain list -- an `override`-wrapped value
    # would not (see the doc comment on this option for the merge
    # footgun that ruled out mkDefault).
    request-encryption-credentials-defaults-to-empty-list =
      (build { }).boot.zfs.requestEncryptionCredentials == [ ];

    # argument validation throws
    invalid-encryption-throws = buildThrows { enableEncryption = "yes"; } (
      r: r.disko.devices.zpool."zroot-testhost".rootFsOptions
    );
    invalid-swap-size-throws = buildThrows {
      enableEncryption = false;
      swapSize = -1;
    } (r: r.disko.devices.disk.main.content.partitions);
    # the natural TYPO: the size as a string ("32") throws like a negative
    invalid-swap-size-type-throws = buildThrows {
      enableEncryption = false;
      swapSize = "32";
    } (r: r.disko.devices.disk.main.content.partitions);
    invalid-extra-datasets-throws = buildThrows {
      enableEncryption = false;
      extraDatasets = 42;
    } (r: r.disko.devices.zpool."zroot-testhost".datasets);
  };

  runner = import ./run-assertions.nix { inherit pkgs; };
in
runner.run "zfs-root-disk-tests" assertions
