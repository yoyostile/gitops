<img src="https://cdn.r4r3.me/Kubernetes_logo_without_workmark.svg.png" align="left" width="144px" />

### My home Kubernetes cluster :sailboat:
_... managed by Flux and serviced with RenovateBot_ :robot:

<br>
<br>
<br>

# 🛠 Gitops

This repository utilizes Flux. Flux is a tool for keeping Kubernetes clusters in sync with sources of configuration (like Git repositories), and automating updates to configuration when there is new code to deploy. Please have a look at the [docs](https://fluxcd.io/docs/).

Also have a look at this great chart:
![overview](https://cdn.r4r3.me/random/gitops-toolkit.png)

## 📁 Repository Structure

```
cluster/
├── base/flux-system/   # Flux controllers, GitRepository, HelmRepositories, encrypted secrets
├── crds/               # Custom Resource Definitions
├── core/               # Infrastructure components
└── apps/               # Applications, organized by namespace
```

Flux reconciles in order: `base` → `crds` → `core` → `apps`.

## 🔐 Secrets

Secrets are encrypted at rest using [SOPS](https://github.com/mozilla/sops) + [age](https://github.com/FiloSottile/age). Files matching `*.sops.yaml` are automatically decrypted by Flux during reconciliation. The age key is expected at `~/.config/sops/age/keys.txt`.

## 🏁 Quickstart

### Tools & Requirements
| Tool                                                      | Why? |
| --------------------------------------------------------- | --- |
| [age](https://github.com/FiloSottile/age)                 | Modern encryption tool used by SOPS |
| [sops](https://github.com/mozilla/sops)                   | Simple and flexible tool for managing secrets |
| [kustomize](https://github.com/kubernetes-sigs/kustomize) | Customization of kubernetes YAML configurations |
| [direnv](https://github.com/direnv/direnv)                | Unclutter your .profile |
| [go-task](https://github.com/go-task/task)                | A task runner / simpler Make alternative written in Go |
| [flux](https://fluxcd.io)                                 | Continuous and progressive delivery solutions for Kubernetes |
| [pre-commit](https://github.com/pre-commit/pre-commit)    | A framework for managing and maintaining multi-language pre-commit hooks |

Before you start simply do this:
```
$ brew bundle
$ task pre-commit:init
```
