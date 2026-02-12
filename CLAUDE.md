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

## Environment

- `direnv` auto-loads `.envrc` which sets `KUBECONFIG` and `SOPS_AGE_KEY_FILE`
- Kubeconfig: `provision/kubeconfig`
- Dependency updates are automated via Renovate (config: `.github/renovate.json5`)
