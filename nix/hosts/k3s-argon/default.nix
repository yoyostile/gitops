{ ... }:

{
  imports = [
    ../../modules/k3s-worker.nix
    ../../modules/disk-uefi.nix
  ];

  lab.host = {
    ipv4 = "10.0.0.40";
    # Boot disk on virtio0 so every /dev/sd* stays exclusively proxmox-csi's.
    disk = "/dev/vda";
  };

  lab.k3sWorker = {
    enable = true;
    # Must equal the PVE host this VM runs on: proxmox-csi pins volumes to the
    # zone, so a node whose zone does not match cannot mount them.
    zone = "pve01";
    gpu = true;
    server = true;
    # Register against a peer, never itself: a server pointing at its own
    # address has nothing to join through on a fresh install.
    serverAddr = "https://10.0.0.43:6443"; # k3s-krypton
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
