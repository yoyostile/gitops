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

## 🏁 Quickstart

### Tools & Requirements
| Tool                                                      | Why? |
| --------------------------------------------------------- | --- |
| [sops](https://github.com/mozilla/sops)                   | Simple and flexible tool for managing secrets |
| [kustomize](https://github.com/kubernetes-sigs/kustomize) | Customization of kubernetes YAML configurations |
| [direnv](https://github.com/direnv/direnv)                | unclutter your .profile |
| [go-task](https://github.com/go-task/task)                | A task runner / simpler Make alternative written in Go |
| [flux](https://fluxcd.io)                                 | Flux is a set of continuous and progressive delivery solutions for Kubernetes, and they are open and extensible. |
| [pre-commit](https://github.com/pre-commit/pre-commit)    | A framework for managing and maintaining multi-language pre-commit hooks. |

Before you start simply do this:
```
$ brew bundle
$ task pre-commit:init
```
