# NixOS hosts

Declarative config for the lab's NixOS VMs. Nothing here is reconciled by Flux —
every Flux Kustomization points under `./cluster`, so this directory is inert.

## Layout

```
flake.nix              # inputs + host auto-discovery; no per-host edits needed
modules/
  common.nix           # every host: users, ssh, sops, network, nix GC, PVE guest
  k3s-worker.nix       # class, opt-in via lab.k3sWorker.enable
  nix-builder.nix      # class, opt-in via lab.nixBuilder.enable
  disk-uefi.nix        # ESP + systemd-boot   — required for PXE
  disk-bios.nix        # EF02 + GRUB          — only for debian-13 template clones
hosts/<name>/
  default.nix          # host assembly: address, classes, firmware, stateVersion
installer/
  netboot.nix          # PXE installer image with the SSH key baked in
secrets/
  k3s-cluster.sops.yaml  # shared by all k3s workers (the join token is shared)
  nix-builder.sops.yaml  # builder01's binary cache signing key
```

Every directory under `hosts/` becomes a `nixosConfiguration` automatically, named
after the directory. **Adding a host does not touch `flake.nix`.**

The split matters because not every VM is a k3s node. `common.nix` is what any lab
VM wants; `k3s-worker.nix` is a class you opt into. A future `adguard` host imports
`common.nix` (automatically) and its own service module, and gets none of the k3s
storage drivers, disabled firewall, or node labels.

`common.nix` deliberately defaults `networking.firewall.enable = true`; the k3s class
overrides it to `false` because k3s manages its own chains. Service hosts keep it on.

## Secrets: sops-nix on the host's SSH key

There is no separate key system. Each host's ed25519 **SSH host key** converts to an
age identity via `ssh-to-age`; sops encrypts to that plus the admin key, and the host
decrypts at activation with a key it already had.

`.sops.yaml` (repo root) carries a `nix/secrets/.*` rule listing every recipient.
Secrets are declared at the point of use — the k3s token lives in `k3s-worker.nix`,
not in a central file — with `restartUnits` so a rotation restarts the consumer.

Verify a host's identity matches what a secret is encrypted to:

```
ssh root@<host> 'cat /etc/ssh/ssh_host_ed25519_key.pub' | ssh-to-age
grep -oE 'age1[a-z0-9]{20,}' secrets/k3s-cluster.sops.yaml | sort -u
```

## Adding a host

**The ordering is not optional.** A freshly installed host has an SSH key that nothing
is encrypted to yet, so it cannot decrypt anything on first boot. Break the cycle by
generating the key first:

1. `mkdir hosts/<name>` containing a single `default.nix`. Set `lab.host.ipv4`, the
   classes it needs, and `system.stateVersion`. There is no per-host disk file —
   import `modules/disk-uefi.nix` (or `disk-bios.nix`), which pairs the partition
   layout with the matching bootloader so the two cannot disagree.
2. Generate its host key locally and derive the recipient:
   `ssh-keygen -t ed25519 -N "" -f /tmp/stage/etc/ssh/ssh_host_ed25519_key`
   then `ssh-to-age < /tmp/stage/etc/ssh/ssh_host_ed25519_key.pub`
3. Add that recipient to the `nix/secrets/` rule in `.sops.yaml`.
4. Re-encrypt existing secrets to include it: `sops updatekeys secrets/k3s-cluster.sops.yaml`.
5. Create the VM (below), then install with the key staged:
   `nixos-anywhere --flake ./nix#<name> --build-on remote --extra-files /tmp/stage --target-host ...`
6. **`shred` the staging tree immediately** — it holds a cleartext private key on a
   third machine. Check the installed key is `0600`; a paste instead of a copy loses
   the mode and sshd silently refuses to load it.

### VM settings baseline

```
--bios ovmf --efidisk0 local-lvm:1,efitype=4m,pre-enrolled-keys=0
--machine q35
--cpu host --numa 0 --balloon 0
--scsihw virtio-scsi-single
--virtio0 local-lvm:<size>,discard=on,iothread=1
--net0 virtio,bridge=vmbr0,firewall=1,tag=1000
--agent enabled=1,fstrim_cloned_disks=1
--serial0 socket --rng0 source=/dev/urandom
--ostype l26 --onboot 1
```

