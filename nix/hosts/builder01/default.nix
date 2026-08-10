{ ... }:

{
  imports = [
    ../../modules/nix-builder.nix
    ../../modules/disk-uefi.nix
  ];

  lab.host = {
    # .20 through .36 were the free-looking candidates; .29 answers ping and .36
    # is netboot01's old address still in the router's ARP cache. .21 had no
    # lease, no ARP entry and no reply. It sits inside pool[lab]
    # (10.0.0.10-10.0.0.199), like every other static host here, so it is held
    # by a DHCP reservation on the MikroTik rather than by being outside the pool.
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
