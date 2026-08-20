# NixOS hosts

Declarative configuration for the lab's NixOS VMs. Flux does not reconcile this
directory; all Flux Kustomizations point into `cluster/`.

Commands below run from the repository root unless noted otherwise.

## Layout

```text
nix/flake.nix                 host auto-discovery and package outputs
nix/hosts/<name>/default.nix  per-host address, role, disk, and state version
nix/modules/common.nix        SSH, networking, sops, Nix, and PVE guest defaults
nix/modules/disk-{uefi,bios}.nix
nix/modules/k3s-worker.nix    optional k3s agent/server role
nix/modules/nix-builder.nix   builder01 and Harmonia cache
nix/modules/netboot.nix       netboot01 appliance
nix/installer/netboot.nix     PXE installer image
nix/secrets/                  sops-encrypted host secrets
```

Every directory under `nix/hosts/` automatically becomes a flake configuration.
Role modules are opt-in; ordinary service VMs receive only `common.nix` plus their
host module. The firewall defaults on and the k3s role turns it off.

## Routine deploy

`builder01` is normally off. Start it once, deploy as many hosts as needed, then
shut it down:

```bash
ssh root@10.0.0.3 'qm start 111'

nixos-rebuild switch --flake ./nix#<name> \
  --target-host root@<ip> --build-host root@10.0.0.21

ssh root@10.0.0.3 'qm shutdown 111'
```

Use `--build-host`: macOS cannot build these `x86_64-linux` systems, and the small
service VMs cannot reliably build their own closures. Drain a k3s node before a
switch that restarts `k3s.service`.

Rollback with `nixos-rebuild --rollback` or select an older generation at boot.

## Add or reinstall a host

Hosts use their ed25519 SSH host key as their sops age identity. Generate and
register that key _before_ installation so the first activation can decrypt its
secrets:

1. Add `nix/hosts/<name>/default.nix`. Set `lab.host.ipv4`, enable its roles,
   import `disk-uefi.nix` (normally) or `disk-bios.nix`, and set
   `system.stateVersion`.
2. Generate the host key in a dedicated staging tree:

   ```bash
   mkdir -p /tmp/<name>-stage/etc/ssh
   ssh-keygen -t ed25519 -N '' \
     -f /tmp/<name>-stage/etc/ssh/ssh_host_ed25519_key
   ssh-to-age < /tmp/<name>-stage/etc/ssh/ssh_host_ed25519_key.pub
   ```

3. Add the age recipient to the `nix/secrets/.*` rule in `.sops.yaml`, then update
   every secret the host needs, for example:

   ```bash
   sops updatekeys nix/secrets/k3s-cluster.sops.yaml
   ```

4. Create and boot the VM, then install while staging the key:

   ```bash
   nixos-anywhere --flake ./nix#<name> --build-on remote \
     --extra-files /tmp/<name>-stage --target-host root@<installer-ip>
   ```

5. Confirm `/etc/ssh/ssh_host_ed25519_key` is mode `0600`, then securely delete
   the staging tree. It contains the host's private key.

To verify the installed identity:

```bash
ssh root@<host> 'cat /etc/ssh/ssh_host_ed25519_key.pub' | ssh-to-age
grep -oE 'age1[a-z0-9]{20,}' nix/secrets/<secret>.sops.yaml | sort -u
```

Never put unrelated credentials in the staging tree: `--extra-files` copies the
entire tree into `/`.

### Proxmox VM baseline

```text
--bios ovmf --efidisk0 local-lvm:1,efitype=4m,pre-enrolled-keys=0
--machine q35 --cpu host --numa 0 --balloon 0
--scsihw virtio-scsi-single
--virtio0 local-lvm:<size>,discard=on,iothread=1
--net0 virtio,bridge=vmbr0,firewall=1,tag=1000
--agent enabled=1,fstrim_cloned_disks=1
--serial0 socket --rng0 source=/dev/urandom
--ostype l26 --onboot 1 --boot order=virtio0;net0
```

Important constraints:

- PXE requires OVMF/UEFI in this lab.
- Keep the root disk on `virtio0` (`/dev/vda`); proxmox-csi volumes use `scsi1+`
  (`/dev/sd*`). `lab.host.disk` must match.
- Disable ballooning; kubelet cannot account for memory reclaimed underneath it.
- Keep disk first and network second. An empty disk falls through to PXE and an
  installed disk boots normally.
- Redundant service twins use `local-lvm` without HA. Single-instance services
  such as `netboot01` and `tsrouter01` use Ceph and Proxmox HA.

### PXE install

Add a temporary MAC rule at the top of `nix/modules/netbootxyz-boot.cfg`, rebuild
`netboot01`, and start the new VM:

```text
iseq ${net0/mac} bc:24:11:xx:xx:xx && chain http://10.0.0.35/nixos-installer/netboot.ipxe ||
```

After installation, **remove the rule and rebuild netboot01**. Leaving it in place
can turn a recoverable boot failure into an unattended disk wipe and SSH-key change.

The Debian 13 template (VM 108 on pve02) is a fallback when PXE is unavailable.
Resize its disk before running nixos-anywhere because disko consumes the full device.

## k3s control plane

Set `lab.k3sWorker.server = true` for an embedded-etcd server that also schedules
workloads.