- **UEFI is mandatory for PXE.** DHCP hands out `netboot.xyz.efi` unconditionally —
  `boot-file-bios` (`netboot.xyz.kpxe`) exists as an option but is in no option set,
  and there is no option-93 arch matcher. A SeaBIOS guest simply cannot netboot here.
- **Boot disk on `virtio0`, not `scsi0`.** proxmox-csi attaches PVCs as `scsi1+`, so
  keeping the root on virtio-blk makes the rule absolute: `/dev/vda` is always the
  boot disk, every `/dev/sd*` is a CSI volume. disko formats whatever you name it, so
  that separation is worth more than virtio-scsi's flexibility on a disk that never
  changes. Set `lab.host.disk` to match.
- **`--balloon 0`.** kubelet derives allocatable memory from total RAM; ballooning
  reclaims underneath it and produces OOM kills it cannot account for.
- **`--rng0 source=/dev/urandom`.** Without it boot stalls waiting for entropy, which
  looks like a hang rather than a missing device.
- **`--cpu host`** costs cross-vendor live migration, which the Intel→AMD MS-A2 move
  breaks regardless.
- **`--machine q35`** going forward. Not a requirement — VM 104 PXE-booted UEFI fine on
  PVE's default i440FX — but q35 is the modern PCIe topology and the right pairing with
  OVMF.
- **Storage follows how the service is made redundant.** A host with a running twin goes
  on `local-lvm` with no HA — the resolvers announce the same anycast address, so losing
  one is a BGP withdrawal and Proxmox HA would add nothing. A **single-instance** host
  (`netboot01`, `tsrouter01`) goes on `ceph` and into HA, so it comes back by itself after
  a node dies rather than waiting for someone to notice. Moving between them is online:
  `qm move-disk <id> virtio0 ceph`, repeat for `efidisk0`, then `qm set <id> --delete
  unused0,unused1` — the originals are kept as `unusedN` and silently keep consuming the
  old storage until removed.

### Creating the VM by PXE (preferred)

Set the boot order **disk first, network second — and leave it that way forever**:

```
--boot order=virtio0;net0
```

A new VM has an empty disk, so UEFI finds no bootable entry and falls through to the
network. After the install the ESP is bootable and the disk wins. No boot-order change
between install and reboot, and nothing to forget.

Add a MAC-gated rule to `boot.cfg` (see **The netboot image**), start the VM, and it
lands in an installer that already trusts your key:

```
nixos-anywhere --flake ./nix#<name> --build-on remote --target-host root@<installer-ip>
```

**Then remove the MAC rule from `boot.cfg`.**

The interesting case is not an empty disk — reinstalling that is the point. It is a disk
whose *root filesystem is intact* but whose boot path is broken: a corrupted ESP, a
`nixos-rebuild switch` that died while installing the bootloader, lost UEFI NVRAM
entries. UEFI then falls through to the network and, if a rule still matches the MAC,
disko wipes a node that was recoverable.

For a cattle worker the wipe itself is cheap — `/nix` and the image cache re-populate.
What actually bites is that a reinstall regenerates the **SSH host key**, changing the
host's age identity, so sops-nix can no longer decrypt `k3s-cluster.sops.yaml`. The node
boots fine and silently never joins, and recovering means re-keying sops.

So self-healing reinstall is a reasonable thing to want; it is only unsafe *because*
node identity is currently tied to the disk. Either remove the rule after provisioning
(cheapest), or break that coupling first — stage the token with `--extra-files` instead
of sops, or key sops to something not derived from the host key.

### Creating the VM by template clone (fallback)

Clone the `debian-13` template (VM `108`, on pve02). It is throwaway scaffolding —
disko wipes the disk — but it boots, answers SSH with your key and has passwordless
sudo, which avoids the console step a NixOS ISO would need. Cross-node clone to
non-shared storage is refused, so clone locally then migrate:

