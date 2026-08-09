{ config, ... }:

# SeaBIOS + GRUB. Only for hosts cloned from the `debian-13` template, which is
# SeaBIOS — a UEFI clone will not boot far enough to SSH into. PXE-provisioned
# hosts want disk-uefi.nix instead; see README.

{
  # disko registers the disk from the EF02 partition; setting
  # boot.loader.grub.devices as well trips a mirroredBoots duplicate assertion.
  boot.loader.grub.enable = true;

  disko.devices.disk.main = {
    device = config.lab.host.disk;
    type = "disk";
    content = {
      type = "gpt";
      partitions = {
        # Somewhere for GRUB to embed core.img on a GPT disk.
        boot = {
          size = "1M";
          type = "EF02";
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
