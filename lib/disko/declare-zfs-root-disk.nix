# Loaded by lib/default.nix under the one calling convention: `self` is the
# fully assembled nixpkgs-lib-extensions lib (a fixed point), `lib` is nixpkgs'.
{ ... }:
{
  /**
    Declare a complete ZFS root disk as a NixOS module: a GPT (GUID
    Partition Table) partition layout -- a boot partition (ESP on
    x86_64-linux, FIRMWARE + ESP on aarch64-linux), an optional swap
    partition, and one partition holding the ZFS pool -- the
    `zroot-<hostname>` pool itself, and the standard ZFS datasets inside
    it (root, /var, /var/log, /nix/store, /home, optional /tmp) plus one
    HOME dataset per user, with optional encryption keyed to the
    machine's hardware identity. (A ZFS "pool" is the whole allocated
    block of storage; a "dataset" is a mountable sub-filesystem inside
    it -- roughly ZFS's equivalent of a partition, but resizable and
    nestable.)

    Prerequisites: the disko NixOS module must be imported (it provides
    the `disko.devices` options -- automatic when disko is a flake input
    of a `mkNixosSystem` setup), and ZFS requires `networking.hostId` to
    be set (an 8-hex-digit ID ZFS uses to tell "my own pool, imported
    normally" apart from "a pool still marked in-use by some OTHER,
    possibly still-running machine").

    THREAT MODEL: keying the pool to the machine's hardware identity
    protects a SEPARATED disk -- pulled for RMA (a warranty
    return/replacement), resold, or discarded -- whose new holder does
    not also hold the machine. It is near-zero protection against
    whole-machine theft: the value is readable from the BIOS setup
    screen, chassis stickers and service tags, IPMI (a server's
    built-in remote-management interface, readable independently of the
    running OS) on `x86_64-linux`, or, on either platform, any live-USB
    boot of the very machine holding the disk. This is a deliberate
    trade-off: auto-unlock with no TPM (Trusted Platform Module)
    involved, not full-disk-encryption-grade secrecy.

    RECOVERY: record the hardware identity value somewhere off-machine
    at install time -- `dmidecode --string system-uuid` on
    `x86_64-linux`, or the `Serial` field of `/proc/cpuinfo` on
    `aarch64-linux` (see `keySourceCommand` below for any other
    platform). After a hardware swap the pool no longer auto-unlocks,
    and boot does NOT prompt for a passphrase either: this function sets
    `boot.zfs.requestEncryptionCredentials = [ ]`, opting out of NixOS's
    own "prompt for anything still locked" default. Recovery is manual:
    boot from a rescue/live medium (a bootable USB/CD running a live
    Linux, independent of the installed system), import the pool (ZFS's
    term for attaching a pool it doesn't yet know about), and
    `zfs load-key -L prompt <dataset>` with the OLD hardware's identity
    value as the passphrase, for every affected dataset, then re-key
    them to the new hardware's value.

    PARTITIONS: one GPT disk, holding (in on-disk order) the boot
    partition(s), the ZFS pool partition, then SWAP last if `swapSize` is
    nonzero. That order comes from disko's own `priority` field, where a
    SMALLER number is created earlier on the disk -- boot gets `1` (`2`
    for the second aarch64-linux partition below), the ZFS partition
    `10`, SWAP `100`. The ZFS partition's own SIZE is what actually
    reserves SWAP's space, despite coming first on disk: with a nonzero
    `swapSize` it ends `swapSize` GiB before the end of the disk
    (`end = "-${swapSize}G"`), leaving exactly that much free for SWAP to
    occupy afterward; with `swapSize = 0` it simply takes the rest of the
    disk (`size = "100%"`) and no SWAP partition exists at all. SWAP
    itself uses `randomEncryption` -- a fresh random key generated at
    every boot, so its content is unrecoverable across reboots by design;
    this also means hibernation (suspend-to-disk) is not supported.

    The boot partition(s) (skipped entirely by `defineBootPartitions`,
    see below) differ by platform, because the firmware that has to find
    them differs:

    - `x86_64-linux`: one 2 GiB `ESP` partition (GPT type code `EF00`,
      the standard EFI System Partition marker), formatted `vfat`,
      mounted at `/boot` -- what a normal UEFI firmware boots from.
    - `aarch64-linux`: TWO 2 GiB `vfat` partitions, both mounted
      ON DEMAND (`noauto` + `x-systemd.automount`, not kept mounted at
      all times): a `FIRMWARE` partition (GPT type code `0700`,
      "Microsoft basic data" -- used here because that is the generic
      FAT marker a Raspberry-Pi-style bootrom scans for, not because it
      is Windows-specific), mounted at `/boot/firmware`, plus a second,
      ordinary `ESP` partition (type `EF00`) mounted at `/boot` for a
      UEFI-capable bootloader (U-Boot, systemd-boot) to chain into once
      the bootrom itself has run. This two-partition layout is shaped
      for Raspberry-Pi-class boards specifically -- a generic aarch64
      UEFI server or VM has no bootrom expecting a `FIRMWARE` partition
      at all, and should pass its own `defineBootPartitions` (typically
      just a single `ESP`, as on `x86_64-linux`) instead of the default.
    - any other platform has no predefined layout at all and THROWS
      unless `defineBootPartitions` is given.

    `defineBootPartitions` (see Arguments below) replaces this whole
    dispatch with an attrset of partition definitions of your own, valid
    on any platform -- use it to change the predefined layout above, or
    to support a platform this function does not predefine one for. A
    further opt-in argument, `legacyBoot`, splices an ADDITION into (not a
    replacement of) the predefined layout above, so it throws if combined
    with `defineBootPartitions` -- there is nothing predefined left to
    splice into. It is ONE argument, valid on both predefined platforms,
    but NOT one mechanism: despite both existing to support a "legacy"
    boot path, `legacyBoot` does two unrelated things for two unrelated
    firmwares, chosen by platform:

    - `aarch64-linux`: registers the `FIRMWARE` partition as ALSO an
      entry in a hybrid MBR table (disko's own native mechanism,
      `sgdisk -h` under the hood) -- for a Raspberry-Pi-style bootrom,
      which cannot read GPT at all and instead reads the MBR partition
      table directly to find its FAT boot partition.
    - `x86_64-linux`: adds a third, raw 1 MiB `EF02` partition (no
      filesystem, never mounted) before `ESP` -- GRUB's own BIOS+GPT boot
      mechanism, which finds this partition by its type code and embeds
      its boot code directly into it. Unlike the aarch64-linux behavior,
      this never touches the MBR partition table at all; GRUB reads GPT
      normally once its embedded code has run.

    # Example

    ```nix
    # use in `imports`; the returned module receives config/pkgs/lib itself
    # extLib = inputs.nixpkgs-lib-extensions.lib
    imports = [
      (extLib.declareZfsRootDisk {
        devicePath = "/dev/disk/by-id/nvme-WDC_PC_SN479_WEFWOER-512G-1233_23425X589324";
        listOfUsernames = [
          "foo"
          { username = "bar"; mountpoint = "/home/bar2"; }
        ];
        hostname = "myhost";
        enableEncryption = false;
      })
    ];
    ```

    # Type

    ```
    declareZfsRootDisk :: Attribute -> Module
    ```

    # Arguments

    devicePath
    : The absolute path to the device

    hostname
    : The host's name; the pool will be named: zroot-<HOSTNAME>

    enableEncryption
    : Whether the pool should be encrypted. Default `true`.
    : The key is derived from the machine's hardware identity: on
    : `x86_64-linux`, `dmidecode --string system-uuid`; on
    : `aarch64-linux`, the `Serial` field of `/proc/cpuinfo`. Record the
    : relevant one off-machine; see the THREAT MODEL and RECOVERY
    : paragraphs above for what this protects against and what a
    : hardware swap costs. See `keySourceCommand` below to use a
    : different source, or to support another platform.

    swapSize
    : Set the size (in GiB, gibibytes -- 1024^3 bytes) of the SWAP
    : partition. Default is `32`.
    : Set it to `0` to disable having a SWAP partition.

    useZfsForTmp
    : Select if `/tmp` should be a zfs dataset with
    : `sync=disabled`, `setuid=off` and `devices=off` or
    : if it should be `tmpfs`. Default `true` (zfs dataset).

    listOfUsernames
    : A list of `string` or `attribute` element (may be mixed).
    : The `string` element is: <USERNAME>.
    : The `attribute` element is: { username = "<USERNAME>"; mountpoint = "<MOUNTPOINT>"; }

    defineBootPartitions
    : Defines boot partitions for systems that are not `x86_64-linux` or `aarch64-linux`,
    : or when boot partitions must be overwritten. Default `null` (use the
    : predefined layout for the two supported platforms).

    legacyBoot
    : One argument, valid on both `aarch64-linux` and `x86_64-linux`, but
    : NOT one mechanism: on `aarch64-linux` it registers the `FIRMWARE`
    : partition in a hybrid MBR table, for a Raspberry-Pi-style bootrom
    : that cannot read GPT at all; on `x86_64-linux` it adds a raw `EF02`
    : partition for GRUB's BIOS+GPT boot embedding instead -- see the
    : PARTITIONS section above for why these are unrelated mechanisms
    : sharing one flag rather than one shared implementation. Throws if
    : combined with `defineBootPartitions`, or on any other platform.
    : Default `false`.

    keySourceCommand
    : Overrides where the encryption key comes from. Default `null` (use
    : the predefined per-platform source described under
    : `enableEncryption` above: `dmidecode` on `x86_64-linux`,
    : `/proc/cpuinfo`'s `Serial` on `aarch64-linux`). A string replaces
    : that dispatch entirely, on ANY platform: a POSIX-sh snippet (no
    : `[[`, no `$'...'` -- it may run under busybox ash, in the
    : script-initrd context) that sets the shell variable `KEY` to the
    : key material. Use it to support a platform with no predefined
    : source, or to key the pool to something other than this function's
    : default choice. `enableEncryption = true` on a platform that is
    : neither `x86_64-linux` nor `aarch64-linux` throws unless this is
    : given -- there is no predefined source to fall back to.

    extraDatasets
    : An attribute set of additional zfs datasets, merged into the generated ones.
    : Keys are dataset paths relative to the pool root (like the generated
    : `ROOT/NixOS` or `HOME/<username>`), values are disko dataset definitions.
    : Parent datasets are not created implicitly -- declare them too.
    : Merged last, so it can also override a generated dataset.
    : Example: { "DATA" = { type = "zfs_fs"; options.mountpoint = "none"; };
    :            "DATA/media" = { type = "zfs_fs"; mountpoint = "/srv/media"; options.mountpoint = "legacy"; }; }
  */
  declareZfsRootDisk =
    {
      devicePath,
      hostname,
      enableEncryption ? true,
      keySourceCommand ? null,
      swapSize ? 32,
      useZfsForTmp ? true,
      listOfUsernames,
      defineBootPartitions ? null,
      legacyBoot ? false,
      extraDatasets ? { },
    }:
    # Returns a module function (valid in `imports`) so the actual initrd
    # (initial ramdisk -- the small environment that runs before the real
    # root filesystem, here `/`, is mounted; NixOS builds it as either a
    # systemd service tree or a legacy shell-script chain, the "flavor"
    # referenced throughout this file) type can be read from `config`,
    # `pkgs` & `lib` instead of having to pass them as arguments.
    {
      config,
      pkgs,
      lib,
      ...
    }:
    let

      zrootName = "zroot-${hostname}";

      # THE key file path. The ZFS `keylocation` property and every writer
      # interpolate this one binding, so the location ZFS reads from and the
      # place the writers put the key cannot drift apart.
      keyFilePath = "/tmp/secrets/zpool.key";

      encryptionAttributes =
        if (lib.isBool enableEncryption) then
          (lib.optionalAttrs enableEncryption {
            encryption = "on";
            keyformat = "passphrase";
            keylocation = "file://${keyFilePath}";
          })
        else
          throw "The argument `enableEncryption` must be of type `boolean`";

      # The encryption key file is written in THREE places -- at pool
      # creation (preCreateHook) and at boot by either initrd flavor. They
      # used to be three copies and had drifted: `cat <<<` appends a trailing
      # newline where `echo -n` does not. That turned out to be harmless,
      # because ZFS strips a single trailing newline from a
      # `keyformat=passphrase` key file (verified in a VM by
      # `nix build .#zfs-newline-probe`), but resting the ability to unlock
      # a pool on that detail is not a plan. Hence ONE definition producing
      # deterministic bytes, used by all three. It expects `KEY` to be set by
      # the caller.
      #
      # `junkPatterns`: extra shell `case` alternatives (besides the
      # universal, source-independent bare `""`) naming values THIS
      # particular key source is known to emit on failure -- a UUID-shaped
      # placeholder only means something for dmidecode's output, a
      # hex-shaped one only for `/proc/cpuinfo`'s `Serial`, so each source
      # supplies its own list (see `keySourceFor` below) rather than this
      # shared writer hardcoding one source's shapes.
      #
      # POSIX sh only (no `[[`, no `$'...'`): the script-initrd hooks run
      # under busybox ash (BusyBox's minimal Almquist-shell clone -- the
      # only shell present in that stripped-down environment, and it
      # rejects bash-only syntax), and one snippet serves every context.
      writeKeyFile = junkPatterns: ''
        SECRET_FOLDER_PATH="${builtins.dirOf keyFilePath}"
        KEY_FILE_PATH="${keyFilePath}"

        # REFUSE to derive a key from junk. Empty output or one of the
        # known placeholder values would "successfully" key the pool to a
        # value every identical machine reports -- or to nothing at all --
        # and the mistake only surfaces when unlocking fails later.
        case "$KEY" in
          ${lib.concatStringsSep " | " ([ "\"\"" ] ++ junkPatterns)} )
            echo "zfs key file: the key source returned an empty or placeholder value ('$KEY'); refusing to derive a ZFS encryption key from it" >&2
            exit 1
            ;;
        esac

        # A leftover NON-directory here (a file, or a dangling symlink)
        # would make the mkdir below fail, so it is removed; an existing
        # directory is kept and its key file simply overwritten.
        if ! [ -d "$SECRET_FOLDER_PATH" ]; then
          rm -rf "$SECRET_FOLDER_PATH"
        fi

        mkdir -p "$SECRET_FOLDER_PATH"
        chmod 700 "$SECRET_FOLDER_PATH"

        # printf, never `echo -n` or a here-string: the key must land in the
        # file verbatim, with no trailing newline.
        printf '%s' "$KEY" > "$KEY_FILE_PATH"
      '';

      # dmidecode's own known placeholder shapes (BIOS fields left
      # unset, or a widely-observed Dell service-tag placeholder GUID).
      dmidecodeJunkPatterns = [
        "\"Not Settable\""
        "\"Not Present\""
        "00000000-0000-0000-0000-000000000000"
        "03000200-0400-0500*"
      ];

      # `/proc/cpuinfo`'s `Serial` field, as set by the Raspberry Pi
      # VideoCore firmware: all-zeros specifically on a failed "get board
      # serial" mailbox call, not a missing line (the universal `""` check
      # covers that case instead).
      cpuinfoSerialJunkPatterns = [ "0000000000000000" ];

      # The load-key loop, shared verbatim by BOTH initrd flavors -- the
      # script-initrd copy used to swallow failures with a bare `|| true`
      # while the systemd one named the dataset. POSIX sh only (busybox ash
      # in the script initrd): `[ ]` instead of `[[ ]]`, and the literal
      # tab for IFS built with printf instead of bash's $'\t'.
      loadKeysScript = ''
        zfs list -rHo name,keylocation,keystatus -t volume,filesystem | \
        while IFS="$(printf '\t')" read -r dataset keylocation keystatus; do
          if [ "$keystatus" != "unavailable" ]; then
            continue
          fi
          case "$keylocation" in
            none|prompt ) ;;
            # `|| echo`, never a bare failure: one dataset that cannot be
            # unlocked must not abort the loop and leave the REST locked
            # too. But say which one -- silently swallowing this is what
            # turned a wrong key into an unexplained sysroot.mount
            # timeout. Nothing prompts for it afterward (see
            # requestEncryptionCredentials below): this is the ONLY
            # attempt a `file://`-keyed dataset gets.
            * ) zfs load-key "$dataset" \
                  || echo "zfs-load-encryption-keys: could not load the key for $dataset (keylocation=$keylocation); it stays locked" >&2 ;;
          esac
        done
      '';

      checkedSwapSize =
        if (lib.isInt swapSize && swapSize >= 0) then
          swapSize
        else
          throw "The argument `swapSize` must be an integer >= 0 (GiB); 0 disables the SWAP partition";

      checkedKeySourceCommand =
        if keySourceCommand == null || lib.isString keySourceCommand then
          keySourceCommand
        else
          throw "The argument `keySourceCommand` must be `null` (use the predefined per-platform key source) or a string (a POSIX-sh snippet that sets `KEY`), but is a value of type `${builtins.typeOf keySourceCommand}`";

      # Chooses where `KEY` comes from: `checkedKeySourceCommand` if given
      # (ANY platform, caller's own snippet, used verbatim); otherwise the
      # predefined per-platform source. `dmidecodeInvocation` -- the ONE
      # thing that still varies by SITE rather than by platform -- is
      # threaded in by each of the three call sites below rather than
      # hardcoded here: preCreateHook runs in an arbitrary live-installer
      # environment and needs a `which`-guarded fallback to `nix run`,
      # systemd-initrd's service relies on `extraBin` staging `dmidecode`
      # onto PATH, and script-initrd's postDeviceCommands references the
      # absolute store path directly (no PATH, no `nix`, in that
      # environment) -- collapsing these into one shared string would
      # either lose preCreateHook's fallback or hand the other two
      # contexts an invocation that cannot work in them. The
      # aarch64-linux and custom-override branches have no such per-site
      # variation: `/proc/cpuinfo` has no availability/PATH concerns in
      # any of the three contexts, and a caller's snippet is spliced in
      # verbatim wherever it is used.
      keySourceFor =
        dmidecodeInvocation:
        if checkedKeySourceCommand != null then
          {
            script = checkedKeySourceCommand;
            junkPatterns = [ ];
          }
        else if pkgs.stdenv.hostPlatform.system == "x86_64-linux" then
          {
            script = dmidecodeInvocation;
            junkPatterns = dmidecodeJunkPatterns;
          }
        else if pkgs.stdenv.hostPlatform.system == "aarch64-linux" then
          {
            # `Serial` appears exactly once in /proc/cpuinfo -- after the
            # last per-core block -- regardless of core count, so a single
            # match is always correct.
            script = ''
              KEY="$(awk -F': *' '/^Serial/{print $2}' /proc/cpuinfo | tr -d '\n')"
            '';
            junkPatterns = cpuinfoSerialJunkPatterns;
          }
        else
          throw "declareZfsRootDisk: `enableEncryption = true` has no predefined key source for `${pkgs.stdenv.hostPlatform.system}` -- supply your own via `keySourceCommand`.";

      # `legacyBoot` only means anything against the predefined per-platform
      # layout below -- a `defineBootPartitions` override replaces that
      # layout wholesale, so there is nothing for it to attach to. Checked
      # against the ARGUMENTS, not the final partitions attrset: this is
      # about which layout is in effect, not about probing what ended up
      # in it. ONE shared argument, valid on both predefined platforms, but
      # NOT one shared mechanism: the platform dispatch below reads it
      # twice, independently, for two unrelated purposes -- see the
      # PARTITIONS section of this function's doc comment for why a
      # Raspberry-Pi bootrom and a legacy BIOS need genuinely different
      # treatment despite both being "legacy boot".
      checkedLegacyBoot =
        if !(lib.isBool legacyBoot) then
          throw "The argument `legacyBoot` must be a `boolean`, but is a value of type `${builtins.typeOf legacyBoot}`"
        else if legacyBoot && defineBootPartitions != null then
          throw "declareZfsRootDisk: `legacyBoot = true` has no effect once `defineBootPartitions` replaces the predefined layout -- add the equivalent partition(s) to your own layout instead (see the PARTITIONS section of this function's doc comment)."
        else if
          legacyBoot
          && !(lib.elem pkgs.stdenv.hostPlatform.system [
            "aarch64-linux"
            "x86_64-linux"
          ])
        then
          throw "declareZfsRootDisk: `legacyBoot = true` is only meaningful for the aarch64-linux and x86_64-linux default layouts -- `${pkgs.stdenv.hostPlatform.system}` has no predefined boot partition(s) for it to extend."
        else
          legacyBoot;

      # Additional zfs datasets requested by the caller. Keys are dataset paths
      # relative to the pool root (e.g. "DATA/media" becomes
      # <zrootName>/DATA/media); parent datasets must be declared by the caller too.
      checkedExtraDatasets =
        if (lib.isAttrs extraDatasets) then
          extraDatasets
        else
          throw "The argument `extraDatasets` must be of type `attrset` (dataset path -> disko dataset definition)";

      /**
        Generate a zfs filesystem for a user

        # Example

        ```nix
        genZfsUserFolder "foo"
        =>
        { "HOME/foo" = { type = "zfs_fs"; ... }; }
        ```

        # Type

        ```
        genZfsUserFolder :: String || Attribute -> Attribute
        ```

        # Arguments

        userSetting
        : Takes a value of the `string` or `attribute.
        : The `string` element is: <USERNAME>.
        : The `attribute` element is: { username = "<USERNAME>"; mountpoint = "<MOUNTPOINT>"; }
      */
      genZfsUserFolder = (
        userSetting:
        let
          user =
            if (lib.isString userSetting) then
              { name = userSetting; }
            else if (lib.isAttrs userSetting && (lib.hasAttr "username" userSetting)) then
              # `mountpoint` is OPTIONAL -- the guard further down already
              # says so, but reading it unconditionally here made that guard
              # dead code and turned `{ username = "bar"; }` into a bare
              # "attribute 'mountpoint' missing" that named neither
              # listOfUsernames nor declareZfsRootDisk.
              {
                name = userSetting.username;
              }
              // lib.optionalAttrs (lib.hasAttr "mountpoint" userSetting) {
                inherit (userSetting) mountpoint;
              }
            else
              (throw "The element in `listOfUsernames` can either be a `string` or `attrset` ({ username = ...; mountpoint = ...; })");
        in
        {
          name = "HOME/${user.name}";
          value = {
            type = "zfs_fs";
            options =
              (lib.optionalAttrs (lib.hasAttr "mountpoint" user) { inherit (user) mountpoint; })
              // encryptionAttributes;
            # By adding encryption attributes to the user folder filesystem,
            # it will make it possible to switch to use the password of the user as the passphrase.
          };
        }
      );

      # A bare `listOfUsernames = "foo"` -- the natural typo, since a lone
      # string is a legal ELEMENT -- otherwise reached forEach and produced
      # Nix's own "expected a list but found a string", which names neither
      # the argument nor this function and cannot be caught by tryEval.
      checkedListOfUsernames =
        if lib.isList listOfUsernames then
          listOfUsernames
        else
          throw "declareZfsRootDisk: `listOfUsernames` must be a list, but is a value of type `${builtins.typeOf listOfUsernames}`. A single user is still a list: `listOfUsernames = [ \"foo\" ];`.";

      # listToAttrs keeps the LAST entry for a repeated key, so two entries
      # for the same user -- with different mountpoints, say -- would have
      # silently collapsed into whichever came last.
      zfsUserFolders = lib.lists.forEach checkedListOfUsernames genZfsUserFolder;
      duplicateUserDatasets =
        let
          names = map (e: e.name) zfsUserFolders;
        in
        lib.unique (lib.filter (n: lib.count (m: m == n) names > 1) names);
      zfsFilesystemsForUsers =
        if duplicateUserDatasets == [ ] then
          lib.listToAttrs zfsUserFolders
        else
          throw "declareZfsRootDisk: `listOfUsernames` names the same user more than once (${
            lib.concatStringsSep ", " (map (n: lib.removePrefix "HOME/" n) duplicateUserDatasets)
          }); only the last entry would have survived.";

      zrootGeneralDatasets = {
        "ROOT" = {
          type = "zfs_fs";
          options = {
            mountpoint = "none";
          };
        };
        "ROOT/NixOS" = {
          type = "zfs_fs";
          mountpoint = "/";
          options = {
            mountpoint = "legacy";
          };
        };
        "HOME" = {
          type = "zfs_fs";
          options = {
            mountpoint = "/home";
            canmount = "on";
          };
        };
        "VAR" = {
          type = "zfs_fs";
          mountpoint = "/var";
          options = {
            mountpoint = "legacy";
          };
        };
        "VAR/log" = {
          type = "zfs_fs";
          mountpoint = "/var/log";
          options = {
            mountpoint = "legacy";
          };
        };
        "NIX_STORE" = {
          type = "zfs_fs";
          mountpoint = "/nix/store";
          options = {
            mountpoint = "legacy";
          };
        };
      };

      # "stage 1" is NixOS's name for the initrd's own boot phase (as
      # opposed to "stage 2", the real system after switch-root). The
      # systemd-initrd flavor of stage 1 does not support
      # boot.initrd.postDeviceCommands or boot.initrd.postResumeCommands
      # (both are script-initrd-only hook points).
      useSystemdInitrd = config.boot.initrd.systemd.enable;

      tmpDataset = lib.optionalAttrs useZfsForTmp {
        "TMP" = {
          type = "zfs_fs";
          mountpoint = "/tmp";
          options = {
            mountpoint = "legacy";
            sync = "disabled";
            setuid = "off";
            devices = "off";
          };
        };
      };

    in
    {
      # Attribute definitions to this file in error messages, instead of
      # whichever configuration.nix called the function.
      # Can be really helpful when debugging.
      _file = ./declare-zfs-root-disk.nix;

      boot = {
        supportedFilesystems = [ "zfs" ];

        zfs = {
          devNodes = lib.mkDefault "/dev/disk/by-partuuid";
          forceImportRoot = lib.mkDefault true;

          # NOT NixOS's own default (true): that's a blanket boot-time
          # prompt for anything locked, which is redundant here --
          # loadKeysScript above already makes the one non-interactive
          # attempt any `file://`-keyed dataset gets -- and actively wrong
          # for a consumer's PAM-unlocked (login-time) dataset, which
          # shouldn't also get a boot prompt.
          #
          # Plain `[ ]`, not `lib.mkDefault [ ]`: a consumer's own plain
          # `requestEncryptionCredentials = [ "pool/ds" ]` concatenates
          # with ours for free; `lib.mkDefault` on THEIR side would not
          # (NixOS only concatenates same-priority list defs, and plain
          # always outranks mkDefault) -- add datasets here as a plain
          # list, not via mkDefault.
          requestEncryptionCredentials = [ ];
        };

        tmp = {
          useTmpfs = lib.mkDefault (!useZfsForTmp);
          cleanOnBoot = lib.mkDefault useZfsForTmp;
        };
      };

      # systemd initrd (boot.initrd.systemd.enable, the default since
      # NixOS 26.05): encryption keys via initrd services. The whole block
      # is inert on script-based initrd (boot.initrd.systemd options are
      # ignored there), so it only gates on enableEncryption.
      boot.initrd.systemd = lib.mkIf enableEncryption {
        # Only staged when it will actually be used: unconditionally
        # bundling `dmidecode` would force building/embedding a binary
        # that is useless on aarch64-linux (no DMI/SMBIOS on ARM SBCs at
        # all) into every such initrd.
        extraBin = lib.optionalAttrs (
          checkedKeySourceCommand == null && pkgs.stdenv.hostPlatform.system == "x86_64-linux"
        ) { dmidecode = "${pkgs.dmidecode}/bin/dmidecode"; };

        services.zfs-key-file-setup =
          let
            ks = keySourceFor ''
              KEY="$(dmidecode --string system-uuid | tr -d '\n')"
            '';
          in
          {
            description = "Create ZFS encryption key file from the machine's hardware identity";
            unitConfig.DefaultDependencies = false;
            wantedBy = [ "zfs-import-${zrootName}.service" ];
            before = [ "zfs-import-${zrootName}.service" ];
            after = [ "systemd-modules-load.service" ];
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
            };
            script = ''
              ${ks.script}
              ${writeKeyFile ks.junkPatterns}
            '';
          };

        services.zfs-load-encryption-keys = {
          description = "Load ZFS encryption keys for all datasets";
          unitConfig.DefaultDependencies = false;
          wantedBy = [
            "zfs-import.target"
            "sysroot.mount"
          ];
          after = [
            "zfs-key-file-setup.service"
            "zfs-import-${zrootName}.service"
          ];
          before = [
            "zfs-import.target"
            "sysroot.mount"
          ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
          };
          script = loadKeysScript;
        };
      };

      # script-based initrd (boot.initrd.systemd.enable = false):
      # encryption keys via the legacy initrd hooks. The writer runs in a
      # SUBSHELL: on junk dmidecode output it exits nonzero, and this code
      # is part of the stage-1 init script -- a bare exit would kill PID 1.
      # The failure stays loud (stderr) instead: nothing downstream prompts
      # for a passphrase (requestEncryptionCredentials is [] -- see above),
      # so this message is the ONLY signal a human gets before whatever
      # dataset needed the key times out several screens later.
      boot.initrd.postDeviceCommands = lib.mkIf (enableEncryption && !useSystemdInitrd) (
        let
          ks = keySourceFor ''
            KEY="$(${pkgs.dmidecode}/bin/dmidecode --string system-uuid | tr -d '\n')"
          '';
        in
        ''
          (
            ${ks.script}
            ${writeKeyFile ks.junkPatterns}
          ) || echo "declareZfsRootDisk: no usable ZFS key file was written; the affected dataset(s) will remain locked (see RECOVERY above)" >&2
        ''
      );

      boot.initrd.postResumeCommands = lib.mkIf (enableEncryption && !useSystemdInitrd) (
        lib.mkAfter loadKeysScript
      );

      security.pam.zfs = lib.mkIf enableEncryption {
        enable = true;
        homes = lib.mkDefault "${zrootName}/HOME";
      };

      services.zfs.autoScrub.enable = lib.mkDefault true;
      services.zfs.trim.enable = lib.mkDefault true;

      systemd.services.systemd-journal-flush.after = [
        "zfs-import.target"
        "zfs-mount.service"
      ];

      disko.devices = {
        disk = {
          main = {
            device = devicePath;
            type = "disk";

            # Force-evaluates here, UNCONDITIONALLY of platform: the
            # `defineBootPartitions` branch below never itself references
            # `checkedLegacyBoot` (it replaces the layout wholesale,
            # ignoring the platform dispatch entirely), so
            # `legacyBoot = true` combined with `defineBootPartitions`
            # would otherwise never reach its own validation at all --
            # silently producing a config that looks fine but never had
            # the argument checked. Caught by actually testing that
            # combination, not just assuming a branch reading its own
            # argument was enough.
            content =
              builtins.seq checkedLegacyBoot {
                type = "gpt";

                partitions = {
                  zfs = {
                    priority = 10;
                    content = {
                      type = "zfs";
                      pool = "${zrootName}";
                    };
                  }
                  // (
                    if checkedSwapSize == 0 then { size = "100%"; } else { end = "-${toString checkedSwapSize}G"; }
                  );
                }
                // (lib.optionalAttrs (checkedSwapSize > 0) {
                  SWAP = {
                    label = "SWAP";
                    priority = 100;
                    size = "${toString checkedSwapSize}G";
                    content = {
                      type = "swap";
                      randomEncryption = true;
                    };
                  };
                })
                // (
                  # null -> platform dispatch below; attrset -> used as-is;
                  # anything else used to be SILENTLY ignored (the platform
                  # layout ran as if nothing had been passed)
                  if defineBootPartitions != null && !(lib.isAttrs defineBootPartitions) then
                    throw "The argument `defineBootPartitions` must be `null` (use the predefined layout) or an attrset of partition definitions, but is a value of type `${builtins.typeOf defineBootPartitions}`"
                  else if (lib.isAttrs defineBootPartitions) then
                    defineBootPartitions
                  else if (pkgs.stdenv.hostPlatform.system == "x86_64-linux") then
                    {
                      # priority 2 unconditionally, whether or not EF02 below
                      # exists: a gap in the priority SEQUENCE (nothing at 1)
                      # is harmless -- disko only reads it as a sort key -- and
                      # this way ESP's own definition never has to change
                      # depending on `legacyBoot`. Verified this is
                      # not just inert in theory: the generated `_create`
                      # script (the actual sgdisk commands disko runs) is
                      # byte-for-byte identical whether ESP is priority 1 or 2,
                      # since its `start = "2MiB"` already pins its real
                      # position regardless of the priority number.
                      ESP = {
                        label = "ESP";
                        priority = 2;
                        type = "EF00"; # GPT partition-type code for an EFI System Partition
                        start = "2MiB";
                        size = "2G";
                        content = {
                          type = "filesystem";
                          format = "vfat";
                          mountpoint = "/boot";
                          mountOptions = [ "umask=0077" ];
                        };
                      };
                    }
                    # A raw, unformatted `EF02` partition for GRUB's own
                    # BIOS+GPT boot mechanism: `grub-install` finds it by type
                    # code and embeds its `core.img` directly into it (no
                    # filesystem, never mounted) -- distinct from, and
                    # unrelated to, the `hybrid`/`efiGptPartitionFirst`
                    # mechanism below (that one is for firmware that reads a
                    # FAT partition via a raw MBR table entry, like a
                    # Raspberry Pi's bootrom; GRUB just needs embedding space).
                    # 1M matches disko's own `example/hybrid.nix`. Lands in the
                    # gap ESP's `start = "2MiB"` already leaves before it --
                    # verified via disko's actual generated sgdisk commands,
                    # not just size arithmetic.
                    // (lib.optionalAttrs checkedLegacyBoot {
                      EF02 = {
                        label = "EF02";
                        priority = 1;
                        type = "EF02";
                        size = "1M";
                      };
                    })
                  else if (pkgs.stdenv.hostPlatform.system == "aarch64-linux") then
                    {
                      FIRMWARE = {
                        priority = 1;
                        label = "FIRMWARE";

                        type = "0700"; # Microsoft basic data
                        # attributes = [
                        #   0 # Required Partition
                        # ];

                        start = "2MiB";
                        size = "2G";
                        content = {
                          type = "filesystem";
                          format = "vfat";
                          mountpoint = "/boot/firmware";
                          mountOptions = [
                            "noatime"
                            "noauto"
                            "x-systemd.automount"
                            "x-systemd.idle-timeout=1min"
                          ];
                        };
                      }
                      # disko's own native hybrid-MBR mechanism (sgdisk's `-h`
                      # flag under the hood): registers this GPT partition as
                      # ALSO an MBR table entry, type `0x0c` (FAT32 LBA) with
                      # the bootable/active flag set -- a Raspberry-Pi-style
                      # bootrom cannot read GPT at all and needs exactly this
                      # to find `config.txt`/`kernel.img`. `mbrBootableFlag =
                      # true` is deliberately hard-coded, NOT disko's own
                      # `example/hybrid-mbr.nix` (which uses `false`, for a
                      # Tow-Boot/UEFI chainloading setup, a different boot
                      # path): verified on real Raspberry Pi 3 hardware with
                      # the RPi's own plain firmware boot (no UEFI layer) that
                      # the flag must be SET for this exact scenario.
                      // (lib.optionalAttrs checkedLegacyBoot {
                        hybrid = {
                          mbrPartitionType = "0x0c";
                          mbrBootableFlag = true;
                        };
                      });

                      ESP = {
                        label = "ESP";
                        priority = 2;
                        type = "EF00"; # GPT partition-type code for an EFI System Partition
                        # attributes = [
                        #   2 # Legacy BIOS Bootable, for U-Boot to find extlinux config
                        # ];
                        size = "2G";
                        content = {
                          type = "filesystem";
                          format = "vfat";
                          mountpoint = "/boot";
                          mountOptions = [
                            "noatime"
                            "noauto"
                            "x-systemd.automount"
                            "x-systemd.idle-timeout=1min"
                            "umask=0077"
                          ];
                        };
                      };
                    }
                  else
                    throw ''
                      Boot partitions are not defined.
                      Boot partitions are only pre-defined for `x86_64-linux` and `aarch64-linux`
                      systems, not for `${pkgs.stdenv.hostPlatform.system}`.
                      Use the argument `defineBootPartitions` to define boot partitions.
                    ''
                );
              }
              # `efiGptPartitionFirst = false` puts the 0xEE protective entry
              # AFTER the hybridized partition(s) in the MBR table instead of
              # disko's own default (before them) -- required for a
              # Raspberry-Pi-style bootrom, which only finds its boot
              # partition if it is the FIRST MBR entry. See the `hybrid`
              # block on FIRMWARE below for the rest of this mechanism. Only
              # meaningful on aarch64-linux: `legacyBoot` on x86_64-linux
              # never sets any partition's `.hybrid`, so this would be inert
              # there anyway, but gating on the platform too keeps this
              # option scoped to the mechanism it actually belongs to.
              // (lib.optionalAttrs (checkedLegacyBoot && pkgs.stdenv.hostPlatform.system == "aarch64-linux") {
                efiGptPartitionFirst = false;
              });
          };
        };

        zpool = {
          "${zrootName}" = {
            type = "zpool";

            # Workaround: cannot import 'zroot': I/O error in disko tests
            options = {
              cachefile = "none";
              ashift = "12";
              #           compatibility = "grub2";
            };

            rootFsOptions = {
              compression = "lz4";
              acltype = "posixacl";
              xattr = "sa";
              atime = "off";
              mountpoint = "none";
              canmount = "off";
            }
            // encryptionAttributes;

            datasets = zrootGeneralDatasets // zfsFilesystemsForUsers // tmpDataset // checkedExtraDatasets;

            preCreateHook = lib.optionalString enableEncryption (
              let
                ks = keySourceFor ''
                  if which dmidecode > /dev/null 2> /dev/null; then
                    KEY="$(dmidecode --string system-uuid | tr -d '\n')"
                  else
                    # Needed in case the kexec image does not have dmidecode when using nixos-anythere or if booting from an ISO
                    KEY="$(nix run nixpkgs#dmidecode -- --string system-uuid | tr -d '\n')"
                  fi
                '';
              in
              ''
                ${ks.script}
                ${writeKeyFile ks.junkPatterns}
              ''
            );

            postMountHook = ''
              # First mount after "/" is mounted (doing installation)
              if [[ "$(zfs get -H -o value mounted ${zrootName}/ROOT/NixOS)" == "yes" ]]; then
                # Mount all datasets which are not set to (mountpoint=) legacy or none and are not already mounted
                zfs list -H -o name,mountpoint,mounted,canmount | awk '$2 != "legacy" && $2 != "none" && $3 != "yes" && $4 == "on" {print $1}' | xargs --no-run-if-empty -n 1 -t zfs mount -vR
              fi
            '';
          };
        };
      };

    };
}