```
ssh <pve02> 'sudo qm clone 108 <id> --name <name> --full 1 --storage local-lvm'
ssh <pve02> 'sudo qm migrate <id> pve01 --with-local-disks'
ssh <pve01> 'sudo qm set <id> --cores 4 --memory 6144 --balloon 0 \
  --agent enabled=1,fstrim_cloned_disks=1 --serial0 socket --onboot 1'
ssh <pve01> 'sudo qm resize <id> virtio0 60G && sudo qm start <id>'
```

Resize **before** installing — disko claims 100% of the device. Find the address with
`sudo qm guest cmd <id> network-get-interfaces`.

PXE skips the clone, the migrate and the kexec entirely — see **The netboot image**.

## Control plane

`lab.k3sWorker.server = true` turns a node into a control-plane member (embedded etcd)
that still schedules workloads. The rules that matter:

- **One server per PVE host.** etcd survives losing a minority, so two members on one
  hypervisor means that hypervisor takes quorum with it.
- **Keep the member count odd.** Three and four members both tolerate exactly one
  loss, so four is strictly worse than three. Going 1→2 is the dangerous step: quorum
  becomes 2, and any single failure is fatal. Move through it quickly.
- **To replace a server, add then remove** — join the new one to reach four, then drop
  the old one back to three. Never remove first.
- **Joining servers must repeat the founding server's flags.** The class does this, but
  if you change them, change them everywhere: a flannel backend mismatch breaks pod
  networking cluster-wide, and a missing `--disable` re-enables bundled traefik or
  servicelb.
- `serverAddr` is used **only to register**. Afterwards k3s keeps its own load-balanced
  list of every server and fails over by itself, so a stale value breaks a fresh join
  and nothing else. Servers point at a peer in a ring, because a server cannot register
  through itself.

**k3s has no in-place agent→server conversion** — the data directories differ. Drain the
node, `systemctl stop k3s`, `rm -rf /var/lib/rancher/k3s /etc/rancher/node`, delete the
node object *and* its `<node>.node-password.k3s` secret, then rebuild with the class
flipped. It rejoins under the same name.

Servers set `system-reserved`/`kube-reserved` because they also run workloads, and an
OOM sweep that reaps etcd on a quorum member takes the whole API down.

### API endpoint

`modules/kube-vip.yaml` is applied through `services.k3s.manifests`, which k3s
auto-deploys on servers. It publishes a floating VIP with leader election so kubectl and
new agents have one address that survives a node dying.

It is deliberately **not** in `cluster/` under Flux: the address you dial to reach the
API must not depend on the GitOps controllers that themselves need the API. It also runs
with `svc_enable=false` so it never competes with MetalLB for Service LoadBalancers.

Declare the VIP as a `--tls-san` on servers **before** you need it — adding it later
means reissuing API certificates, while adding it up front costs nothing.

## The build host and binary cache

`builder01` (10.0.0.21, VM 111 on pve02) is the one host in the fleet whose job is
to compile. `modules/nix-builder.nix` is the class; `lab.nixBuilder.enable` turns it
on. It exists because of three separate problems that all have the same fix:

- The service guests were shrunk to 1 vCPU / 1 GB and **can no longer build their own
  closures**. `nixos-rebuild --build-host` is now mandatory for them, not an
  optimisation.
- Without a cache every host derives the same closures independently.
- The 522 MB PXE installer had to be built by hand on a k3s node and rsynced.

It runs **`services.harmonia.cache`**, which serves `/nix/store` over HTTP on `:5000`.
Nothing has to be pushed to it: a `nixos-rebuild --build-host builder01` leaves the
result in builder01's store, and that store *is* the cache.

`modules/common.nix` points the whole fleet at it, so this is transparent — a host
that needs a path builder01 already has fetches it instead of building it.

### Deploying anything

```
nixos-rebuild switch --flake ./nix#<name> \
  --target-host root@<ip> --build-host root@10.0.0.21
```

The closure goes **builder01 → target directly**; it never travels through the Mac.
`adguard01` (1 vCPU / 1 GB) rebuilds this way in about 12 seconds.

