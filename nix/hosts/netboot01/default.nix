{ ... }:

{
  imports = [
    ../../modules/netboot.nix
    ../../modules/disk-uefi.nix
  ];

  lab.host = {
    # Must match the MikroTik DHCP next-server address.
    ipv4 = "10.0.0.35";
    disk = "/dev/vda";
  };

  lab.netboot.enable = true;

  boot.initrd.availableKernelModules = [
    "virtio_pci"
    "virtio_blk"
    "virtio_scsi"
    "sd_mod"
  ];

  nixpkgs.hostPlatform = "x86_64-linux";

  system.stateVersion = "26.05";
}
