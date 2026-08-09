{ ... }:

{
  imports = [
    ../../modules/k3s-worker.nix
    ../../modules/disk-uefi.nix
  ];

  lab.host = {
    ipv4 = "10.0.0.42";
    # Boot disk on virtio0 so every /dev/sd* stays exclusively proxmox-csi's.
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

  # Records the install-time release. Never bump this to match the running
  # nixpkgs — moving it forward is the dangerous direction.
  system.stateVersion = "26.05";
}
