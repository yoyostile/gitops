{ ... }:

{
  imports = [
    ../../modules/nix-builder.nix
    ../../modules/disk-uefi.nix
  ];

  lab.host = {
    ipv4 = "10.0.0.21";
    disk = "/dev/vda";
  };

  lab.nixBuilder.enable = true;

  boot.initrd.availableKernelModules = [
    "virtio_pci"
    "virtio_blk"
    "virtio_scsi"
    "sd_mod"
  ];

  nixpkgs.hostPlatform = "x86_64-linux";

  system.stateVersion = "26.05";
}