`--build-host` and `--target-host` may name the same machine — that is the right shape
for builder01 and for the k3s nodes, which are big enough to build for themselves.

### Sizing and why there is no HA

16 vCPU, 8 GB, 180 GB on **local-lvm**. A build store wants a fast local NVMe, not
ceph: it is write-heavy, entirely reproducible, and replicating it buys nothing.

For the same reason it is deliberately **not** in Proxmox HA, unlike `netboot01` and
`tsrouter01`. Those are single-instance *and* load-bearing. Losing builder01 costs a
slower deploy on the hosts that can still build and a broken deploy on the ones that
cannot — annoying, not an outage, and rebuilding it is a PXE install.

`max-jobs * cores` is pinned to the vCPU count rather than oversubscribed. On a build
host RAM is the binding constraint, and an OOM kill loses the entire `nixos-rebuild`
rather than degrading it. There is also an 8 GB swapfile, because `disk-uefi.nix` lays
out ESP + root only and a linker spike with no swap is a hard failure.

### Garbage collection is inverted here

`common.nix` runs `nix-collect-garbage --delete-older-than 14d` weekly. On this host
that is **forced off**, because it would empty the cache every week: a
`nixos-rebuild --build-host` copies its result to the target and leaves **no gcroot
behind**, so every closure built for another host is unreachable the moment the deploy
finishes and a full GC pass takes all of it.

Eviction is driven by `min-free`/`max-free` (20 GB / 60 GB) instead. That only runs
*during a build*, which is also the only thing that fills the store, so it is
self-regulating: the cache keeps everything until disk pressure, then frees 60 GB.
`keep-outputs`/`keep-derivations` are on so a near-identical rebuild reuses inputs.

To pin something in the cache regardless, give it a gcroot — `nix build --out-link
/root/<name>` is exactly that, which is why the netboot installer build below keeps
its 1.97 GB closure permanently resident instead of losing it to the next sweep.

### The signing key

Harmonia signs the narinfo it serves; the store itself holds unsigned, locally-built
paths. So the key is the only thing that makes the cache usable by a client that does
not trust it blindly.

```
nix-store --generate-binary-cache-key builder01.lab.r4r3.me-1 priv pub
```

The private key is `secrets/nix-builder.sops.yaml`, consumed through `sops.secrets`.
The public key is not secret and lives in `common.nix` under `trusted-public-keys`.
Rotating it means both halves at once, or every host rejects the cache.

Priority is pinned to **30** against cache.nixos.org's 40. That number, not the order
of the `substituters` list, is what decides who is asked first — leave it at harmonia's
default 50 and clients fetch over the WAN what is already sitting on the LAN.

### Checking it

```
curl http://10.0.0.21:5000/nix-cache-info                 # StoreDir, Priority: 30
curl http://10.0.0.21:5000/<storehash>.narinfo | grep Sig # signed by builder01…-1
```

To prove a client really substitutes rather than rebuilds, use a path that **cannot**
come from cache.nixos.org — build a throwaway derivation on builder01, then realise it
on another host, which has no `.drv` for it and therefore could only have fetched it:

```
ssh root@10.0.0.21 "nix-build --no-out-link --expr 'derivation {
  name = \"probe\"; system = \"x86_64-linux\"; builder = \"/bin/sh\";
  args = [ \"-c\" \"echo hi > \$out\" ]; }'"
ssh root@<other> "nix-store --realise <that-path>"
```

The cache is plain HTTP with no authentication, on the lab VLAN only. sops-nix
decrypts to `/run/secrets` at activation, so no repo secret is ever in a store path —
but the store does expose every host's rendered configuration, which is why this stays
off any routable path.

## The netboot image

`installer/netboot.nix` builds a NixOS installer that PXE-boots with your SSH key
already in it. That is the entire reason it exists: the installer restores root's
`authorized_keys` **from the initrd** (see `restore-remote-access.nix` in
nix-community/nixos-images), and the stock image published on GitHub has none — so
booting it leaves you at a console with no way in. Baking the key makes PXE
provisioning unattended.

