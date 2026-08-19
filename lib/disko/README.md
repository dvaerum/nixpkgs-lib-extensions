# Intro

Some extra notes about using disko to format disks.


# Tips and Tricks

## Raspberry PI 3 - Add legacy bios support

The Raspberry Pi 3's bootrom (the fixed boot firmware built into the
board, not something you can change) only understands MBR (Master
Boot Record), the old-style partition table -- not GPT (GUID
Partition Table), the modern one disko uses by default.
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

This creates a "hybrid" MBR: a legacy MBR table squeezed onto the same
disk as the GPT one, listing the FIRMWARE partition (the small FAT32
partition holding the Pi's boot files) as MBR partition 1 so the
bootrom -- which cannot read GPT at all -- can still find it, while
the disk's real, full partition table stays GPT for Linux to read
correctly.

## declareZfsRootDisk + a login-unlocked (PAM) home dataset

`declareZfsRootDisk` sets `boot.zfs.requestEncryptionCredentials =
[ ]` (a plain empty list, not wrapped in `lib.mkDefault` -- see the
merge-behavior note below for why). NixOS's own default (`true`)
recursively scans the whole pool at boot and interactively prompts for
anything still locked -- which is redundant for every dataset this
function creates (their ZFS `keylocation` property -- where ZFS reads
the encryption key/passphrase from -- is always `file://...`, already
handled once by this function's own key-loading script) and actively
wrong for a dataset you want unlocked at LOGIN instead of at boot,
e.g. a per-user home managed by
[`security.pam.zfs`](https://search.nixos.org/options?query=security.pam.zfs)
(PAM: Pluggable Authentication Modules, Linux's login-time
authentication framework -- this module unlocks the dataset as part of
a successful login). Left at `true`, that dataset would ALSO get an
unwanted boot-time password prompt on every boot, on top of the
login-time unlock.

If you add your own dataset with `keylocation=prompt` (ZFS asks
interactively for its key/passphrase) and DO want NixOS's boot-time
passphrase prompt for it, add it as a **plain list**:

```nix
boot.zfs.requestEncryptionCredentials = [ "mypool/mydataset" ];
```

This works because of how NixOS's module system combines settings
from multiple places (this function AND your own host config) into
one final value: a plain list here merges by concatenation with
another plain list, so your plain list and this function's plain `[ ]`
combine automatically into `[ "mypool/mydataset" ]` -- no extra
ceremony needed.

**Do not use `lib.mkDefault [ ... ]` for your own addition here.**
NixOS's module system ranks every setting by a priority number; when
two definitions of the same option have DIFFERENT priorities, only
the higher-priority one survives at all -- lower-priority ones are
discarded outright, not merged. Concatenation (as above) only happens
between definitions at the SAME priority. A plain assignment (what
this function uses) outranks `lib.mkDefault`, so a `lib.mkDefault
[ ... ]` on your side would be silently discarded entirely, with no
error, instead of being combined with this function's list. Use a
plain list, or `lib.mkForce`/`lib.mkAfter` (NixOS's own "force this to
win" / "run this after everything else" markers) if you specifically
need override or ordering control instead of concatenation.

See `declareZfsRootDisk`'s own doc comment (`docs/lib.md`) for the
full reasoning and the manual RECOVERY procedure after a motherboard
swap.


