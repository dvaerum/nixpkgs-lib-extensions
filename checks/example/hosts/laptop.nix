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
  system.stateVersion = "25.05";
}
