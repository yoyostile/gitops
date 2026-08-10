{ ... }:

{
  imports = [
    ../../modules/adguard.nix
    ../../modules/disk-uefi.nix
  ];

  lab.host = {
    # Reuses the address the retired Debian adguard held, so the router needed
    # no preparation: bgp-adguard, the bgp-peers entry (which gates BFD) and the
    # dns_server entry all already pointed here.
    ipv4 = "10.0.0.8";
    disk = "/dev/vda";
  };

  lab.adguard = {
    enable = true;
    # Keep this off on a freshly installed resolver until its AdGuard config is
    # restored: a fresh AdGuard comes up in its setup wizard serving nothing on
    # :53, and the health check only greps for the process, so announcing would
    # black-hole every client the router steered here. Enabled 2026-08-10 after
    # verifying resolution on 10.0.0.8 directly. Second anycast resolver: with
    # both announcing 3.3.3.3, losing either is a withdrawal rather than an
    # outage — the redundancy that replaces Proxmox HA for these hosts.
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
