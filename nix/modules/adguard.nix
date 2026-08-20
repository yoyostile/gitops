{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.lab.adguard;
  ip = config.lab.host.ipv4;

  # Static routes let the health check gate DNS independently of interface setup.
  birdConfig = ''
    log stderr all;
    router id ${ip};

    protocol device {
      scan time 10;
    };

    # BIRD announces only the static routes declared below.
    protocol kernel {
      persist;
      scan time 20;
      ipv4 {
        export none;
        import all;
      };
    };

    protocol kernel {
      persist;
      scan time 20;
      ipv6 {
        export none;
        import all;
      };
    };

    protocol bfd {
      interface "ens*" {
        min rx interval 20 ms;
        min tx interval 50 ms;
        idle tx interval 300 ms;
      };
      multihop {
        interval 200 ms;
        multiplier 10;
      };
    };

    filter announce_route {
      if net ~ 3.3.3.3/32 then accept;
      reject;
    };

    filter announce_ipv6_route {
      if net ~ fc00::53/128 then accept;
      reject;
    };

    protocol bgp cgn_core_01 {
      local as 65123;
      source address ${ip};
      neighbor 172.16.0.1 as 65123;
      bfd on;

      ipv4 {
        next hop self;
        export filter announce_route;
        import none;
      };

      ipv6 {
        export filter announce_ipv6_route;
        import none;
      };
    };

    # Only check-adguard enables these routes, preventing announcements before
    # the resolver is running.
    protocol static anycast4 {
      ipv4;
      disabled;
      route 3.3.3.3/32 via "lo";
    };

    protocol static anycast6 {
      ipv6;
      disabled;
      route fc00::53/128 via "lo";
    };
  '';
in
{
  options.lab.adguard = {
    enable = lib.mkEnableOption "AdGuard Home resolver announcing the lab's anycast DNS address over BGP";

    announce = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether this host announces the anycast DNS prefixes.

        Defaults off so a freshly installed resolver can be validated on its own
        host address while production DNS is untouched. Turning it on is the
        cutover; because anycast tolerates both resolvers announcing at once,
        the old one stays up as the fallback and rollback is
        `birdc disable anycast4 anycast6` — seconds, with no router edit.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # Keep the web UI configuration authoritative and out of the Nix store.
    services.adguardhome = {
      enable = true;
      settings = null;
    };

    services.bird = {
      # This configuration targets BIRD 2 syntax.
      package = pkgs.bird2;
      enable = true;
      config = birdConfig;
    };

    # Tailnet membership provides DNS only; routing stays on tsrouter01.
    sops.secrets."tailscale-authkey" = {
      sopsFile = ../secrets/tailscale.sops.yaml;
      mode = "0400";
    };

    services.tailscale = {
      enable = true;
      authKeyFile = config.sops.secrets."tailscale-authkey".path;
      extraUpFlags = [ "--advertise-tags=tag:server" ];
    };

    # Loopback has no udev event to start its generated address unit.
    systemd.services.network-addresses-lo = {
      wantedBy = [ "multi-user.target" ];
      before = [ "bird.service" ];
    };

    # Local delivery for the announced anycast addresses.
    networking.interfaces.lo = {
      ipv4.addresses = [
        {
          address = "3.3.3.3";
          prefixLength = 32;
        }
      ];
      ipv6.addresses = [
        {
          address = "fc00::53";
          prefixLength = 128;
        }
      ];
    };

    # Keep a resolver available when local AdGuard is down.
    networking.nameservers = lib.mkForce [
      "127.0.0.1"
      "9.9.9.11"
    ];

    # Preserve the fallback when a loopback nameserver is present.
    networking.resolvconf.extraConfig = "resolv_conf_local_only=NO";

    networking.firewall = {
      allowedTCPPorts = [
        22
        53
        80
        179
      ];
      # 3784/4784 are required for BFD.
      allowedUDPPorts = [
        53
        3784
        4784
        41641
      ];
      trustedInterfaces = [ "tailscale0" ];
    };

    # Withdraw DNS routes when AdGuard exits. This checks process liveness, not
    # successful resolution; replace it with a DNS probe if stronger gating is needed.
    systemd.services.check-adguard = lib.mkIf cfg.announce {
      description = "Withdraw the anycast DNS routes while AdGuard Home is down";
      after = [ "bird.service" ];
      serviceConfig.Type = "oneshot";
      script = ''
        if ${pkgs.procps}/bin/pgrep -x AdGuardHome > /dev/null; then
          action=enable
        else
          action=disable
        fi
        # birdc returns non-zero when the protocol is already in the target state.
        ${pkgs.bird2}/bin/birdc "$action" anycast4 > /dev/null || true
        ${pkgs.bird2}/bin/birdc "$action" anycast6 > /dev/null || true
      '';
    };

    systemd.timers.check-adguard = lib.mkIf cfg.announce {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "10s";
        OnUnitActiveSec = "2s";
        AccuracySec = "1us";
      };
    };
  };
}
