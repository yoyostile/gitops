{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.lab.adguard;
  ip = config.lab.host.ipv4;

  # Announcing from a static protocol rather than `protocol kernel { learn; }`
  # is the one deliberate departure from the Debian config. There, the address
  # on lo only produced a route in the `local` table, and an `ip route add ...
  # dev lo:1` line in /etc/network/interfaces put a copy in `main` purely so
  # BIRD could learn it — an implicit dependency between interface scripts and
  # the BGP export that nothing named. Declaring the route here makes the
  # announcement independent of how the address got onto the interface, and it
  # is what lets the health check gate DNS alone (below).
  birdConfig = ''
    log stderr all;
    router id ${ip};

    protocol device {
      scan time 10;
    };

    # export none / no learn: BIRD neither installs nor picks up kernel routes.
    # Everything it announces is declared below.
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

    # The lab's anycast DNS address. Both resolvers announce it at once; the
    # router picks one best path, so a cutover is an overlap rather than a swap
    # and rollback is `birdc disable anycast4 anycast6`.
    #
    # Always disabled in the config: check-adguard is the only thing that ever
    # enables these, so the prefix is never announced before AdGuard has been
    # observed running. Starting them enabled would announce for the ~10s until
    # the first health check, black-holing DNS if AdGuard is slow to come up.
    # The cost is that a bird reload withdraws them for up to 2s until the timer
    # re-enables — a brief withdrawal is the safe direction.
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
    # settings = null means Nix supplies no AdGuard configuration whatsoever and
    # the web UI stays the source of truth, exactly as on the Debian box. The
    # hand-tuned user_rules and rewrites therefore migrate byte-identically, and
    # the admin bcrypt hash never has to enter Git — the tailnet auth key below
    # is this host's only secret.
    #
    # Note the module only injects http.address on the `settings != null` branch,
    # so `host`/`port` here would be silently ignored: the listen addresses come
    # from the migrated AdGuardHome.yaml.
    services.adguardhome = {
      enable = true;
      settings = null;
    };

    services.bird = {
      # services.bird2 was removed in 26.05 and services.bird now defaults to
      # bird3. Pinning 2.x keeps the config semantics the Debian box was running
      # under; moving to bird3 is a separate change with its own validation.
      package = pkgs.bird2;
      enable = true;
      config = birdConfig;
    };

    # A resolver joins the tailnet purely so tailnet clients can use it as a DNS
    # server — its tailnet address goes in cloud-tf's `dns_servers`, which drives
    # both the tailnet DNS configuration and the ACL that opens :53 to members.
    # It is deliberately NOT a subnet router or exit node: that role lives on its
    # own host, so there are no routing features, no advertised routes, and no
    # --bird-socket integration here. Carrying them would recreate the coupling
    # this module exists to remove, where losing DNS also drops LAN-to-tailnet
    # routing.
    #
    # Being on the tailnet is also what makes the migrated config's
    # `[/ts.net/]100.100.100.100` upstream and the MagicDNS PTR resolver work;
    # without it those upstreams are simply unreachable.

    # Reusable, pre-authorized, tag:server — minted by cloud-tf, so a second
    # resolver joins with no manual step. The key only authorises the initial
    # join; afterwards the node has its own key in tailscaled.state, so rotating
    # or expiring this secret never disturbs a host that is already on the
    # tailnet.
    sops.secrets."tailscale-authkey" = {
      sopsFile = ../secrets/tailscale.sops.yaml;
      mode = "0400";
    };

    services.tailscale = {
      enable = true;
      authKeyFile = config.sops.secrets."tailscale-authkey".path;
      extraUpFlags = [ "--advertise-tags=tag:server" ];
    };

    # NixOS generates network-addresses-lo.service from the declaration below,
    # and then never starts it: scripted-networking address units are pulled in
    # by each interface's udev device unit, and loopback has none, so the
    # generated unit carries only PartOf= — which stops a unit but never starts
    # one. The failure is silent and total: the addresses are simply absent, and
    # the host drops every DNS packet the router steers to the anycast address.
    # network-setup.service and network-online.target are both inactive on these
    # hosts, so multi-user.target is the only dependable hook. Ordered before
    # bird so local delivery exists before anything can be announced.
    systemd.services.network-addresses-lo = {
      wantedBy = [ "multi-user.target" ];
      before = [ "bird.service" ];
    };

    # Local delivery for the anycast addresses. The BGP announcement does not
    # depend on these being here (see birdConfig), but without them the packets
    # the router steers here have nowhere to land.
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

    # common.nix points every host at 3.3.3.3, which on this host resolves to
    # itself — and fails, because the reply's source address becomes 3.3.3.3,
    # which is not in AdGuard's allowed_clients. The second entry matters most
    # when AdGuard is down, which is exactly when you are trying to rebuild to
    # fix it.
    networking.nameservers = lib.mkForce [
      "127.0.0.1"
      "9.9.9.11"
    ];

    # Without this the fallback above is silently thrown away. openresolv
    # defaults resolv_conf_local_only to yes: when any loopback nameserver is
    # listed it writes ONLY that one to /etc/resolv.conf and drops the rest.
    # `resolvconf -l` still shows both, which makes it look configured while the
    # host in fact has no resolver at all whenever AdGuard is down — the exact
    # moment you need DNS to rebuild the machine.
    networking.resolvconf.extraConfig = "resolv_conf_local_only=NO";

    networking.firewall = {
      allowedTCPPorts = [
        22
        53
        80
        179
      ];
      # 3784/4784 are BFD. The session comes up without them and then resets
      # every few seconds forever — the same silent failure the README documents
      # for k3s nodes missing the bgp-peers address-list.
      allowedUDPPorts = [
        53
        3784
        4784
        41641
      ];
      trustedInterfaces = [ "tailscale0" ];
    };

    # Gate the announcement on AdGuard being alive, so a dead resolver withdraws
    # the route instead of black-holing every client on every VLAN.
    #
    # Two known weaknesses, both carried over knowingly: pgrep proves only that
    # the process exists, so a hung or SERVFAILing AdGuard keeps the route; and
    # a 2s oneshot is a lot of unit churn for a liveness probe. A dig-based
    # probe would be strictly better and is the obvious follow-up.
    #
    # Unlike the Debian original this disables the two anycast protocols rather
    # than the whole BGP session, so an AdGuard crash no longer also withdraws
    # 100.64.0.0/10 and takes LAN-to-tailnet routing down with it.
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
        # birdc reports "already enabled/disabled" as an error; without this the
        # unit fails every 2 seconds in steady state.
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
