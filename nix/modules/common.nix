{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.lab.host;
  sshKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGA6mJ5U3GlaON6hlpA5lz9BStGoZfV1W7EiIfYHBvw7";
in
{
  options.lab = {
    domain = lib.mkOption {
      type = lib.types.str;
      default = "lab.r4r3.me";
      description = ''
        Internal DNS domain, used for networking.domain and the resolver search
        path. Flakes evaluate only git-tracked files, so a value needed at
        eval time cannot be kept out of the repo.
      '';
    };

    host = {
      ipv4 = lib.mkOption {
        type = lib.types.str;
        description = ''
          Static IPv4 address of this host. Also consumed by class modules that
          need it (k3s passes it as --node-ip), so it is declared once here
          rather than per class.
        '';
      };

      prefixLength = lib.mkOption {
        type = lib.types.int;
        default = 24;
      };

      interface = lib.mkOption {
        type = lib.types.str;
        default = "ens18";
        description = "Proxmox virtio NIC name inside the guest.";
      };

      disk = lib.mkOption {
        type = lib.types.str;
        default = "/dev/vda";
        description = ''
          Root device, consumed by the disk-uefi / disk-bios modules. virtio0 in
          the VM config appears as /dev/vda; proxmox-csi attaches PVCs as scsi1+
          (/dev/sd*), which disko must never touch.
        '';
      };
    };
  };

  config = {
    ## Access
    services.openssh = {
      enable = true;
      settings = {
        PasswordAuthentication = false;
        PermitRootLogin = "prohibit-password";
      };
    };

    users.users.yoyostile = {
      isNormalUser = true;
      extraGroups = [ "wheel" ];
      openssh.authorizedKeys.keys = [ sshKey ];
    };
    users.users.root.openssh.authorizedKeys.keys = [ sshKey ];
    security.sudo.wheelNeedsPassword = false;

    ## Secrets. The age identity is derived from this host's SSH host key, so
    ## there is no separate key to distribute — but a freshly installed host has
    ## a key nothing is encrypted to yet. See README, "adding a host".
    sops.age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];

    ## Network. The address is per-host; everything else is fleet-wide.
    networking = {
      useDHCP = false;
      interfaces.${cfg.interface}.ipv4.addresses = [
        {
          address = cfg.ipv4;
          inherit (cfg) prefixLength;
        }
      ];
      defaultGateway = "10.0.0.1";
      nameservers = [ "3.3.3.3" ];
      domain = config.lab.domain;
      search = [ config.lab.domain ];
      # SLAAC privacy addresses rotate, which drifted the k3s master's etcd peer
      # URL across reboots and is why --node-ip had to be pinned there by hand.
      tempAddresses = "disabled";
      firewall.enable = lib.mkDefault true;
    };

    ## Proxmox guest
    services.qemuGuest.enable = true;
    boot.kernelParams = [
      "console=tty0"
      "console=ttyS0,115200"
    ];

    ## Nix
    nix.settings = {
      experimental-features = [
        "nix-command"
        "flakes"
      ];
      # Time-based GC alone does not save a small root disk when every deploy
      # adds a generation; this collects on space pressure instead.
      min-free = 1024 * 1024 * 1024;
      max-free = 8 * 1024 * 1024 * 1024;
      auto-optimise-store = true;
      # These guests are small and nixos-rebuild is the peak memory consumer on
      # them; unbounded parallelism OOMs the switch rather than failing cleanly.
      max-jobs = 2;

      # builder01's harmonia cache. Both of these are list options that NixOS
      # already defines, and list definitions merge, so these append to
      # cache.nixos.org rather than replacing it — repeating upstream here would
      # only duplicate the entry.
      #
      # List order does not decide who is asked first; the `Priority` each cache
      # reports in /nix-cache-info does. harmonia is pinned to 30 against
      # upstream's 40 in modules/nix-builder.nix, which is what keeps a hit on
      # the LAN from being fetched over the WAN instead.
      #
      # The literal IP is deliberate. A hostname would put AdGuard on the path
      # of every nixos-rebuild, including the rebuild you run to fix AdGuard.
      # An unreachable substituter is only a warning — a host still falls
      # through to upstream when builder01 is down.
      substituters = [ "http://10.0.0.21:5000" ];
      trusted-public-keys = [
        "builder01.lab.r4r3.me-1:fC6JEnF1nZ+Zi6/5mjdxkrVUiYZinipGCZ9HssOeb2M="
      ];
    };

    nix.gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 14d";
    };

    time.timeZone = "Europe/Berlin";

    environment.systemPackages = with pkgs; [
      git
      htop
      vim
    ];
  };
}
