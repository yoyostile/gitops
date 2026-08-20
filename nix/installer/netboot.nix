{ lib, modulesPath, ... }:

{
  imports = [ "${modulesPath}/installer/netboot/netboot-minimal.nix" ];

  nixpkgs.hostPlatform = "x86_64-linux";

  # Bake remote access into the initrd for unattended installation.
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGA6mJ5U3GlaON6hlpA5lz9BStGoZfV1W7EiIfYHBvw7"
  ];

  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "prohibit-password";
      PasswordAuthentication = false;
    };
  };
  # The installation-device profile leaves sshd socket-activated only.
  systemd.services.sshd.wantedBy = lib.mkForce [ "multi-user.target" ];

  boot.kernelParams = [
    "console=tty0"
    "console=ttyS0,115200"
  ];

  # No networking.useDHCP here: the installer profile brings NetworkManager,
  # which owns DHCP and sets useDHCP = false. Setting it conflicts.

  system.stateVersion = "26.05";
}
