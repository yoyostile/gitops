{ config, ... }:

# UEFI + systemd-boot. Use this for anything provisioned over PXE: DHCP serves
# `netboot.xyz.efi` unconditionally (there is no option-93 arch matcher), so a
# SeaBIOS guest cannot netboot at all.
#
# Partitioning and bootloader live together on purpose — an ESP with GRUB, or a
# BIOS boot partition with systemd-boot, are both silently unbootable.

{
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  disko.devices.disk.main = {
    device = config.lab.host.disk;
    type = "disk";
    content = {
      type = "gpt";
      partitions = {
        ESP = {
          size = "512M";
          type = "EF00";
          content = {
            type = "filesystem";
            format = "vfat";
            mountpoint = "/boot";
            mountOptions = [ "umask=0077" ];
          };
        };
        root = {
          size = "100%";
          content = {
            type = "filesystem";
            format = "ext4";
            mountpoint = "/";
          };
        };
      };
    };
  };
}
