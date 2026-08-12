# Design

This is a kind-based (kubernetes-sigs/kind) Kubernetes lab. This document
records the decisions that shape the repo and why they were made, so future
changes can be checked against the original reasoning instead of guessed at.

## Why kind, not k3d or minikube

kind runs unmodified upstream Kubernetes components (kubeadm, kubelet,
etcd, etc.) inside Docker containers acting as nodes. k3d wraps k3s, which
strips and replaces pieces of the control plane (its own lightweight
storage backend option, a bundled `traefik`, a bundled `servicelb`) - useful
for footprint, bad for a lab whose point is to see stock Kubernetes
behavior. minikube optimizes for a single-VM, single-node developer
experience with a large addon surface. kind's node-as-container model is
also what makes multi-control-plane topologies (see `ha-control-plane`
below) cheap to spin up locally.

## Why profiles are plain files, not one templated config

The alternative to `kind/profiles/<name>/` would be a single
`cluster.yaml.tmpl` plus a values file (Helm-style, or envsubst, or a
Makefile full of `sed`). That was deliberately rejected:

- **A template hides the actual applied config.** With a template you're
  reading interpolation syntax, not Kubernetes/kind config; you have to
  mentally render it (or actually render it) to know what will really run.
  A plain `cluster.yaml` per profile *is* what gets applied - `cat` shows
  you the truth.
- **Diffing two profiles by eye is the primary way you'll understand what
  "HA control plane" actually changes.** `diff kind/profiles/default/cluster.yaml
  kind/profiles/ha-control-plane/cluster.yaml` shows exactly the node
  topology change and nothing else, because both files are line-for-line
  comparable. A templated config with conditionals doesn't diff cleanly -
  you'd be diffing template logic, not outcomes.
- **Templating variables invites templating variables for things that
  shouldn't vary per-run** (image tags becoming `{{ .NodeImage }}` "for
  convenience," silently drifting from the pinned, tested digest). Plain
  files make every value a conscious, visible edit.

The cost is duplication - both profiles repeat the same node image digest,
the same `networking.disableDefaultCNI: false`. That's accepted on purpose:
duplication here is legible, and there are only two profiles today. If a
third or fourth profile makes the duplication genuinely painful, revisit
this - but don't preemptively solve a problem two files don't have.

## Why every add-on is an explicit applied manifest, not a toggle

kind (and other local Kubernetes tools) increasingly offer "just turn on
ingress" style flags/addons. This repo avoids that everywhere except the
default CNI: every non-core-control-plane component - ingress controller,
metrics-server, and (staged, unused) Calico - is a real manifest file under
`manifests/`, referenced by explicit path from a profile's
`manifests.txt`, applied with a plain `kubectl apply -f`. There is no
addon system, no "enable: true" flag, no version resolved at apply-time.

The reasons:

- An addon flag resolves *some* version of *some* manifest at cluster
  creation time, and that resolution logic lives in kind's (or another
  tool's) code, not in this repo. You can't `git diff` a version bump,
  can't pin to a digest you've actually tested, and can't see what will be
  applied without running it.
- `manifests.txt` is deliberately a flat ordered list of paths, not YAML,
  not a Kustomize `resources:` list. It has no syntax to hide behind - to
  understand what a profile installs, read one small text file top to
  bottom.
- Every manifest in `manifests/` carries a header comment recording where
  it came from (upstream URL + pinned tag/release) and every deliberate
  change made to the upstream version. Nothing is silently patched.

## kindnetd stays the default CNI (for now)

Both profiles set `networking.disableDefaultCNI: false` explicitly in
`cluster.yaml` - not by omitting the field (which defaults to the same
value), but by writing it out, so it's a visible decision rather than
something you'd have to know kind's default to notice.

`manifests/cni/calico.yaml` (Calico v3.32.1, fetched verbatim from
`https://raw.githubusercontent.com/projectcalico/calico/v3.32.1/manifests/calico.yaml`)
is staged in the repo but **not referenced by either profile's
`manifests.txt`**. It exists so that adding a `calico` profile later is a
small, mechanical change rather than a research project. To add it
yourself:

1. `cp -r kind/profiles/default kind/profiles/calico`
2. In `kind/profiles/calico/cluster.yaml`, flip `disableDefaultCNI: false`
   to `true`. kindnetd will no longer be installed, so nodes stay
   `NotReady` until a CNI is applied.
