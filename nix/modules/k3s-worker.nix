{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.lab.k3sWorker;
in
{
  options.lab.k3sWorker = {
    enable = lib.mkEnableOption "k3s agent joined to the lab cluster";

    zone = lib.mkOption {
      type = lib.types.str;
      description = ''
        Proxmox host this VM runs on. proxmox-csi volumes carry a matching
        topology zone, so a node whose label does not match the host it boots
        on cannot mount them.
      '';
    };

    region = lib.mkOption {
      type = lib.types.str;
      default = "lab";
    };

    serverAddr = lib.mkOption {
      type = lib.types.str;
      default = "https://10.0.0.40:6443";
      description = ''
        Server used to *register*; afterwards k3s keeps its own load-balanced
        list of every server and fails over on its own, so this address being
        down only breaks a fresh join, not a restart.

        Servers must point at a peer rather than themselves, so this is
        overridden per control-plane host in a ring.
      '';
    };

    gpu = lib.mkEnableOption "Intel GVT-g vGPU support (needs a hostpci mdev on the VM)";

    server = lib.mkEnableOption ''
      run the control plane (server role, embedded etcd) on this node in
      addition to scheduling workloads.

      Keep exactly one server per PVE host: etcd tolerates losing a minority,
      so two members on one hypervisor means that hypervisor's failure takes
      quorum with it. Also keep the member count odd — a 3-member cluster and
      a 4-member cluster both survive only one loss, so 4 is strictly worse
    '';

    apiVip = lib.mkOption {
      type = lib.types.str;
      default = "10.0.0.5";
      description = ''
        Floating API address published as a TLS SAN on every server. Nothing
        serves it yet; declaring it up front means adding kube-vip later does
        not require reissuing the API certificates.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    sops.secrets."k3s-token" = {
      sopsFile = ../secrets/k3s-cluster.sops.yaml;
      mode = "0400";
      restartUnits = [ "k3s.service" ];
    };

    services.k3s = {
      enable = true;
      package = pkgs.k3s_1_36;
      role = if cfg.server then "server" else "agent";
      inherit (cfg) serverAddr;
      tokenFile = config.sops.secrets."k3s-token".path;
      extraFlags = [
        "--node-ip=${config.lab.host.ipv4}"
        "--node-label=topology.kubernetes.io/region=${cfg.region}"
        "--node-label=topology.kubernetes.io/zone=${cfg.zone}"
        # In-cluster upgraders must skip Nix-managed nodes.
        "--node-label=managed-by=nixos"
      ]
      ++ lib.optionals cfg.server [
        # Cluster-wide server flags must match on every control-plane node.
        "--disable=traefik"
        "--disable=servicelb"
        "--disable=metrics-server"
        "--flannel-backend=wireguard-native"
        "--tls-san=${cfg.apiVip}"
        "--tls-san=${config.lab.host.ipv4}"
        # Reserve capacity for k3s and etcd on nodes that also run workloads.
        "--kubelet-arg=system-reserved=cpu=200m,memory=512Mi"
        "--kubelet-arg=kube-reserved=cpu=200m,memory=512Mi"
      ];
    };

    # k3s auto-applies anything here on a server; agents ignore it.
    services.k3s.manifests = lib.mkIf cfg.server {
      kube-vip.source = ./kube-vip.yaml;
    };

    ## Storage
    boot.kernelModules = [
      "rbd"
      "overlay"
      "br_netfilter"
    ];

    boot.supportedFilesystems.nfs = true;
    services.rpcbind.enable = true;

    # ceph-csi hostPath-mounts /lib/modules, which does not exist on NixOS.
    systemd.tmpfiles.rules = [
      "L+ /lib/modules - - - - /run/current-system/kernel-modules/lib/modules"
    ];

    boot.kernel.sysctl = {
      "fs.inotify.max_user_watches" = 524288;
      "fs.inotify.max_user_instances" = 8192;
    };

    # k3s manages the required iptables chains.
    networking.firewall.enable = false;

    hardware.graphics = lib.mkIf cfg.gpu {
      enable = true;
      extraPackages = with pkgs; [
        intel-media-driver
        intel-compute-runtime
      ];
    };
  };
}
