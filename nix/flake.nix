{
  description = "NixOS hosts for the lab";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      nixpkgs,
      disko,
      sops-nix,
      ...
    }:
    let
      inherit (nixpkgs) lib;

      # Every directory under hosts/ is a host. Adding one is `mkdir` plus a
      # default.nix — the flake needs no edit.
      hostNames = lib.attrNames (
        lib.filterAttrs (_: type: type == "directory") (builtins.readDir ./hosts)
      );

      mkHost =
        name:
        lib.nixosSystem {
          modules = [
            disko.nixosModules.disko
            sops-nix.nixosModules.sops
            ./modules/common.nix
            ./hosts/${name}
            { networking.hostName = name; }
          ];
        };
      # PXE installer image. Built for x86_64-linux, so it needs a remote
      # builder when driven from the Mac — see README, "netboot image".
      netbootSystem = lib.nixosSystem { modules = [ ./installer/netboot.nix ]; };
      pkgs = nixpkgs.legacyPackages.x86_64-linux;
    in
    {
      nixosConfigurations = lib.genAttrs hostNames mkHost;

      packages.x86_64-linux.netbootInstaller =
        pkgs.runCommand "netboot-installer" { }
          ''
            mkdir -p $out
            cp ${netbootSystem.config.system.build.kernel}/bzImage $out/
            cp ${netbootSystem.config.system.build.netbootRamdisk}/initrd $out/
            cp ${netbootSystem.config.system.build.netbootIpxeScript}/netboot.ipxe $out/
          '';
    };
}
