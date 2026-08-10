{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.lab.tailscaleRouter;
  ip = config.lab.host.ipv4;

  # 100.64.0.0/10 is announced into the lab over BGP so LAN clients can reach
  # tailnet peers without being on the tailnet themselves. The protocol must be
  # named `tailscale`: tailscaled enables and disables a BIRD protocol of that
  # exact name over --bird-socket, which is what withdraws the route by itself
  # when the daemon stops or loses its routes. Renaming it silently breaks the
  # gating and leaves a black-hole route announced.
  birdConfig = ''
    log stderr all;
    router id ${ip};

    protocol device {
      scan time 10;
    };

    protocol kernel {
      persist;
      scan time 20;
      ipv4 {
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
      if net ~ 100.64.0.0/10 then accept;
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
    };

    protocol static tailscale {
      ipv4;
      route 100.64.0.0/10 via "tailscale0";
    };
  '';
in
{
  options.lab.tailscaleRouter = {
    enable = lib.mkEnableOption "tailscale subnet router and exit node for the lab";

    advertiseRoutes = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "10.0.0.0/8"
        "172.16.0.0/12"
      ];
      description = ''
        Subnets advertised to the tailnet. These auto-approve via the
        autoApprovers.routes entry for tag:server in cloud-tf; the exit-node
        routes (0.0.0.0/0, ::/0) come from --advertise-exit-node instead and are
        approved by the separate exitNode entry for tag:router.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # This host carries the routing role alone, deliberately kept off the
    # resolvers: on the old Debian box both lived together behind one BGP
    # session, so an AdGuard failure withdrew LAN-to-tailnet routing too.
    sops.secrets."tailscale-router-authkey" = {
      sopsFile = ../secrets/tailscale-router.sops.yaml;
      mode = "0400";
    };

    services.tailscale = {
      enable = true;
      # Sets the ip_forward sysctls; without them the node advertises routes it
      # cannot actually forward.
      useRoutingFeatures = "server";
      authKeyFile = config.sops.secrets."tailscale-router-authkey".path;
      extraUpFlags = [
        "--advertise-tags=tag:server,tag:router"
        "--advertise-routes=${lib.concatStringsSep "," cfg.advertiseRoutes}"
        "--advertise-exit-node"
      ];
      # NixOS's RuntimeDirectory puts the control socket here, which is the same
      # path /var/run/bird/bird.ctl resolved to on the Debian box.
      extraDaemonFlags = [ "--bird-socket=/run/bird/bird.ctl" ];
    };

    services.bird = {
      enable = true;
      package = pkgs.bird2;
      config = birdConfig;
    };

    networking.firewall = {
      allowedTCPPorts = [
        22
        179
      ];
      # 3784/4784 are BFD, 41641 is tailscale's direct UDP port. Omitting the
      # BFD ports gives the silent failure the README documents: the session
      # reaches Established and then resets every few seconds, forever.
      allowedUDPPorts = [
        3784
        4784
        41641
      ];
      trustedInterfaces = [ "tailscale0" ];
    };
  };
}
