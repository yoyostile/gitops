{ ... }:

{
  imports = [
    ../../modules/adguard.nix
    ../../modules/disk-uefi.nix
  ];

  lab.host = {
    # The dormant adguard2 (VM 111) held this address, so the router already has
    # it in the dns_server address-list and an enabled bgp-adguard2 connection.
    # Taking the slot means the cutover needs no router preparation at all.
    ipv4 = "10.0.0.9";
    disk = "/dev/vda";
  };

  lab.adguard = {
    enable = true;
    # Joined the anycast announcement 2026-08-10, after validating resolution,
    # rewrites and split-horizon forwarding on 10.0.0.9 directly. The old box
    # was withdrawn the same day and now announces only 100.64.0.0/10; its
    # AdGuard is left running as the rollback path.
    announce = true;
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
