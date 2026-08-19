# Intro

Some extra notes about using disko to format disks.


# Tips and Tricks

## Raspberry PI 3 - Add legacy bios support

Raspberry Pi 3 bootrom only understands MBR, not GPT.
After disko formats the disk and filesystems are unmounted, run:

```bash
sudo gdisk /dev/sdX   # replace sdX with your device
# Enter: r (recovery), h (hybrid MBR), 1 (partition 1)
# Answer: n (EFI GPT not first), 0c (FAT32 LBA type), y (bootable), n (no extra)
# Enter: w (write), y (confirm)
```

Or non-interactively:

```bash
echo -e "r\nh\n1\nn\n0c\ny\nn\nw\ny" | sudo gdisk /dev/sdX
```

This creates a hybrid MBR where the FIRMWARE partition appears as
MBR partition 1 (bootable, FAT32) so the Pi bootrom can find it,
while preserving GPT for Linux to read all partitions correctly.

## declareZfsRootDisk + a login-unlocked (PAM) home dataset

`declareZfsRootDisk` sets `boot.zfs.requestEncryptionCredentials =
lib.mkDefault [ ]`. NixOS's own default (`true`) recursively scans the
whole pool at boot and interactively prompts for anything still
locked -- which is redundant for every dataset this function creates
(they're all `keylocation=file://...`, already handled once by this
function's own key-loading script) and actively wrong for a dataset
you want unlocked at LOGIN instead of at boot, e.g. a per-user home
managed by
[`security.pam.zfs`](https://search.nixos.org/options?query=security.pam.zfs):
left at `true`, that dataset would ALSO get an unwanted boot-time
password prompt on every boot, on top of the login-time unlock.

If you add your own `keylocation=prompt` dataset and DO want NixOS's
boot-time passphrase fallback for it, override the default on that
host:

```nix
boot.zfs.requestEncryptionCredentials = [ "mypool/mydataset" ];
```

See `declareZfsRootDisk`'s own doc comment (`docs/lib.md`) for the
full reasoning and the manual RECOVERY procedure after a motherboard
swap.


