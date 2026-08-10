{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.lab.netboot;
  stateDir = "/var/lib/netbootxyz";
in
{
  options.lab.netboot = {
    enable = lib.mkEnableOption "netboot.xyz PXE appliance";

    bootMenu = lib.mkOption {
      type = lib.types.path;
      default = ./netbootxyz-boot.cfg;
      description = ''
        The iPXE script served over TFTP as boot.cfg. Declared rather than
        hand-edited because the appliance keeps a second, identical-looking copy
        at config/menus/local/boot.cfg that is NOT served: editing that one looks
        correct and does nothing, and the symptom is a client that PXE-boots,
        takes a DHCP lease and then drops to the UEFI boot manager.

        Gate an unattended install on the target's MAC by adding a line here:
          iseq ''${net0/mac} bc:24:11:xx:xx:xx && chain http://.../netboot.ipxe ||
        and remove it once installed — a rule left behind reimages any host that
        falls through to network boot.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # The same upstream image the Debian box ran, so the full netboot.xyz
    # catalogue (Debian, Windows, memtest, …) is unchanged — only the host
    # around it becomes declarative.
    virtualisation.oci-containers = {
      backend = "docker";
      containers.netbootxyz = {
        image = "ghcr.io/netbootxyz/netbootxyz";
        environment = {
          NGINX_PORT = "80";
          WEB_APP_PORT = "3000";
        };
        volumes = [
          "${stateDir}/config:/config"
          "${stateDir}/assets:/assets"
        ];
        ports = [
          "80:80"
          "3000:3000"
          "69:69/udp"
        ];
      };
    };

    # config/ and assets/ stay mutable state on purpose: the appliance ships its
    # own menus/*.ipxe and replaces them on update, and assets/ holds large
    # downloaded images. Only boot.cfg is asserted from the flake.
    systemd.tmpfiles.rules = [
      "d ${stateDir} 0755 1000 1000 -"
      "d ${stateDir}/config 0755 1000 1000 -"
      "d ${stateDir}/config/menus 0755 1000 1000 -"
      "d ${stateDir}/assets 0755 1000 1000 -"
    ];

    # dnsmasq inside the container runs with --tftp-secure and serves only files
    # owned by its own uid (1000). A /nix/store symlink is root-owned and would
    # silently stop being served, so the menu is installed as a real file with
    # that ownership instead. Re-asserted on every activation, which is the
    # point: a hand-edit on the box reverts at the next rebuild.
    # Ordered AFTER the container, not before: on a fresh /config the appliance
    # seeds its own stock menus on first start and would overwrite anything
    # written ahead of it — leaving the default netboot.xyz menu in place and no
    # sign that the declared one was ever applied.
    systemd.services.netbootxyz-boot-menu = {
      description = "Install the declared netboot.xyz boot menu";
      wantedBy = [ "multi-user.target" ];
      after = [ "docker-netbootxyz.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        install -D -o 1000 -g 1000 -m 0644 \
          ${cfg.bootMenu} ${stateDir}/config/menus/boot.cfg
      '';
    };

    networking.firewall = {
      allowedTCPPorts = [
        80 # nginx: assets and installer images
        3000 # netboot.xyz web UI
      ];
      allowedUDPPorts = [
        69 # TFTP: how the menus are served. Not HTTP — curling them 404s.
      ];
    };
  };
}
