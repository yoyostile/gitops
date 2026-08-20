{ ... }:

{
  imports = [
    ../../modules/k3s-worker.nix
    ../../modules/disk-uefi.nix
  ];

  lab.host = {
    ipv4 = "10.0.0.42";
    disk = "/dev/vda";
  };

  lab.k3sWorker = {
    enable = true;
    zone = "pve03";
    gpu = true;
  };

  boot.initrd.availableKernelModules = [
    "virtio_pci"
    "virtio_blk"
    "virtio_scsi"
    "sd_mod"
  ];

  nixpkgs.hostPlatform = "x86_64-linux";

  system.stateVersion = "26.05";
}
