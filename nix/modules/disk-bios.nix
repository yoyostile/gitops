{ config, ... }:

# SeaBIOS + GRUB for hosts cloned from the Debian template.

{
  # disko registers the GRUB device from the EF02 partition.
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
