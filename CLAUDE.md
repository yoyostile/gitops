# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Flux CD v2 GitOps repository managing a home Kubernetes cluster. All cluster state is declared in Git and automatically reconciled by Flux. Secrets are encrypted with SOPS + Age.

## Key Commands

```bash
brew bundle                  # Install all required tools (first-time setup)
task pre-commit:init         # Initialize pre-commit hooks (first-time setup)
task flux:sync               # Trigger Flux reconciliation from Git
task lint:all                # Run all linters (yamllint, markdownlint, prettier)
task format:all              # Auto-format Markdown and YAML with prettier
```

Lint/format configs live in `.github/linters/`.

## Secrets Management

- Files matching `*.sops.yaml` are encrypted with SOPS + Age
- `.sops.yaml` defines encryption rules: `data`/`stringData` fields in `cluster/**`, `values` in helm-release files
- Age key: `~/.config/sops/age/keys.txt` (set via `.envrc`)
- Decrypt: `sops -d file.sops.yaml` | Encrypt: `sops -e file.yaml` | Edit in-place: `sops file.sops.yaml`
- Pre-commit hook (`forbid-secrets`) blocks committing unencrypted secrets

## Architecture

### Reconciliation Order

Flux applies resources in a strict dependency chain:

```
cluster/base/flux-system    (Flux controllers, GitRepository, HelmRepositories, encrypted secrets)
        ↓
cluster/crds                (CRDs: cert-manager, prometheus-operator, mariadb-operator, metallb, traefik)
        ↓
cluster/core                (Infrastructure: cert-manager, metallb, external-dns, storage provisioners, velero)
        ↓
cluster/apps                (Applications, organized by namespace)
```

### Application Structure

Each app follows this pattern:

```
cluster/apps/{namespace}/{app-name}/
├── ks.yaml                    # Flux Kustomization - points to ./app, configures substitution
└── app/
    ├── kustomization.yaml     # Kustomize resource list
    ├── helm-release.yaml      # HelmRelease (for Helm-based apps)
    ├── deployment.yaml        # Raw manifests (for non-Helm apps)
    ├── ingress.yaml
    └── *.sops.yaml            # Encrypted secrets/configmaps
```

Apps are either Helm-based (using `HelmRelease` CRD referencing a `HelmRepository` from `cluster/base/flux-system/charts/`) or raw manifests.

### Variable Substitution

Flux Kustomizations use `postBuild.substituteFrom` to inject variables from:
- `cluster-settings` ConfigMap (cluster-wide non-secret config)
- `cluster-secrets` Secret (cluster-wide secret values)

Use `${VARIABLE_NAME}` syntax in manifests. When substitution is not needed, set `substitute: {}` to explicitly disable it.

### Namespace Organization

Apps are grouped under `cluster/apps/` by namespace: `cnpg`, `default`, `kube-system`, `monitoring`, `networking`, `system-upgrade`, `trivy-system`, `woodpecker`. To add an app, create its directory under the appropriate namespace and add it to that namespace's `kustomization.yaml`.

## Ingress Patterns

- **Dual Traefik architecture**: Two separate instances - `traefik` (external, LB IP `${METALLB_TRAEFIK_ADDR}`) and `traefik-internal` (internal, LB IP `${METALLB_TRAEFIK_INTERNAL_ADDR}`)
- **Internal ingress** (e.g., lidarr, prowlarr):
  - `ingressClassName: traefik-internal`
  - Annotations: `external-dns/internal: "true"`, middleware `networking-internal-ips-only@kubernetescrd`
  - DNS managed by Mikrotik via external-dns-internal
- **External/public ingress** (e.g., searxng, echoip):
  - `ingressClassName: traefik`
  - Annotations: `external-dns/external: "true"`, `external-dns.alpha.kubernetes.io/target: "${SECRET_CLOUDFLARE_TUNNEL_DOMAIN}"`, `external-dns.alpha.kubernetes.io/cloudflare-proxied: "true"`, middleware `networking-cloudflarewarp@kubernetescrd`
  - DNS managed by Cloudflare via external-dns
- Wildcard TLS cert covers `*.${SECRET_LAB_DOMAIN}`, `*.lab.${SECRET_LAB_DOMAIN}`, `*.lan.${SECRET_LAB_DOMAIN}`, `*.hzn.${SECRET_LAB_DOMAIN}`
- TLS secret name pattern: `${SECRET_LAB_DOMAIN/./-}-tls`
- Reference templates: `cluster/apps/default/lidarr/app/ingress.yaml` (internal), `cluster/apps/default/searxng/app/ingress.yaml` (external)

## Middlewares

- `networking-internal-ips-only@kubernetescrd` - IP allowlist (10.0.0.0/8, 100.64.0.0/10, lab IPs)
- `networking-cloudflarewarp@kubernetescrd` - Validates requests from Cloudflare tunnel
- `networking-authentik@kubernetescrd` - Forward auth to Authentik SSO
- Defined in: `cluster/apps/networking/traefik/app/middlewares.yaml`

## Storage

- **Storage classes**: `nfs-client` (default, NFS subdir provisioner), `proxmox-data-ext4`/`proxmox-data-zfs` (Proxmox CSI), `ceph-rbd` (Ceph block)
- **NFS server**: `glacier.lab.${SECRET_LAB_DOMAIN}` with media at `/mnt/tank/media` (subdirs: music, series, movies, ebooks, games)
- **App config**: typically small PVCs (1Gi) on `nfs-client`
- **Media volumes**: direct NFS mounts in pod spec or Helm persistence
- **Node scheduling**: media apps use `nodeSelector: topology.kubernetes.io/region: lab`

## Key Cluster Variables

Non-secret (`cluster-settings.yaml`): `METALLB_LB_RANGE`, `METALLB_TRAEFIK_ADDR`, `METALLB_TRAEFIK_INTERNAL_ADDR`

Secret (`cluster-secrets.sops.yaml`): `SECRET_LAB_DOMAIN`, `SECRET_LAB_IP`, `SECRET_LAB_IPV6`, `SECRET_CLOUDFLARE_TUNNEL_DOMAIN`, `SECRET_CLOUDFLARE_EMAIL`, `SECRET_NFS_HOST`, `SECRET_NFS_PATH`, `TZ`

## Environment

- `direnv` auto-loads `.envrc` which sets `KUBECONFIG` and `SOPS_AGE_KEY_FILE`
- Kubeconfig: `provision/kubeconfig`
- Dependency updates are automated via Renovate (config: `.github/renovate.json5`)
