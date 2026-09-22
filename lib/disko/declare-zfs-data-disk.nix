# Per lib/default.nix's `{ lib, self, ... }` calling convention (see there).
{ ... }:
{
  /**
    Declare a non-root ZFS data pool as a NixOS module: one or more disks,
    partitioned and assigned to one pool -- `nameFn name` (default
    `zdata-<name>`) -- with a configurable vdev topology (single disks,
    mirrors, or raidz, mixed freely within one pool), a single `DATA`
    dataset mounted at `poolMountpoint`, and optional encryption keyed to
    the machine's hardware identity, exactly like `declareZfsRootDisk`.
    (See that function's own doc comment for the shared hardware-identity
    scheme and its THREAT MODEL -- both functions use the identical,
    deliberately unsalted derivation.)

    Prerequisites: same as `declareZfsRootDisk` -- the disko NixOS module
    imported, and `networking.hostId` set. Unlike the root disk, this pool
    is NOT required for the system to boot at all: it is imported during
    regular (post-initrd) boot via `boot.zfs.extraPools`, which this
    function wires up itself, alongside `boot.zfs.forceImportAll = true`.
    NixOS's own `zfs-import-<pool>.service` already performs the actual
    key-load automatically for any locked dataset whose `keylocation` is
    a file (`boot.zfs.requestEncryptionCredentials` defaults to `true`),
    so this function only needs to make sure a valid key FILE exists
    before that unit runs -- it does not reimplement key-loading itself.

    THREAT MODEL: identical to `declareZfsRootDisk` -- see that function's
    doc comment. One data-pool-specific addition: a pool built from
    multiple `vdevs` is only as resilient as its WEAKEST vdev -- ZFS
    requires every top-level vdev to stay healthy for the pool to stay
    importable at all, so mixing e.g. a small mirror and a large raidz1 in
    one pool means the pool's overall failure risk is the SUM of each
    vdev's own risk, not just whichever vdev happens to hold the data you
    care about.

    KEY MIGRATION: `keyFilePath` names where the encryption key should
    ultimately live (e.g. a sops-managed secret), but pool CREATION always
    uses the ephemeral default (`/run/zfs-data-disk-secrets/zpool.key`,
    hardware-derived, regenerated every boot) regardless of what
    `keyFilePath` is set to --
    the pool must be creatable during an unattended install (e.g.
    `nixos-anywhere`), before any secrets machinery necessarily exists on
    the target machine. Once `keyFilePath` names something other than
    that ephemeral default AND a real file exists there (e.g. sops has
    since been provisioned), the NEXT boot migrates the pool onto it
    permanently: `zfs change-key` adopts that file's content as the
    pool's real key and repoints `keylocation` at it. From then on the
    pool no longer depends on the hardware-derived key at all. Migration
    is idempotent -- it reads the pool's OWN live `keylocation` property
    each boot, not a separate stamp, so there is nothing to fall out of
    sync with reality. Leaving `keyFilePath` at its default never
    migrates: the pool stays on the ephemeral hardware-derived key
    indefinitely, exactly like `declareZfsRootDisk`.

    # Example

    ```nix
    # extLib = inputs.nixpkgs-lib-extensions.lib
    imports = [
      (extLib.declareZfsDataDisk {
        name = "bulk";
        vdevs = [
          {
            mode = "mirror";
            devicePaths = [
              "/dev/disk/by-id/ata-bulk-1"
              "/dev/disk/by-id/ata-bulk-2"
            ];
          }
        ];
        enableEncryption = true;
      })
    ];
    ```

    # Type

    ```
    declareZfsDataDisk :: Attribute -> Module
    ```

    # Arguments

    name
    : Names the pool: `nameFn name` (default `zdata-<name>`).

    nameFn
    : Formats `name` into the pool name. Default `name: "zdata-${name}"`.

    vdevs
    : A list of `{ mode ? null; devicePaths; }` vdev groups, each becoming
    : one real ZFS vdev in the pool. `mode = null` means an independent,
    : unmirrored single disk -- it requires EXACTLY one `devicePaths`
    : entry (list N disks as N separate `mode = null` entries instead of
    : one entry with N paths; ZFS has no "grouped stripe" vdev type, and
    : `null` with more than one path would silently produce N independent
    : vdevs anyway -- this function makes that explicit instead).
    : `mode = "mirror"` (or `"raidz"`/`"raidz1"`) needs at least 2;
    : `"raidz2"` needs at least 3; `"raidz3"` needs at least 4 -- disko
    : itself does not enforce these minimums, so this function throws
    : instead of letting a too-small raidz surface as an opaque `zpool
    : create` failure. Multiple vdevs of DIFFERENT modes in one `vdevs`
    : list are allowed (ZFS permits it), though see the THREAT MODEL
    : paragraph above for why that is not necessarily a good idea.

    enableEncryption
    : Whether the pool should be encrypted. Default `true`. See the KEY
    : MIGRATION paragraph above and `keyFilePath`/`keySourceCommand`
    : below.

    keyFilePath
    : Default `"/run/zfs-data-disk-secrets/zpool.key"` -- deliberately NOT
    : `declareZfsRootDisk`'s own `/tmp/secrets/zpool.key`: that path is
    : safe for root only because root's key-write and key-load both
    : happen inside the initrd's own throwaway `/tmp`, before
    : `switch_root`. This function's key-write and NixOS's own automatic
    : key-load happen in the REAL, post-switch_root system, where `/tmp`
    : may itself be a real ZFS mount (e.g. a host with `useZfsForTmp =
    : true` on its root disk) that mounts later in boot than this
    : function's key-writer runs -- confirmed on a real deployment: the
    : key file was written, then silently shadowed once the real `/tmp`
    : mounted on top of it, so `zfs-import-<pool>.service`'s own
    : automatic key-load found nothing there. `/run` is always tmpfs,
    : mounted essentially at the start of boot, so it carries no such
    : race regardless of the host's own `/tmp` configuration. Leaving
    : `keyFilePath` unset never migrates (see KEY MIGRATION above): the
    : pool stays on the ephemeral hardware-derived key at that exact path
    : forever. Set it to a real, persistent path (e.g. a sops secret) to
    : migrate onto it once that file exists. This function is entirely
    : secrets-manager-agnostic -- it never reads sops or anything else
    : itself, `keyFilePath` is just a path it compares against and, once
    : migrated, hands to `zfs change-key`.

    keySourceCommand
    : Overrides where the EPHEMERAL default key comes from (the
    : hardware-identity dispatch `declareZfsRootDisk` also uses:
    : `dmidecode` on x86_64-linux, `/proc/cpuinfo`'s `Serial` on
    : aarch64-linux). Default `null` (use that predefined dispatch). Has
    : no effect on a key already migrated to `keyFilePath` -- see KEY
    : MIGRATION above.

    poolMountpoint
    : Where the pool's single `DATA` dataset mounts. Default `"/data"`.
    : `null` gives `DATA` no mountpoint at all (`options.mountpoint =
    : "none";`) -- a pure parent for datasets you add via `extraDatasets`,
    : the same idiom `declareZfsRootDisk`'s own `ROOT` dataset uses.

    extraDatasets
    : Identical mechanism to `declareZfsRootDisk`'s own `extraDatasets`:
    : an attribute set of additional zfs datasets, merged in last (so it
    : can also override `DATA` itself). Parent datasets are not created
    : implicitly -- declare them too.
  */
  declareZfsDataDisk =
    {
      name,
      nameFn ? (n: "zdata-${n}"),
      vdevs,
      enableEncryption ? true,
      keyFilePath ? "/run/zfs-data-disk-secrets/zpool.key",
      keySourceCommand ? null,
      poolMountpoint ? "/data",
      extraDatasets ? { },
    }:
    {
      config,
      pkgs,
      lib,
      ...
    }:
    let
      hardwareKey = import ./internal/hardware-key.nix { inherit lib pkgs; };

      poolName = nameFn name;

      # The ephemeral, hardware-derived key's path -- a PRIVATE constant,
      # deliberately NOT the `keyFilePath` argument: pool CREATION always
      # uses this exact path (see the KEY MIGRATION doc section above),
      # regardless of what `keyFilePath` is currently declared to be.
      # `keyFilePath` only names the migration TARGET. Deliberately under
      # `/run` (tmpfs, always mounted early), not `/tmp` like
      # `declareZfsRootDisk`'s own initrd-scoped key -- see the
      # `keyFilePath` doc section above for why `/tmp` is unsafe here.
      defaultKeyFilePath = "/run/zfs-data-disk-secrets/zpool.key";

      encryptionAttributes =
        if (lib.isBool enableEncryption) then
          (lib.optionalAttrs enableEncryption {
            encryption = "on";
            keyformat = "passphrase";
            keylocation = "file://${defaultKeyFilePath}";
          })
        else
          throw "The argument `enableEncryption` must be of type `boolean`";

      writeKeyFile = hardwareKey.writeKeyFile defaultKeyFilePath;
      checkedKeySourceCommand = hardwareKey.checkedKeySourceCommand "declareZfsDataDisk" keySourceCommand;
      keySourceFor =
        dmidecodeInvocation:
        hardwareKey.keySourceFor {
          functionName = "declareZfsDataDisk";
          inherit keySourceCommand dmidecodeInvocation;
        };

      checkedExtraDatasets =
        if (lib.isAttrs extraDatasets) then
          extraDatasets
        else
          throw "The argument `extraDatasets` must be of type `attrset` (dataset path -> disko dataset definition)";

      checkedPoolMountpoint =
        if poolMountpoint == null || lib.isString poolMountpoint then
          poolMountpoint
        else
          throw "The argument `poolMountpoint` must be `null` or a string (an absolute path), but is a value of type `${builtins.typeOf poolMountpoint}`";

      # A vdev group's `mode` dictates the MINIMUM number of devicePaths
      # it can possibly mean something with -- disko itself does not
      # enforce this (its `mode` type is just a string enum, with no tie
      # to a vdev's member count), so an under-sized raidz would
      # otherwise surface only as an opaque `zpool create` failure at
      # install time instead of an eval-time throw naming the offending
      # entry.
      modeMinDevices =
        index: mode:
        if mode == null then
          1
        else if
          lib.elem mode [
            "mirror"
            "raidz"
            "raidz1"
          ]
        then
          2
        else if mode == "raidz2" then
          3
        else if mode == "raidz3" then
          4
        else
          throw "declareZfsDataDisk: `vdevs.[${toString index}].mode` must be `null`, `\"mirror\"`, `\"raidz\"`, `\"raidz1\"`, `\"raidz2\"`, or `\"raidz3\"`, but is `${builtins.toJSON mode}`.";

      checkedVdev =
        index: vdev:
        if !(lib.isAttrs vdev) then
          throw "declareZfsDataDisk: `vdevs.[${toString index}]` must be an attrset (`{ mode ? null; devicePaths; }`), but is a value of type `${builtins.typeOf vdev}`"
        else
          let
            mode = vdev.mode or null;
            devicePaths =
              if !(vdev ? devicePaths) then
                throw "declareZfsDataDisk: `vdevs.[${toString index}]` is missing `devicePaths`"
              else if !(lib.isList vdev.devicePaths) then
                throw "declareZfsDataDisk: `vdevs.[${toString index}].devicePaths` must be a list, but is a value of type `${builtins.typeOf vdev.devicePaths}`"
              else
                vdev.devicePaths;
            count = lib.length devicePaths;
            minDevices = modeMinDevices index mode;
          in
          if mode == null && count != 1 then
            throw "declareZfsDataDisk: `vdevs.[${toString index}]` has `mode = null` (an independent, unmirrored disk) but ${toString count} `devicePaths` -- `null` only ever means exactly ONE disk; list each additional disk as its own `vdevs` entry instead."
          else if count < minDevices then
            throw "declareZfsDataDisk: `vdevs.[${toString index}]` has `mode = ${builtins.toJSON mode}`, which needs at least ${toString minDevices} `devicePaths`, but only ${toString count} were given."
          else
            {
              inherit mode devicePaths;
            };

      checkedVdevs =
        if !(lib.isList vdevs) then
          throw "declareZfsDataDisk: `vdevs` must be a list, but is a value of type `${builtins.typeOf vdevs}`"
        else if vdevs == [ ] then
          throw "declareZfsDataDisk: `vdevs` is empty -- a pool needs at least one vdev."
        else
          lib.imap0 checkedVdev vdevs;

      allDevicePaths = lib.concatMap (v: v.devicePaths) checkedVdevs;
      duplicateDevicePaths = lib.unique (
        lib.filter (p: lib.count (q: q == p) allDevicePaths > 1) allDevicePaths
      );
      checkedVdevsNoDuplicates =
        if duplicateDevicePaths == [ ] then
          checkedVdevs
        else
          throw "declareZfsDataDisk: the same device path is used in more than one `vdevs` entry (${lib.concatStringsSep ", " duplicateDevicePaths}); each device can only belong to one vdev.";

      # Disko disk-attribute and vdev-member names, both scoped by the
      # POOL name (not the bare `name` argument): the pool name is what
      # actually has to be unique per host for ZFS itself to work, so
      # keying collision-avoidance off it also covers a custom `nameFn`
      # correctly, and it matches NixOS's own `zfs-import-<pool>.service`
      # naming (see the boot-time units below) so the two are trivially
      # correlated by eye.
      vdevsWithDiskNames = lib.imap0 (
        i: v:
        v
        // {
          diskNames = lib.imap0 (j: _: "${poolName}-vdev${toString i}-disk${toString j}") v.devicePaths;
        }
      ) checkedVdevsNoDuplicates;

      # `null` -> disko's own `""` (the "independent single disk" marker
      # in its vdev-topology type); any other mode is disko's own string
      # verbatim.
      diskoModeFor = mode: if mode == null then "" else mode;

      diskAttrs = lib.listToAttrs (
        lib.concatMap (
          v:
          lib.zipListsWith (diskName: devicePath: {
            name = diskName;
            value = {
              type = "disk";
              device = devicePath;
              content = {
                type = "gpt";
                partitions.zfs = {
                  size = "100%";
                  content = {
                    type = "zfs";
                    pool = poolName;
                  };
                };
              };
            };
          }) v.diskNames v.devicePaths
        ) vdevsWithDiskNames
      );

      topologyVdevs = map (v: {
        mode = diskoModeFor v.mode;
        members = v.diskNames;
      }) vdevsWithDiskNames;

      dataDataset = {
        "DATA" = {
          type = "zfs_fs";
          options =
            if checkedPoolMountpoint == null then
              { mountpoint = "none"; }
            else
              {
                mountpoint = checkedPoolMountpoint;
                canmount = "on";
              };
        };
      };

      zfsPackageBin = bin: "${config.boot.zfs.package}/sbin/${bin}";
    in
    {
      _file = ./declare-zfs-data-disk.nix;

      boot.zfs.extraPools = [ poolName ];
      boot.zfs.forceImportAll = lib.mkDefault true;

      # `requestEncryptionCredentials` is a SINGLE, host-wide option (not
      # scoped per-pool), and `declareZfsRootDisk` deliberately sets it
      # to a plain `[ ]` -- opting the ROOT pool's own already-initrd-
      # unlocked dataset out of a redundant boot-time prompt. Since a
      # plain-list definition WINS over the option's own `true` default
      # (see declareZfsRootDisk's own comment on this exact mechanism),
      # that `[ ]` silently disables NixOS's automatic key-load for
      # EVERY pool on the host, not just root -- confirmed on a real
      # deployment: `zdata-bulk` imported successfully but its key was
      # never loaded, because nothing had asked for it explicitly. This
      # pool asks for itself, the same way: a plain list concatenates
      # with root's `[ ]` (and anything else) for free, no `lib.mkDefault`
      # (which would lose to root's plain assignment and be silently
      # discarded, per the exact footgun `declareZfsRootDisk`'s own
      # `lib/disko/README.md` section documents).
      boot.zfs.requestEncryptionCredentials = lib.optional enableEncryption poolName;

      # Only NixOS's own automatic key-load (requestEncryptionCredentials,
      # default true -- see this function's doc comment) needs a real key
      # FILE to exist before `zfs-import-${poolName}.service` runs; the
      # migration below runs after that same unit, once the pool is
      # already unlocked.
      #
      # Plain `if/else`, not `lib.mkIf`: `systemd.services` is an
      # `attrsOf submodule` keyed by service name, not a single
      # scalar-merge-priority option, so nothing here needs `mkIf`'s
      # merge semantics -- and a plain conditional evaluates to a REAL
      # attrset immediately, so this function stays directly testable
      # (like `checks/zfs-root-disk.nix`) without going through
      # `lib.evalModules` first to resolve an `mkIf` wrapper.
      systemd.services =
        if !enableEncryption then
          { }
        else
          let
            keyWriterSource = keySourceFor ''
              KEY="$(dmidecode --string system-uuid | tr -d '\n')"
            '';
          in
          {
            "zfs-data-key-${poolName}" = {
              description = "Create the ZFS encryption key file for ${poolName} from the machine's hardware identity";
              # Ordered BEFORE zfs-import-<pool>.service, which is itself
              # upstream of local-fs.target -> sysinit.target -- a plain
              # service picks up systemd's IMPLICIT `After=sysinit.target`
              # by default, which would make this and zfs-import-<pool>
              # order each other in a cycle (systemd breaks it by
              # deleting an edge arbitrarily, silently making the ordering
              # unreliable, rather than a hard failure). Same reason
              # declareZfsRootDisk's own initrd-context key-file unit
              # sets this.
              unitConfig.DefaultDependencies = false;
              wantedBy = [ "zfs-import-${poolName}.service" ];
              before = [ "zfs-import-${poolName}.service" ];
              after = [ "systemd-modules-load.service" ];
              # Guaranteed present (unlike preCreateHook's arbitrary
              # install-time environment below), so no `which`-guarded
              # fallback is needed here.
              path = lib.optional (
                checkedKeySourceCommand == null && pkgs.stdenv.hostPlatform.system == "x86_64-linux"
              ) pkgs.dmidecode;
              serviceConfig = {
                Type = "oneshot";
                RemainAfterExit = true;
              };
              script = ''
                ${keyWriterSource.script}
                ${writeKeyFile keyWriterSource.junkPatterns}
              '';
            };
          }
          # `keyFilePath == defaultKeyFilePath` (the un-migrated, default
          # case -- IT-03400's own, for instance) never needs this unit
          # AT ALL: leaving it defined with an empty `script` still
          # produces a [Service] section with no `ExecStart=`, which
          # systemd rejects outright as a "bad unit file setting" --
          # confirmed on a real deployment, not just a theoretical
          # concern. Omitting the whole unit, not just its script body,
          # is what actually keeps the common case inert.
          // lib.optionalAttrs (keyFilePath != defaultKeyFilePath) {
            "zfs-data-key-migrate-${poolName}" = {
              description = "Migrate ${poolName}'s encryption key from the ephemeral default to the declared keyFilePath, once one exists";
              # After, not before, zfs-import-<pool>.service -- same
              # cycle risk as the key-writer above, same fix.
              unitConfig.DefaultDependencies = false;
              wantedBy = [ "zfs-import-${poolName}.service" ];
              after = [ "zfs-import-${poolName}.service" ];
              serviceConfig = {
                Type = "oneshot";
                RemainAfterExit = true;
              };
              script = ''
                if ! ${zfsPackageBin "zpool"} list "${poolName}" > /dev/null 2>&1; then
                  # the pool did not actually import -- nothing to migrate
                  exit 0
                fi
                current_keylocation="$(${zfsPackageBin "zfs"} get -H -o value keylocation "${poolName}" 2>/dev/null || true)"
                if [ "$current_keylocation" != "file://${defaultKeyFilePath}" ]; then
                  # already migrated (or the pool was never on the default
                  # in the first place) -- idempotent no-op
                  exit 0
                fi
                if [ ! -e "${keyFilePath}" ]; then
                  # the migration target does not exist YET (e.g. sops has
                  # not provisioned it on this boot) -- stay on the
                  # ephemeral default and try again next boot
                  exit 0
                fi
                ${zfsPackageBin "zfs"} change-key -o keylocation="file://${keyFilePath}" -o keyformat=passphrase "${poolName}"
              '';
            };
          };

      disko.devices = {
        disk = diskAttrs;
        zpool.${poolName} = {
          type = "zpool";
          # `type = "topology"` is REQUIRED, not just documentation: disko's
          # own subType dispatch mechanism (a separate, freeform-typed
          # mini-`evalModules` used only to pick which real submodule
          # applies) reads it from the RAW input directly, before the real
          # `topology` submodule -- whose OWN `type` option happens to
          # default to the same string -- ever gets a chance to apply that
          # default. Omitting it throws "the option `type' was accessed
          # but has no value defined", not a friendlier type error --
          # verified directly against disko (this repo has no disko input
          # of its own; see lib/disko/README.md).
          mode = {
            topology = {
              type = "topology";
              vdev = topologyVdevs;
            };
          };
          options = {
            cachefile = "none";
            ashift = "12";
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
          mountpoint = null;
          datasets = dataDataset // checkedExtraDatasets;

          preCreateHook = lib.optionalString enableEncryption (
            let
              ks = keySourceFor ''
                if which dmidecode > /dev/null 2> /dev/null; then
                  KEY="$(dmidecode --string system-uuid | tr -d '\n')"
                else
                  # Needed in case the kexec image does not have dmidecode when using nixos-anywhere or if booting from an ISO
                  KEY="$(nix run nixpkgs#dmidecode -- --string system-uuid | tr -d '\n')"
                fi
              '';
            in
            ''
              ${ks.script}
              ${writeKeyFile ks.junkPatterns}
            ''
          );
        };
      };
    };
}
