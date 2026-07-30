# PLACEHOLDER host configuration (also asserted by this repo's checks).
# For a real machine, replace the contents with your actual config:
# import the machine's hardware-configuration.nix and enable a boot
# loader (e.g. boot.loader.systemd-boot.enable = true).
{ ... }:
{
  fileSystems."/" = {
    device = "/dev/sda1";
    fsType = "ext4";
  };
  boot.loader.grub.enable = false;
  # The release this host was FIRST installed with -- not the release you
  # are on now. Set it once, then leave it alone.
  system.stateVersion = "26.11";
}
