{
  config,
  lib,
  ...
}:

let
  cfg = config.lab.nixBuilder;
in
{
  options.lab.nixBuilder = {
    enable = lib.mkEnableOption "Nix remote builder and binary cache for the lab";

    port = lib.mkOption {
      type = lib.types.port;
      default = 5000;
      description = ''
        Harmonia's listen port. Also the port every other host has in its
        substituter URL (modules/common.nix), so changing it here is only half
        the change.
      '';
    };

    maxJobs = lib.mkOption {
      type = lib.types.int;
      default = 4;
      description = ''
        Derivations built in parallel. maxJobs * cores is deliberately equal to
        the vCPU count rather than oversubscribed: RAM is the binding constraint
        on a build host, not CPU, and an OOM kill mid-build loses the whole
        nixos-rebuild rather than degrading it.
      '';
    };

    cores = lib.mkOption {
      type = lib.types.int;
      default = 4;
      description = "Cores offered to each individual derivation (make -j).";
    };
  };

  config = lib.mkIf cfg.enable {
    nix.settings = {
      # Permit remote builds and store operations over SSH.
      trusted-users = [
        "root"
        "@wheel"
      ];

      # Override the conservative fleet default on the dedicated builder.
      max-jobs = lib.mkForce cfg.maxJobs;
      inherit (cfg) cores;

      # Retain build inputs for incremental rebuilds.
      keep-outputs = true;
      keep-derivations = true;

      # Evict by disk pressure rather than age.
      min-free = lib.mkForce (20 * 1024 * 1024 * 1024);
      max-free = lib.mkForce (60 * 1024 * 1024 * 1024);
    };

    # Remote build outputs have no gcroot, so time-based GC would empty the cache.
    nix.gc.automatic = lib.mkForce false;

    # Clients trust the matching public key from common.nix.
    sops.secrets."harmonia-signing-key" = {
      sopsFile = ../secrets/nix-builder.sops.yaml;
      mode = "0400";
      restartUnits = [ "harmonia.service" ];
    };

    services.harmonia.cache = {
      enable = true;
      signKeyPaths = [ config.sops.secrets."harmonia-signing-key".path ];
      settings = {
        bind = "[::]:${toString cfg.port}";
        # Lower than cache.nixos.org (40), so LAN hits win.
        priority = 30;
      };
    };

    # Absorb linker memory spikes without a dedicated swap partition.
    swapDevices = [
      {
        device = "/var/lib/swapfile";
        size = 8192;
      }
    ];

    networking.firewall.allowedTCPPorts = [
      22
      cfg.port
    ];
  };
}
