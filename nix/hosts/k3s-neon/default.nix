{ ... }:

{
  imports = [
    ../../modules/k3s-worker.nix
    ../../modules/disk-uefi.nix
  ];

  lab.host = {
    ipv4 = "10.0.0.41";
    # Boot disk on virtio0 so every /dev/sd* stays exclusively proxmox-csi's.
    disk = "/dev/vda";
  };

  lab.k3sWorker = {
    enable = true;
    # Two nodes share a zone deliberately: proxmox-csi pins volumes to the PVE
    # host, so a volume here has nowhere to go while its only node is drained.
    zone = "pve01";
    # This iGPU exposes two GVT-g instances, so both nodes on the host can hold
    # one and i915 workloads survive either being drained.
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
