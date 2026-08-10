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
      # Remote builds arrive over SSH as root. Root is implicitly trusted, but
      # naming it is what keeps `nix store sign` / `nix copy --to ssh-ng://`
      # working if a future client connects as someone else.
      trusted-users = [
        "root"
        "@wheel"
      ];

      # common.nix caps the fleet at max-jobs = 2 because the service guests are
      # 1 vCPU and a parallel nixos-rebuild OOMs them. This host exists to build,
      # so both settings are forced back up.
      max-jobs = lib.mkForce cfg.maxJobs;
      inherit (cfg) cores;

      # Keep the inputs of what has been built. Without this a GC pass strips
      # the build-time dependencies of every closure and the next near-identical
      # rebuild re-downloads or re-derives them, which is exactly the work this
      # host exists to avoid.
      keep-outputs = true;
      keep-derivations = true;

      # Space-pressure GC replaces the time-based sweep below. On a cache the
      # eviction trigger has to be disk, not age.
      min-free = lib.mkForce (20 * 1024 * 1024 * 1024);
      max-free = lib.mkForce (60 * 1024 * 1024 * 1024);
    };

    # `nix-collect-garbage --delete-older-than 14d` does a full GC, and nothing
    # roots the closures built here for other hosts — nixos-rebuild --build-host
    # copies them away and leaves no gcroot behind. Left enabled, the weekly
    # timer would empty the cache every Monday and the host would serve only
    # whatever is currently in flight. min-free/max-free above evicts instead,
    # and it only ever runs during a build, which is also the only thing that
    # fills the store.
    nix.gc.automatic = lib.mkForce false;

    # Harmonia signs the narinfo it serves; the store itself holds unsigned
    # locally-built paths. So this key is the only thing that makes the cache
    # usable by a client that does not trust it blindly, and the matching public
    # key must be in every client's trusted-public-keys.
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
        # Lower number wins. cache.nixos.org is 40, harmonia's own default is
        # 50 — leaving it there would send clients over the WAN for anything
        # upstream also has, which defeats the point of a LAN cache.
        priority = 30;
      };
    };

    # The build host has no swap partition (disk-uefi.nix lays out ESP + root
    # only) and 8 GB is thin for a linker that spikes. Swap turns "the whole
    # rebuild died" into "that derivation was slow".
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
