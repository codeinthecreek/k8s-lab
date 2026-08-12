# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A reproducible local Kubernetes lab built on kind (kubernetes-sigs/kind), not k3d or minikube. There is no application code here — the repo is kind cluster configs, plain Kubernetes manifests, and a Makefile. Full rationale for every design choice lives in `DESIGN.md`; read it before changing anything structural (profile format, manifest layout, node pinning). `docs/findings.md` is a running log of real problems hit while operating this repo (upstream manifests missing expected fields, port conflicts between profiles, etc.) — check it before re-debugging something that may already be documented there, and add an entry when you hit something non-obvious that cost time.

## Commands

```
make up [PROFILE=name]         # kind create cluster + apply that profile's manifests.txt in order
make down [PROFILE=name]       # kind delete cluster
make reset [PROFILE=name]      # down + up
make list-profiles             # ls kind/profiles
make kubeconfig [PROFILE=name] # kind export kubeconfig for that profile
make status [PROFILE=name]     # kubectl get nodes -o wide + get pods -A
```

`PROFILE` defaults to `default`. Cluster name is always `k8s-lab-$(PROFILE)`, kubectl context is always `kind-k8s-lab-$(PROFILE)`.

There is no build/lint/test tooling — this is declarative config, not code. The only real validation is running `make up` against an actual Docker daemon and checking the resulting cluster (`make status`, `kubectl describe`/`logs`, a real `curl` through the ingress hostPort). Don't claim a manifest or cluster.yaml change works without actually creating a cluster and checking pod status — YAML parsing successfully is not the same as kind or kubeadm accepting the config.

**Only one profile can run ingress-enabled at a time**: both `default` and `ha-control-plane` publish host ports 80/443 for ingress-nginx, so bringing up a second profile while one is already running fails with a Docker "port is already allocated" error. `make down PROFILE=<other>` first.

## Architecture

**Profiles are plain, complete files, not a template.** `kind/profiles/<name>/cluster.yaml` is a real kind config, `manifests.txt` is a flat ordered list of manifest paths (relative to repo root) applied via `kubectl apply -f` after cluster creation — no Kustomize, no Helm, no variable substitution anywhere. Comparing two profiles means literally diffing two files. This is deliberate (see DESIGN.md's "Why profiles are plain files, not templates") — don't introduce templating to reduce duplication between profiles.

**Every add-on is an explicit applied manifest, not a kind/tool addon flag.** Everything under `manifests/` was fetched from a real upstream release tag and is referenced by exact path from a profile's `manifests.txt`. Each manifest file's header comment records its upstream source URL/tag and every deliberate deviation from upstream. `manifests/cni/calico.yaml` is staged but intentionally not wired into either profile's `manifests.txt` yet.

**Node images are pinned by tag *and* sha256 digest** in every `cluster.yaml` (tag alone is not reproducible across kind builds). When bumping the pinned kind node image, update the digest in both profiles in the same change so they never diverge onto different images — check the digest against the upstream kind release notes rather than trusting a summarized fetch (a 64-hex-char digest is exactly the kind of value that can get silently mangled by an LLM summarization pass; pull it from the raw release body or GitHub API, not a rendered/summarized page).

**Ingress node-pinning is load-bearing, not decorative.** Upstream's ingress-nginx kind-provider `deploy.yaml` (as of controller-v1.15.1) no longer sets a `nodeSelector` tying its controller pod to a specific node, even though the pod's hostPort mapping only works on the one node whose Docker container actually publishes 80/443 to the host. `manifests/ingress/ingress-nginx.yaml` adds that `ingress-ready: "true"` nodeSelector back manually, and each profile's `cluster.yaml` labels exactly one node that way via `kubeadmConfigPatches` (the control-plane node in `default`, a worker in `ha-control-plane`, to keep ingress off apiserver nodes in HA). If you touch either file, keep the label and the nodeSelector in sync — that's what makes ingress actually reachable rather than just "not wrong."

**`metrics-server.yaml` carries `--kubelet-insecure-tls`, which would be wrong outside this lab.** kind's kubelet serving certs are self-signed without a SAN metrics-server accepts; this flag is a kind-specific workaround documented in the manifest's header comment, not something to copy into a real-cluster metrics-server config.

**HA control plane uses kind's Envoy load balancer**, not HAProxy (kind switched in a recent release — verify against current kind release notes if this matters again, don't assume). It runs as a separate Docker container (`<cluster>-external-load-balancer`) using Envoy's xDS dynamic config (`/home/envoy/cds.yaml` and `lds.yaml` inside that container, not the static `/etc/envoy/envoy.yaml` which is unused leftover from the base image) listing all control-plane nodes as health-checked backends. kubeconfig's `server:` field points at this container, not at any individual apiserver.

**Storage is kind's default `local-path-provisioner` only** — hostPath-backed, no ReadWriteMany, no replication. See DESIGN.md if this needs to change; the intended replacement path is an NFS-backed provisioner added as an explicit manifest under a new `manifests/storage/`, following the same pattern as everything else here.
