{ ... }:

{
  imports = [
    ../../modules/k3s-worker.nix
    ../../modules/disk-uefi.nix
  ];

  lab.host = {
    ipv4 = "10.0.0.43";
    disk = "/dev/vda";
  };

  lab.k3sWorker = {
    enable = true;
    zone = "pve03";
    gpu = true;
    server = true;
    serverAddr = "https://10.0.0.44:6443"; # k3s-radon
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
