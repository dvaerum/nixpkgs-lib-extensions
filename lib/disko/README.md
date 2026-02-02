# Intro

Some extra notes about using disko to format diskos.


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


