{ ... }:

{
  imports = [
    ../../modules/netboot.nix
    ../../modules/disk-uefi.nix
  ];

  lab.host = {
    # The MikroTik DHCP scope hardcodes next-server=10.0.0.35, so holding that
    # address is what makes this host the PXE server for every client without a
    # router change — and keeps the chain URLs in boot.cfg and the README valid.
    # It was installed on a temporary address while the Debian appliance still
    # held this one; the old box PXE-booted its own replacement.
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