Booting it also sidesteps the DHCP lease dance: a netbooted machine announces one
hostname from its first DHCP request and never changes identity mid-install, unlike
the clone→kexec path which switches from `debian13-template` to `nixos-installer`
and gets a second address.

### Building it

`nix build --builders …` **does not work from the Mac** — the local daemon rejects it
with *"ignoring the client-specified setting 'builders', because it is a restricted
setting and you are not a trusted user"*. (`nixos-rebuild --build-host` is unaffected;
it runs nix over SSH on the target instead of going through the local daemon.) So ship
the flake to an x86_64 host and build there — the same rsync-then-build shape a CD
pipeline would use:

```
ssh root@10.0.0.21 'rm -rf /root/nixcfg && mkdir -p /root/nixcfg'
tar -C nix -cf - . | ssh root@10.0.0.21 'tar -C /root/nixcfg -xf -'
ssh root@10.0.0.21 'nix build /root/nixcfg#packages.x86_64-linux.netbootInstaller \
  --out-link /root/netboot-result --print-build-logs'
```

**Build it on `builder01`.** This used to mean picking a k3s agent by hand — never a
control-plane node, never a PVE host — because nix builds are write-heavy and
CPU-hungry, hypervisors already run Ceph plus every VM, and thrashing a server node's
disk beside an etcd member is a bad trade. builder01 exists so that choice is no longer
a judgement call, and the resulting 1.97 GB / 690-path closure lands in the cache, so
the next host that wants any of it substitutes instead of rebuilding.

The tarball is still needed because `nix build` runs on the far side of an SSH session
and needs the flake *there*; `--build-host` is a `nixos-rebuild` feature and does not
apply to a plain `nix build` of a flake package.

Output is ~522 MB: `bzImage` (13 M), `initrd` (509 M), `netboot.ipxe`.

### Publishing it

`netboot01` (10.0.0.35) runs the upstream netboot.xyz container declaratively — see
`modules/netboot.nix`. It mounts `/var/lib/netbootxyz/assets` as `/assets` and serves it
with nginx on `:80`. The generated `netboot.ipxe` references `bzImage` and `initrd` by
**relative path**, so all three must sit in one directory:

```
ssh root@10.0.0.40 'tar -C /root/netboot-result -chf - bzImage initrd netboot.ipxe' \
  | ssh root@10.0.0.35 'tar -C /var/lib/netbootxyz/assets/nixos-installer -xf -'
```

Served at `http://10.0.0.35/nixos-installer/netboot.ipxe`. Verify with `curl -I`.

`config/` and `assets/` are deliberately **mutable state**, not declared: the appliance
ships its own `menus/*.ipxe` and rewrites them on update, and `assets/` holds large
downloaded images. Only `boot.cfg` is asserted from the flake.

### Auto-booting it

