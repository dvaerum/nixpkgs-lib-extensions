{
  /**
    Generate a zfs filesystem for a user

    # Example

    ```nix
    DeclareZfsRootDisk {
      inherit pkgs lib;
      devicePath = "/dev/disk/by-id/nvme-WDC_PC_SN479_WEFWOER-512G-1233_23425X589324";
      listOfUsernames = [ "foo" { name: "bar"; } { name: "bar"; home: "/home/bar2"; } ]
      hostname = config.networking.hostname;
      enableEncryption = false;
    }
    =>
    { ... }
    ```

    # Type

    ```
    DeclareZfsRootDisk :: Attribute -> Attribute
    ```

    # Arguments

    pkgs
    : `pkgs` from nixpkgs or the nixpkgs 😅 Need for the `dmidecode` package

    lib
    : `lib` from nixpkgs.

    devicePath
    : The absolute path to the device

    hostname
    : The name of the device. The pool will be name: zroot-<HOSTNAME>

    enableEncryption
    : Enable or Disable of the drive should be encrypted.
    : Currently the encryption is using the motherboards UUID.
    : You can find it with the command: `dmidecode --string system-uuid`

    swapSize
    : Set the size (in GiB) of the SWAP partition. Default is `32`.
    : Set it to `0` to disable having a SWAP partition.

    listOfUsernames
    : A list of `string` or `attribute` element (may be mixed).
    : The `string` element is: <USERNAME>.
    : The `attribute` element is: { name = "<USERNAME>"; mountpoint = "<MOUNTPOINT>"; }

    defineBootPartitions
    : Defines boot partitions for systems that are not `x86_64-linux` or `aarch64-linux`,
    : or when boot partitions must be overwritten
  */
  declareZfsRootDisk = {
    pkgs,
    lib,
    devicePath,
    hostname,
    enableEncryption ? true,
    swapSize ? 32,
    listOfUsernames,
    defineBootPartitions ? null
  }:
  let

    zroot_name = "zroot-${hostname}";

    encryption_attribures =
      if ( builtins.isBool enableEncryption )
      then ( lib.optionalAttrs enableEncryption {
        encryption = "on";
        keyformat = "passphrase";
        keylocation = "file:///tmp/secrets/zpool.key";
      })
      else throw "The argument `enableEncryption` must be of type `boolean`";

    swap_size =
      if ( builtins.isInt swapSize && swapSize >= 0 )
      then swapSize
      else throw "The size of the SWAP partition in Gigabytes. If 0 when no SWAP partition will be created. The value can be negative"
    ;

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
      : The `attribute` element is: { name = "<USERNAME>"; mountpoint = "<MOUNTPOINT>"; }

    */
    gen_zfs_user_folder = ( user_setting:
      let
        user =
          if ( builtins.isString user_setting )
          then { name = user_setting; }
          else if ( builtins.isAttrs user_setting && ( builtins.hasAttr "username" user_setting ))
          then { name = user_setting.username; mountpoint = user_setting.mountpoint; }
          else ( throw "The element in `listOfUsernames` can either be a `string` or `attrset` ({ username = ...; mountpoint = ...; })" )
        ;
      in
      {
        name = "HOME/${user.name}";
        value = {
          type = "zfs_fs";
          options = (
            lib.optionalAttrs
            ( builtins.hasAttr "mountpoint" user )
            { inherit (user) mountpoint; }
          )
          // encryption_attribures;
          # By adding encryption attributes to the user folder filesystem,
          # it will make it possible to switch to use the password of the user as the passphrase.
        };
      }
    );


    zfs_filesystems_for_users = builtins.listToAttrs (
      lib.lists.forEach listOfUsernames gen_zfs_user_folder
    );

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
          canmount = "off";
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
    boot.supportedFilesystems = [ "zfs" ];

    boot.zfs.devNodes = lib.mkDefault "/dev/disk/by-partuuid";
    boot.zfs.forceImportRoot = lib.mkDefault true;
    boot.zfs.requestEncryptionCredentials = lib.mkDefault enableEncryption;

    security.pam.zfs = lib.mkIf enableEncryption {
      enable = true;
      homes = lib.mkDefault "${zroot_name}/HOME";
    };

    services.zfs.autoScrub.enable = lib.mkDefault true;
    services.zfs.trim.enable = lib.mkDefault true;

    systemd.services.systemd-journal-flush.after = [ "zfs-import.target" "zfs-mount.service" ];


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
                # size = "100%";
                end = "-${toString swap_size}G";
                content = {
                  type = "zfs";
                  pool = "${zroot_name}";
                };
              };
            } // ( lib.optionalAttrs ( swap_size > 0 ) {
              SWAP = {
                label = "SWAP";
                priority = 100;
                size = "${toString swap_size}G";
                content = {
                  type = "swap";
                  randomEncryption = true;
                };
              };
            }) // (
              if ( builtins.isAttrs defineBootPartitions )
              then defineBootPartitions
              else if ( pkgs.stdenv.hostPlatform.system == "x86_64-linux" )
              then {
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
              else if ( pkgs.stdenv.hostPlatform.system == "aarch64-linux" )
              then {
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
              else throw ''
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
          } // encryption_attribures;

          datasets = zroot_general_datasets // zfs_filesystems_for_users;

          preCreateHook = lib.optionalString enableEncryption ''
            if which dmidecode > /dev/null 2> /dev/null; then
              KEY="$(dmidecode --string system-uuid | tr -d '\n')"
            else
              # Needed in case the kexec image does not have dmidecode when using nixos-anythere or if booting from an ISO
              KEY="$(nix run nixpkgs#dmidecode -- --string system-uuid | tr -d '\n')"
            fi
            SECRET_FOLDER_PATH="/tmp/secrets"
            KEY_FILE_PATH="$SECRET_FOLDER_PATH/zpool.key"

            if ! [[ -d "$SECRET_FOLDER_PATH" ]]; then
              rm -rf "$SECRET_FOLDER_PATH"
            fi

            mkdir -p "$SECRET_FOLDER_PATH"
            chmod 700 "$SECRET_FOLDER_PATH"
            cat <<<"$KEY" > "$KEY_FILE_PATH"
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

    boot.initrd.postDeviceCommands = lib.mkIf enableEncryption ''
      KEY="$(${pkgs.dmidecode}/bin/dmidecode --string system-uuid | tr -d '\n')"
      SECRET_FOLDER_PATH="/tmp/secrets"
      KEY_FILE_PATH="$SECRET_FOLDER_PATH/zpool.key"

      if ! [[ -d "$SECRET_FOLDER_PATH" ]]; then
        rm -rf "$SECRET_FOLDER_PATH"
      fi

      mkdir -p "$SECRET_FOLDER_PATH"
      chmod 700 "$SECRET_FOLDER_PATH"
      echo -n "$KEY" > "$KEY_FILE_PATH"
    '';
  };
}