- Keep an odd number of servers and place at most one on each PVE host.
- Replace a server by adding the new member before removing the old one.
- All servers must use the same cluster-wide k3s flags.
- `serverAddr` is only the registration endpoint; joined servers discover peers.
- The kube-vip manifest lives outside Flux so API availability does not depend on
  the controllers that use the API. Declare its VIP as `--tls-san` on every server.

k3s cannot convert an agent to a server in place. Drain it, stop k3s, remove
`/var/lib/rancher/k3s` and `/etc/rancher/node`, delete the Kubernetes node and its
`<node>.node-password.k3s` secret, then rebuild with the server role enabled.

New nodes also need:

- a MikroTik BGP peer;
- their IP in both `k3s-nodes` (BGP) and `bgp-peers` (BFD) firewall lists;
- a DHCP reservation; and
- any required NAS exports or RouterOS per-user `address=` allowlists.

Verify BGP with `/routing/bgp/session print` and BFD with
`/routing/bfd/session/print`.

## builder01 and binary cache

`builder01` is a 16-vCPU, 8-GB build host on local NVMe. Harmonia serves its Nix
store at `http://10.0.0.21:5000`; fleet hosts prefer it at priority 30 and fall back
to cache.nixos.org when it is off.

It deliberately has no Proxmox HA and no `onboot`. Automatic time-based GC is also
disabled: remote builds leave no gcroot, so weekly GC would erase the cache.
`min-free`/`max-free` perform pressure-based eviction instead.

Check the cache with:

```bash
curl http://10.0.0.21:5000/nix-cache-info
curl http://10.0.0.21:5000/<storehash>.narinfo | grep Sig
```

The signing key is generated with:

```bash
nix-store --generate-binary-cache-key builder01.lab.r4r3.me-1 priv pub
```

Its private half belongs in `nix/secrets/nix-builder.sops.yaml`; the public half
belongs in `common.nix`. Rotate both together.

## Build and publish the netboot image

Build on `builder01`, where the output also remains pinned by `/root/netboot-result`:

```bash
ssh root@10.0.0.21 'rm -rf /root/nixcfg && mkdir -p /root/nixcfg'
tar -C nix -cf - . | ssh root@10.0.0.21 'tar -C /root/nixcfg -xf -'
ssh root@10.0.0.21 'nix build /root/nixcfg#packages.x86_64-linux.netbootInstaller \
  --out-link /root/netboot-result --print-build-logs'
```

Publish the three colocated outputs to `netboot01`:

```bash
ssh root@10.0.0.21 'tar -C /root/netboot-result -chf - bzImage initrd netboot.ipxe' \
  | ssh root@10.0.0.35 \
      'tar -C /var/lib/netbootxyz/assets/nixos-installer -xf -'
```

The entry point is `http://10.0.0.35/nixos-installer/netboot.ipxe`. Treat
netboot.xyz's `config/` and `assets/` as mutable appliance state; only the generated
`boot.cfg` is declared by this flake. Edit `nix/modules/netbootxyz-boot.cfg`, never
the live copy or generated `menus/*.ipxe` files.

## Retire a host

```bash
kubectl drain <name> --ignore-daemonsets --delete-emptydir-data
ssh root@<node> 'systemctl disable --now k3s'
kubectl delete node <name>
kubectl -n kube-system delete secret <name>.node-password.k3s
ssh <pve-host> 'qm stop <id> && qm destroy <id> --purge --destroy-unreferenced-disks 1'
```

Stop k3s before deleting the node object or it immediately re-registers. A
single-instance CNPG database may block drain through its PodDisruptionBudget; once
the node is cordoned, delete that pod so the operator can recreate it elsewhere.

Also remove the host from MikroTik BGP, both firewall address lists, DHCP, RouterOS
user allowlists, and NAS exports.

## Troubleshooting notes

- Upgrade k3s only through nixpkgs and rolling `nixos-rebuild switch`, one server at
  a time. In-cluster upgraders cannot replace binaries in the read-only Nix store.
- A rebuilt node needs its old `<node>.node-password.k3s` secret deleted before it
  can rejoin under the same name.
- `--node-label` applies only at registration; use `kubectl label` afterward.
- Do not provision proxmox-csi volumes while their selected node is cordoned.
- NixOS has no `/lib/modules`; the k3s module's tmpfiles symlink is intentional.
- disko owns the GRUB device; do not also set `boot.loader.grub.devices`.
- Never bump `system.stateVersion` merely to match the current release.
- `qm reset` does not reload changed VM configuration; use `qm stop` and `qm start`.
- Do not pass `-i` to nixos-anywhere. Use `--ssh-option IdentitiesOnly=yes` and
  `--ssh-option IdentityFile=<path>`.
- For a reused IP, verify the new SSH fingerprint and run `ssh-keygen -R <ip>`.
- Check DHCP leases, ARP, and ping before assigning an apparently free address.
  Static hosts still require reservations because they sit inside the DHCP pool.
- Quote RouterOS names containing brackets, for example `server="dhcp[lab]"`.
- NixOS list options merge with defaults. Do not repeat cache.nixos.org in
  `nix.settings.substituters`; cache priority, not list order, chooses precedence.
- `services.harmonia.cache.*` is the current option namespace.
- If a configured loopback address remains absent, explicitly add its generated
  service to `multi-user.target`; loopback has no udev event to start it.
- openresolv drops non-loopback nameservers by default when `127.0.0.1` is present.
  Set `networking.resolvconf.extraConfig = "resolv_conf_local_only=NO"` when fallback
  resolvers must remain available.