netboot.xyz's main menu ends with `choose --timeout ${timeout} --default ${menu} menu ||
goto local`, so setting `menu` and `timeout` gives unattended boot and anything unmatched
falls through to booting from disk. Because `config/menus/boot.cfg` is itself an iPXE
script, gate it on the MAC of the machine being provisioned, as the first lines of the
file so it runs before the menu:

```
iseq ${net0/mac} bc:24:11:xx:xx:xx && chain http://10.0.0.35/nixos-installer/netboot.ipxe ||
```

Only that VM auto-installs; every other PXE client keeps the interactive menu.

**Edit `modules/netbootxyz-boot.cfg` in this repo and `nixos-rebuild`** — never the copy
on the box, which is overwritten on every activation, and never `menus/*.ipxe`, which the
appliance replaces on update. That is also why the built-in `nixos.ipxe` stops at 25.11
while `menuversion.txt` already reads 3.0.2. Declaring the menu is what makes the MAC rule
a reviewable diff and its removal a revert rather than a thing to remember.

Two traps that cost real time before the menu was declared:

- **`config/menus/local/boot.cfg` is not served.** A same-sized copy sits there, so
  editing it looks right and does nothing — the VM PXE-boots, takes a DHCP lease, then
  drops to the UEFI boot manager with no clue why.
- **The menus go over TFTP, not the nginx on `:80`** — every HTTP path 404s. Check which
  file is live with `curl tftp://10.0.0.35/boot.cfg`, and run it **from a lab host**:
  dnsmasq replies from a fresh source port, which a NixOS host firewall or a client on
  another subnet drops, so a timeout there means nothing. The container logs
  `sent /config/menus/boot.cfg to <ip>` either way — trust that over the client.

Unrelated but worth fixing while in there: `config/menus/boot.cfg` pins
`boot_domain netbootxyz.<lab-domain>/<version>`, and both that path and `/3.0.2/` return
**404** because `assets/` was empty. It only feeds `memdisk` and `sigs` (and
`sigs_enabled` is false), so nothing you use is broken — but memdisk-based entries are.

## Day 2

```
nixos-rebuild switch --flake ./nix#<name> \
  --target-host root@<ip> --build-host root@10.0.0.21
```

`--build-host` is required from macOS: these are `x86_64-linux` and the Mac is not.
Point it at **builder01** rather than at the target — the 1 vCPU / 1 GB service guests
cannot build their own closures at all any more, and the ones that can still do it
faster on 16 cores. Rollback is `nixos-rebuild --rollback`, or pick an older generation
at boot.

**Drain k3s nodes first.** A switch that touches `k3s.service` restarts containerd and
every pod on the node with it.

## Teardown

```
kubectl drain <name> --ignore-daemonsets --delete-emptydir-data
ssh root@<node> 'systemctl disable --now k3s'      # before deleting the node object
kubectl delete node <name>
kubectl -n kube-system delete secret <name>.node-password.k3s
ssh <pve-host> 'qm stop <id> && qm destroy <id> --purge --destroy-unreferenced-disks 1'
```

**Stop k3s on the node before deleting the node object**, or it re-registers within
seconds and the delete looks like it silently failed.

A `drain` will not evict a single-instance CNPG database: its PodDisruptionBudget can
never allow it, so drain spins until timeout. Delete that pod directly once the node is
cordoned — the operator recreates it elsewhere. Expect several minutes in `Terminating`
while Postgres checkpoints.

Retiring a node also means cleaning up everything keyed to its address:

- MikroTik: its BGP connection, and its entry in **both** the `k3s-nodes` and
  `bgp-peers` firewall address-lists, plus the DHCP reservation
- MikroTik: any **per-user `address=` allowlist** (`/user/print`) that names it —
  these are easy to miss and fail closed, showing up only as `login failure for user
  <x> from <ip>` in the router log
- NFS exports on the NAS

A contiguous CIDR (`10.0.0.40/29`) in place of per-node entries removes most of this
chore permanently.

## Gotchas

All hit for real.

- **No in-cluster upgrader may touch these nodes.** Anything that swaps the k3s
  binary in place (`rancher/k3s-upgrade` and friends) resolves it to its `/nix/store`
  path and tries to `cp` over it; the store is read-only, so the job loops and leaves
  the node cordoned. k3s versions come from `pkgs.k3s_*` in `modules/k3s-worker.nix`,
  and upgrading is a nixpkgs bump plus a rolling `nixos-rebuild switch`, **one server
  at a time**. Nothing reminds you to do it.
- **DHCP hands out a new lease at kexec.** The installer announces hostname
  `nixos-installer`, and RouterOS issues a *different* address, so nixos-anywhere retries
  an address the machine has left. Resume with
  `--phases disko,install,reboot --target-host root@<new-ip>`. A static lease bound to the
  MAC avoids it; reservations already exist for every k3s node.
- **A new node needs a BGP peer on the MikroTik, or MetalLB will black-hole its
  services.** The router runs `connect=no listen=yes`, so it accepts sessions only
  from explicitly configured neighbours — an unknown node's session is refused with
  no error anywhere in the cluster. MetalLB still logs `announcing from node <x>`,
  so it looks healthy; the only evidence is a missing route on the router. A service
  with `externalTrafficPolicy: Local` is announced *only* from the node running its
  pod, so one unpeered node takes that service down completely — this is how a
  mosquitto VIP took every MQTT/zigbee2mqtt device in Home Assistant offline. Services
  with the default traffic policy survive, because other nodes keep announcing.

  ```
  /routing/bgp/connection add name=bgp-<node> instance=bgp-instance-1 \
    remote.address=<ip>/32 remote.as=65123 local.address=10.0.0.1 \
    local.role=ibgp connect=no listen=yes routing-table=main as=65123 use-bfd=yes
  ```

  Verify with `/routing/bgp/session print` (look for flag `E`) and confirm routes
  appear via the new node's IP.

  **The node must be added to TWO firewall address-lists, not one.** This is the
  trap: `k3s-nodes` gates BGP itself (tcp/179), but a separate `bgp-peers` list
  gates **BFD** (udp/3784,4784) — and the MetalLB `BGPPeer` here sets
  `bfdProfile`, so BFD is mandatory. Miss `bgp-peers` and the symptom is
  maddening: TCP/179 is reachable, FRR reports `BGP state = Established`, then
  `Last reset ... Peer closed the session` a few seconds later, forever. The
  router's BFD session sits at `state=down packets-rx=0` while the node's
  `show bfd peers brief` sits at `init` — router→node works, node→router is
  dropped. Add both:

  ```
  /ip/firewall/address-list/add list=k3s-nodes address=<ip> comment="<name>"
  /ip/firewall/address-list/add list=bgp-peers address=<ip> comment="<name>"
  ```

  Check with `/routing/bfd/session/print` — every peer should show flag `U`.
- **`--node-label` applies at registration only.** Changing one later needs
  `kubectl label`; the flag alone will not move it. Self-labelling an unprefixed key
  (`managed-by=nixos`) via `--node-label` is confirmed working: a fresh join registers
  with it already set.
- **Node password.** k3s stores `<node>.node-password.k3s` in `kube-system`. A node
  rebuilt from scratch generates a new password and the server rejects the rejoin —
  delete the secret before re-installing under the same name.
- **Don't provision volumes while the node is cordoned.** A `proxmox-data-ext4` PVC bound
  while its node was cordoned landed in the wrong zone despite the `selected-node`
  annotation; a clean retry placed it correctly.
- **`networking.interfaces.lo` addresses are generated and never applied.** The
  scripted-networking `network-addresses-<iface>.service` units are pulled in by each
  interface's udev device unit; loopback has none, so the generated unit carries only
  `PartOf=` — which stops a unit but never starts one. It sits `inactive (dead)` and the
  addresses are silently absent. `network-setup.service` and `network-online.target` are
  both inactive on these hosts, so add `wantedBy = [ "multi-user.target" ]` yourself.
  This is how an anycast host comes up with a healthy BGP session and still black-holes
  every packet steered to it.
- **A loopback nameserver silently discards every other one.** openresolv defaults
  `resolv_conf_local_only` to yes, so `networking.nameservers = [ "127.0.0.1" "9.9.9.11" ]`
  writes *only* `127.0.0.1` to `/etc/resolv.conf`. `resolvconf -l` still lists both, which
  makes it look configured. On a host that resolves through its own service, that means no
  DNS at all whenever the service is down — exactly when you need to `nixos-rebuild` to fix
  it. Set `networking.resolvconf.extraConfig = "resolv_conf_local_only=NO"`.
- **`/lib/modules`** does not exist on NixOS. The tmpfiles symlink in the k3s class is
  what keeps ceph-csi's hostPath mount working.
- **disko owns the GRUB device.** Setting `boot.loader.grub.devices` as well trips a
  `mirroredBoots` duplicate assertion.
- **Never bump `system.stateVersion`** to match the running release. It records
  install-time conventions; moving it forward is the dangerous direction.
- **`qm reset` does not re-read the VM config.** It issues a QEMU system reset, so
  anything changed with `qm set` since the VM started is ignored — the old boot order
  stays on the running command line. Use `qm stop` then `qm start`.
- **A MAC rule left in `boot.cfg` is a reinstall trap.** With the permanent
  `disk;net0` order, any node that fails to boot falls through to the network. If its
  MAC still matches, it reimages itself unattended — and loses the SSH host key its
  sops identity is derived from. Remove the rule as soon as a host is installed.
- **The k3s NixOS module moved** to `nixos/modules/services/cluster/rancher/` in 26.05.
  `services.k3s.*` is unchanged, but older search results point at the old path.
- **`nixos-anywhere` must not be given `-i`.** Its own flag collides with the temporary
  key it manages and it dies with `Load key ...: invalid format` while reporting exit 0.
  Pass the identity through instead:
  `--ssh-option IdentitiesOnly=yes --ssh-option IdentityFile=<path>`.
- **A reused IP trips `known_hosts` and blocks `nixos-rebuild`** with a host-key
  mismatch. `ssh-keygen -R <ip>` first — but verify the new fingerprint against
  `/etc/ssh/ssh_host_ed25519_key.pub` on the host before trusting it, rather than
  disabling checking.
- **A free-looking IP is not free.** The DHCP lease table showed nothing for
  `10.0.0.20/.21/.29/.30/.34/.36`, and `.29` still answered ping — a statically
  configured device leaves no lease to find. `.36` was worse: it had a complete ARP
  entry pointing at netboot01's own MAC, because that was the temporary address
  netboot01 was installed on. Check all three before claiming one — no lease, no
  *complete* ARP entry, and no ping reply:

  ```
  /ip/dhcp-server/lease/print where address=<ip>
  /ip/arp/print where address=<ip>
  /ping <ip> count=3
  ```

  Note every static host here sits **inside** `pool[lab]` (10.0.0.10-10.0.0.199), so
  what actually reserves the address is a DHCP static lease on the MAC, not being
  outside the pool. Add one before first boot; it also hands the PXE installer the
  host's final address, which sidesteps the lease dance entirely.
- **RouterOS eats `[` in an unquoted value.** `server=dhcp[lab]` fails with `expected
  end of command` pointing at the bracket's column; `server="dhcp[lab]"` works. The
  column number in the error is the only clue which argument it choked on.
- **`nix.settings` list options merge with the NixOS defaults, they do not replace
  them.** Setting `substituters` in `common.nix` *appends* to cache.nixos.org rather
  than overriding it, so writing upstream out explicitly to "keep" it silently produces
  a duplicated entry. The same applies to `trusted-public-keys`. Check with
  `nix eval .#nixosConfigurations.<host>.config.nix.settings.substituters` rather than
  assuming either behaviour.
- **Substituter order in the list does not decide precedence.** The `Priority` each
  cache advertises in `/nix-cache-info` does, and lower wins. A LAN cache left at
  harmonia's default 50 loses to cache.nixos.org's 40 and is silently never used for
  anything upstream also has.
- **`services.harmonia.enable` is renamed to `services.harmonia.cache.enable`.** The
  flat options (`signKeyPath`, `signKeyPaths`, `settings`) all moved under `.cache`
  too. The old names still evaluate through `mkRenamedOptionModule`, so a stale
  snippet appears to work and only the deprecation warning tells you.
- **`nixos-anywhere --extra-files` copies the *whole* staging tree to `/`.** Generating
  the SSH host key and the binary cache keypair into one scratch directory would have
  shipped a cleartext signing key into the installed root filesystem. Keep the tree to
  exactly the files that belong on the host, and check it with `find` before running.
- **Building a cache host does not make it cache anything by itself.** `nixos-rebuild
  --build-host` leaves no gcroot on the builder, so the fleet-wide weekly
  `nix-collect-garbage` would delete every closure it built for other hosts. See
  **The build host and binary cache**, "Garbage collection is inverted here".
- **RouterOS per-user `address=` allowlists fail closed and are easy to forget.**
  `/user/print` restrictions are separate from firewall address-lists; a node that is
  not listed shows up only as `login failure for user <x> from <ip>` in the router log,
  while the client just retries forever.
