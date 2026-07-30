{
  /**
    Declare a complete ZFS root disk as a NixOS module: GPT partitions
    (boot/ESP, optional swap, zfs), the `zroot-<hostname>` pool, the
    standard datasets (root, /var, /var/log, /nix/store, /home, optional
    /tmp) plus one HOME dataset per user, with optional encryption keyed
    to the motherboard's UUID.

    Prerequisites: the disko NixOS module must be imported (it provides
    the `disko.devices` options -- automatic when disko is a flake input
    of a `nixosConfigurationsBuilder` setup), and ZFS requires
    `networking.hostId` to be set.

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
    : Currently the encryption is using the motherboards UUID as the key.
    : You can find it with the command: `dmidecode --string system-uuid`

    swapSize
    : Set the size (in GiB) of the SWAP partition. Default is `32`.
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
      swapSize ? 32,
      useZfsForTmp ? true,
      listOfUsernames,
      defineBootPartitions ? null,
      extraDatasets ? { },
    }:
    # Returns a module function (valid in `imports`) so the actual initrd
    # type can be read from `config`, `pkgs` & `lib` instead
    # of having to pass them as arguments.
    {
      config,
      pkgs,
      lib,
      ...
    }:
    let

      zroot_name = "zroot-${hostname}";

      encryption_attribures =
        if (builtins.isBool enableEncryption) then
          (lib.optionalAttrs enableEncryption {
            encryption = "on";
            keyformat = "passphrase";
            keylocation = "file:///tmp/secrets/zpool.key";
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
      write_key_file = ''
        SECRET_FOLDER_PATH="/tmp/secrets"
        KEY_FILE_PATH="$SECRET_FOLDER_PATH/zpool.key"

        # A leftover NON-directory here (a file, or a dangling symlink)
        # would make the mkdir below fail, so it is removed; an existing
        # directory is kept and its key file simply overwritten.
        if ! [[ -d "$SECRET_FOLDER_PATH" ]]; then
          rm -rf "$SECRET_FOLDER_PATH"
        fi

        mkdir -p "$SECRET_FOLDER_PATH"
        chmod 700 "$SECRET_FOLDER_PATH"

        # printf, never `echo -n` or a here-string: the key must land in the
        # file verbatim, with no trailing newline.
        printf '%s' "$KEY" > "$KEY_FILE_PATH"
      '';

      swap_size =
        if (builtins.isInt swapSize && swapSize >= 0) then
          swapSize
        else
          throw "The argument `swapSize` must be an integer >= 0 (GiB); 0 disables the SWAP partition";

      # Additional zfs datasets requested by the caller. Keys are dataset paths
      # relative to the pool root (e.g. "DATA/media" becomes
      # <zroot_name>/DATA/media); parent datasets must be declared by the caller too.
      extra_datasets =
        if (builtins.isAttrs extraDatasets) then
          extraDatasets
        else
          throw "The argument `extraDatasets` must be of type `attrset` (dataset path -> disko dataset definition)";

      /**
        Generate a zfs filesystem for a user

        # Example

        ```nix
        gen_zfs_user_folder "foo"
        =>
        { "HOME/foo" = { type = "zfs_fs"; ... }; }
        ```

        # Type

        ```
        gen_zfs_user_folder :: String || Attribute -> Attribute
        ```

        # Arguments

        user_setting
        : Takes a value of the `string` or `attribute.
        : The `string` element is: <USERNAME>.
        : The `attribute` element is: { username = "<USERNAME>"; mountpoint = "<MOUNTPOINT>"; }
      */
      gen_zfs_user_folder = (
        user_setting:
        let
          user =
            if (builtins.isString user_setting) then
              { name = user_setting; }
            else if (builtins.isAttrs user_setting && (builtins.hasAttr "username" user_setting)) then
              # `mountpoint` is OPTIONAL -- the guard further down already
              # says so, but reading it unconditionally here made that guard
              # dead code and turned `{ username = "bar"; }` into a bare
              # "attribute 'mountpoint' missing" that named neither
              # listOfUsernames nor declareZfsRootDisk.
              {
                name = user_setting.username;
              }
              // lib.optionalAttrs (builtins.hasAttr "mountpoint" user_setting) {
                inherit (user_setting) mountpoint;
              }
            else
              (throw "The element in `listOfUsernames` can either be a `string` or `attrset` ({ username = ...; mountpoint = ...; })");
        in
        {
          name = "HOME/${user.name}";
          value = {
            type = "zfs_fs";
            options =
              (lib.optionalAttrs (builtins.hasAttr "mountpoint" user) { inherit (user) mountpoint; })
              // encryption_attribures;
            # By adding encryption attributes to the user folder filesystem,
            # it will make it possible to switch to use the password of the user as the passphrase.
          };
        }
      );

      # listToAttrs keeps the LAST entry for a repeated key, so two entries
      # for the same user -- with different mountpoints, say -- would have
      # silently collapsed into whichever came last.
      zfs_user_folders = lib.lists.forEach listOfUsernames gen_zfs_user_folder;
      duplicate_user_datasets =
        let
          names = map (e: e.name) zfs_user_folders;
        in
        lib.unique (lib.filter (n: lib.count (m: m == n) names > 1) names);
      zfs_filesystems_for_users =
        if duplicate_user_datasets == [ ] then
          builtins.listToAttrs zfs_user_folders
        else
          throw "declareZfsRootDisk: `listOfUsernames` names the same user more than once (${
            builtins.concatStringsSep ", " (map (n: lib.removePrefix "HOME/" n) duplicate_user_datasets)
          }); only the last entry would have survived.";

      zroot_general_datasets = {
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

      # systemd stage 1 does not support boot.initrd.postDeviceCommands or
      # boot.initrd.postResumeCommands.
      useSystemdInitrd = config.boot.initrd.systemd.enable;

      use_zfs_for_tmp = lib.optionalAttrs useZfsForTmp {
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
      _file = "nixpkgs-lib-extensions/lib/disko/declare-zfs-root-disk.nix";

      boot = {
        supportedFilesystems = [ "zfs" ];

        zfs = {
          devNodes = lib.mkDefault "/dev/disk/by-partuuid";
          forceImportRoot = lib.mkDefault true;

          # Left at NixOS's default (true) when encrypting: the key file is
          # derived from the motherboard's UUID, so a board swap, a machine
          # reporting "Not Settable", or a restored-elsewhere pool leaves a
          # dataset locked. With this false there is no fallback at all --
          # the visible symptom is a sysroot.mount timeout, with the real
          # cause several screens earlier. Leaving it true means stage 1
          # ASKS for the passphrase for anything the key file did not
          # unlock, which is the difference between a recoverable boot and
          # a rescue USB. Datasets the key file did unlock are never
          # prompted for.
          requestEncryptionCredentials = lib.mkIf (!enableEncryption) (lib.mkDefault false);
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
        extraBin = {
          dmidecode = "${pkgs.dmidecode}/bin/dmidecode";
        };

        services.zfs-key-file-setup = {
          description = "Create ZFS encryption key file from system UUID";
          unitConfig.DefaultDependencies = false;
          wantedBy = [ "zfs-import-${zroot_name}.service" ];
          before = [ "zfs-import-${zroot_name}.service" ];
          after = [ "systemd-modules-load.service" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
          };
          script = ''
            KEY="$(dmidecode --string system-uuid | tr -d '\n')"
            ${write_key_file}
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
            "zfs-import-${zroot_name}.service"
          ];
          before = [
            "zfs-import.target"
            "sysroot.mount"
          ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
          };
          script = ''
            zfs list -rHo name,keylocation,keystatus -t volume,filesystem | \
            while IFS=$'\t' read -r dataset keylocation keystatus; do
              if [[ "$keystatus" != "unavailable" ]]; then
                continue
              fi
              case "$keylocation" in
                none|prompt ) ;;
                # `|| true` on purpose: one dataset that cannot be unlocked
                # must not abort the loop and leave the REST locked too.
                # But say which one -- silently swallowing this is what
                # turned a wrong key into an unexplained sysroot.mount
                # timeout. boot.zfs.requestEncryptionCredentials then
                # prompts for whatever is still locked.
                * ) zfs load-key "$dataset" \
                      || echo "zfs-load-encryption-keys: could not load the key for $dataset (keylocation=$keylocation); it stays locked" >&2 ;;
              esac
            done
          '';
        };
      };

      # script-based initrd (boot.initrd.systemd.enable = false):
      # encryption keys via the legacy initrd hooks
      boot.initrd.postDeviceCommands = lib.mkIf (enableEncryption && !useSystemdInitrd) ''
        KEY="$(${pkgs.dmidecode}/bin/dmidecode --string system-uuid | tr -d '\n')"
        ${write_key_file}
      '';

      boot.initrd.postResumeCommands = lib.mkIf (enableEncryption && !useSystemdInitrd) (
        lib.mkAfter ''
          zfs list -rHo name,keylocation,keystatus -t volume,filesystem | \
          while IFS=$'\t' read -r dataset keylocation keystatus; do
            if [[ "$keystatus" != "unavailable" ]]; then
              continue
            fi
            case "$keylocation" in
              none|prompt ) ;;
              * ) zfs load-key "$dataset" || true ;;
            esac
          done
        ''
      );

      security.pam.zfs = lib.mkIf enableEncryption {
        enable = true;
        homes = lib.mkDefault "${zroot_name}/HOME";
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

            content = {
              type = "gpt";

              partitions = {
                zfs = {
                  priority = 10;
                  content = {
                    type = "zfs";
                    pool = "${zroot_name}";
                  };
                }
                // (if swap_size == 0 then { size = "100%"; } else { end = "-${toString swap_size}G"; });
              }
              // (lib.optionalAttrs (swap_size > 0) {
                SWAP = {
                  label = "SWAP";
                  priority = 100;
                  size = "${toString swap_size}G";
                  content = {
                    type = "swap";
                    randomEncryption = true;
                  };
                };
              })
              // (
                if (builtins.isAttrs defineBootPartitions) then
                  defineBootPartitions
                else if (pkgs.stdenv.hostPlatform.system == "x86_64-linux") then
                  {
                    ESP = {
                      label = "ESP";
                      priority = 1;
                      type = "EF00";
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
                    };

                    ESP = {
                      label = "ESP";
                      priority = 2;
                      type = "EF00";
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
                    Use the argument `defineBootPartitions` to defined boot partitions.
                  ''
              );
            };
          };
        };

        zpool = {
          "${zroot_name}" = {
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
            // encryption_attribures;

            datasets = zroot_general_datasets // zfs_filesystems_for_users // use_zfs_for_tmp // extra_datasets;

            preCreateHook = lib.optionalString enableEncryption ''
              if which dmidecode > /dev/null 2> /dev/null; then
                KEY="$(dmidecode --string system-uuid | tr -d '\n')"
              else
                # Needed in case the kexec image does not have dmidecode when using nixos-anythere or if booting from an ISO
                KEY="$(nix run nixpkgs#dmidecode -- --string system-uuid | tr -d '\n')"
              fi
              ${write_key_file}
            '';

            postMountHook = ''
              # First mount after "/" is mounted (doing installation)
              if [[ "$(zfs get -H -o value mounted ${zroot_name}/ROOT/NixOS)" == "yes" ]]; then
                # Mount all datasets which are not set to (mountpoint=) legacy or none and are not already mounted
                zfs list -H -o name,mountpoint,mounted,canmount | awk '$2 != "legacy" && $2 != "none" && $3 != "yes" && $4 == "on" {print $1}' | xargs --no-run-if-empty -n 1 -t zfs mount -vR
              fi
            '';
          };
        };
      };

    };
}
