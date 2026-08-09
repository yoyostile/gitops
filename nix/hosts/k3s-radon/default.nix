{ ... }:

{
  imports = [
    ../../modules/k3s-worker.nix
    ../../modules/disk-uefi.nix
  ];

  lab.host = {
    ipv4 = "10.0.0.44";
    # Boot disk on virtio0 so every /dev/sd* stays exclusively proxmox-csi's.
    disk = "/dev/vda";
  };

  lab.k3sWorker = {
    enable = true;
    zone = "pve02";
    # AMD host: no GVT-g equivalent exists, so i915 workloads cannot run here.
    # The PVE "Graphics" resource mapping still lists this host — it is wrong.
    gpu = false;
    server = true;
    # Register against a peer, never itself: a server pointing at its own
    # address has nothing to join through on a fresh install.
    serverAddr = "https://10.0.0.40:6443"; # k3s-argon
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