3. In `kind/profiles/calico/manifests.txt`, add
   `manifests/cni/calico.yaml` as the **first** line - it must be applied
   and nodes must go `Ready` before ingress-nginx or metrics-server pods
   can schedule.
4. `make up PROFILE=calico`.

Nothing in the Makefile or the other profiles needs to change - that's the
point of the profile-per-directory layout.

## HA control plane and the Envoy load balancer

`kind/profiles/ha-control-plane/cluster.yaml` runs 3 control-plane nodes +
2 workers, same pinned node image as `default`. With more than one
control-plane node, kind stands up an additional Docker container running
Envoy (as of kind v0.32.0 - this replaced an older HAProxy-based load
balancer in earlier kind versions) in front of the kube-apiservers. The
kubeconfig `server:` field and every control-plane node's own kubeadm join
process point at that Envoy container, not at any individual apiserver.
See `kind/profiles/ha-control-plane/cluster.yaml`'s header comment and the
walkthrough in this repo's chat history / README for what to check if a
control-plane node fails to join.

## Ingress: hostPort + node pinning, not a cloud LoadBalancer

`manifests/ingress/ingress-nginx.yaml` is the ingress-nginx kind-provider
variant (controller-v1.15.1) fetched verbatim from upstream, with one
deliberate change layered on top: an `ingress-ready: "true"` nodeSelector
added back onto the controller pod spec. As fetched, upstream's kind
`deploy.yaml` no longer sets that selector itself (it did in earlier
releases) - without it, the controller Deployment (`replicas: 1`, no anti-
affinity) can be scheduled by Kubernetes onto any node with
`kubernetes.io/os: linux`, including a worker whose Docker container has no
host port mapping, silently breaking `curl localhost:80`. Both profiles'
`cluster.yaml` label exactly one node `ingress-ready=true` and give that
node's container `extraPortMappings` for 80/443, so the pod has exactly one
place it can land that actually works.

- `default`: the label and port mapping are on the single control-plane
  node - there's only one "special" node in that topology anyway.
- `ha-control-plane`: the label and port mapping are on the first worker
  node instead, keeping the ingress controller off the apiserver nodes.

## metrics-server and `--kubelet-insecure-tls`

`manifests/metrics/metrics-server.yaml` (v0.9.0) is rendered from
upstream's kustomize overlay (`manifests/overlays/release`) rather than a
flat file, because upstream stopped publishing a single `components.yaml`
in this release layout. Rendered with:

```
kubectl kustomize "https://github.com/kubernetes-sigs/metrics-server/manifests/overlays/release?ref=v0.9.0"
```

One deliberate change on top: `--kubelet-insecure-tls` added to the
container args. kind's kubelet serving certificates are self-signed and
don't carry a SAN metrics-server will accept, so every kubelet scrape
fails TLS verification without this flag and `kubectl top` silently
returns nothing. There is no real per-node cert-rotation path available on
a kind cluster to fix this the "correct" way, so insecure verification is
the accepted tradeoff for a local lab specifically - this flag should not
be carried into a real cluster's metrics-server config.

## Storage: kind's default local-path-provisioner, nothing more

Neither profile installs a StorageClass. kind ships a `standard`
StorageClass backed by `rancher.io/local-path` (the local-path-provisioner
that runs as part of kind itself) and marks it default automatically -
that's left as-is. It is **hostPath-backed on a single node**: a PVC's
data lives on whichever node's container filesystem the pod happened to
land on, there is no replication, and it cannot be mounted
`ReadWriteMany`. That's fine for this lab's current scope (single-pod
workloads, throwaway state). If this grows to need multi-pod shared
storage or real ReadWriteMany semantics, local-path-provisioner is the
piece that needs to be replaced - with an NFS-backed provisioner
(`nfs-subdir-external-provisioner` or similar) pointed at a real or
container-hosted NFS export, added the same way everything else here is:
as an explicit manifest under `manifests/storage/`, referenced from
`manifests.txt`.

## Node image pinning

Both profiles pin `kindest/node` by tag **and** sha256 digest
(`kindest/node:v1.36.1@sha256:3489c7674813ba5d8b1a9977baea8a6e553784dab7b84759d1014dbd78f7ebd5`),
taken from the kind v0.32.0 release notes
(https://github.com/kubernetes-sigs/kind/releases/tag/v0.32.0). kind's own
docs are explicit that the tag alone is not reproducible - the same tag
can point at different image content across kind versions/builds - so the
digest is the actual pin. When bumping this, update the digest in both
profiles' `cluster.yaml` in the same commit so they never silently diverge
onto different node images.
