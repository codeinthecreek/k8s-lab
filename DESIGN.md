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

One caveat to "independent, run whichever you want": today's two profiles
are *not* independent at runtime, because both publish the same fixed host
ports for ingress - see "Ingress: hostPort + node pinning" below for why,
and `docs/findings.md` for what hitting that looks like in practice.

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

The one thing `manifests.txt` does *not* cover, and can't: `kind create
cluster` itself applies kindnetd (when `disableDefaultCNI: false`),
CoreDNS, kube-proxy, and the `local-path-provisioner` + default
`StorageClass` as part of cluster creation, before the Makefile ever reads
a profile's `manifests.txt`. Those are kind's own bundled behavior, not
something this repo controls without disabling and replacing them
outright (which is exactly what the staged-but-unused
`manifests/cni/calico.yaml` is for, on the CNI side - see below). Every
profile's `make up` also passes `--wait 5m` to `kind create cluster`, so
it blocks until node(s) report `Ready` (which requires the CNI to actually
be up) before the Makefile starts applying `manifests.txt` - without that,
`kubectl apply` could race ahead of a cluster where nothing can schedule
yet, which matters even more for a future CNI-swapped profile than it
does here.

## kindnetd stays the default CNI on default and ha-control-plane

`default` and `ha-control-plane` both set `networking.disableDefaultCNI: false`
explicitly in `cluster.yaml` - not by omitting the field (which defaults to
the same value), but by writing it out, so it's a visible decision rather
than something you'd have to know kind's default to notice.

`kind/profiles/calico/` swaps kindnetd for Calico (`manifests/cni/calico.yaml`,
v3.32.1, fetched verbatim from
`https://raw.githubusercontent.com/projectcalico/calico/v3.32.1/manifests/calico.yaml`)
because kindnetd did not enforce NetworkPolicy - it was needed at the
time to test and demonstrate real NetworkPolicy enforcement at all. That
was the correct call when this profile was built, on the node image
pinned then.

**Correction (2026-08-28):** that reasoning is now out of date, not
wrong for its time. kindnetd on `kindest/node:v1.36.1` and later
enforces NetworkPolicy via an embedded, nftables-based
`kube-network-policies` controller - verified live on the `default`
profile: a NetworkPolicy that should block cross-Pod traffic genuinely
blocked it, and kindnet's own pod logs show `"Starting controller"
name="kube-network-policies"` and `"Policy engine is ready."` (see
`docs/tutorial/08-security.md` and `docs/findings.md`'s 2026-08-28 entry
for how this was found). This was not always true, and most current
material - including Kubernetes' own docs pages - still states kindnetd
doesn't enforce NetworkPolicy, because they haven't caught up to it
either. **If reusing an older or different node image, re-verify** by
checking kindnet's pod logs for that `kube-network-policies` controller
line before assuming either way.

Given that, `calico` is kept for a narrower set of reasons than
originally stated: (a) demonstrating a real CNI swap mechanically, not
tied to NetworkPolicy specifically; (b) Calico's own behavior - IPAM,
`IPPool` resources, its health-check model - is independently worth
having a live example of; (c) a fallback for anyone pinning an older or
different node image where kindnet's enforcement isn't present. It is
no longer "the only way to test NetworkPolicy here." It was added by
following the same mechanical steps documented here, in case another
CNI-swapped profile is needed later:

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
2 workers, same pinned node image as `default`. Control-plane nodes use
**stacked etcd** - each of the 3 control-plane containers runs its own
etcd member alongside its own apiserver/controller-manager/scheduler,
rather than etcd living on separate dedicated nodes. With more than one
control-plane node, kind also stands up an additional Docker container
(`<cluster-name>-external-load-balancer`) running Envoy (as of kind
v0.32.0 - this replaced an older HAProxy-based load balancer in earlier
kind versions) in front of the kube-apiservers. The kubeconfig `server:`
field and every control-plane node's own kubeadm join process point at
that Envoy container, not at any individual apiserver.

Verified against a real cluster: Envoy's actual routing config is **not**
the static `/etc/envoy/envoy.yaml` inside that container - that file is
unused leftover from the base image (it's Envoy's stock demo config,
routing to `www.envoyproxy.io`). The config kind actually runs is dynamic
xDS resources the entrypoint script generates at container start:
`/home/envoy/cds.yaml` (a `kube_apiservers` cluster listing all
control-plane nodes by container hostname on port 6443, with active
`/healthz` health checks) and `/home/envoy/lds.yaml` (a TCP proxy listener
on 6443 forwarding to that cluster). If a control-plane node fails to
join:

- `docker ps` - confirm the LB container and all control-plane containers
  actually exist and are running; a node that never started won't produce
  a kubeadm error, it just won't be there.
- `docker exec <lb-container> cat /home/envoy/cds.yaml` - check whether
  the failing node is even listed as a backend, and whether Envoy has
  marked it unhealthy. (The Envoy image has no shell utilities - no
  `curl`/`wget` - so hitting its admin API from inside the container
  doesn't work; reading the generated config files directly does.)
- `docker logs <failing-cp-container>` - kind streams that node's boot and
  `kubeadm join --control-plane` output here.
- `docker exec -it <failing-cp-container> journalctl -u kubelet -f` - for
  cases where `kubeadm join` succeeded but the kubelet itself can't reach
  the endpoint or has a cert problem.
- In practice, stale bootstrap tokens/certificate-keys (which kind manages
  internally) are the most common real cause, and `make reset
  PROFILE=ha-control-plane` is the practical fix rather than debugging
  kubeadm token expiry by hand.

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

The tradeoff accepted here: both profiles publish host ports 80/443
directly on the Docker host, so **at most one ingress-enabled profile can
run at a time** - bringing up a second one fails with a real Docker "port
is already allocated" error, verified against an actual cluster (see
`docs/findings.md`). This wasn't designed around, because doing so would
mean giving one profile different host ports for ingress (e.g. 8080/8443)
and documenting a different URL per profile - a special case that isn't
worth it unless running both together becomes a real, not hypothetical,
need.

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

## Local registry: containerd config_path patch

All three profiles' `cluster.yaml` carry a top-level `containerdConfigPatches`
setting `[plugins."io.containerd.grpc.v1.cri".registry] config_path =
"/etc/containerd/certs.d"`. This is what lets `lab-helpers/registry` (a
`registry:3` container, same pattern as `lab-helpers/nfs-server` - see the
top-level README's "Lab helpers" section) act as a real image registry for
the tutorial's developer-journey chapter (`docs/tutorial/12-*.md`):
containerd on each node reads `/etc/containerd/certs.d/localhost:5001/hosts.toml`
(written by `make registry-client-install`) to redirect
`localhost:5001/<image>` pulls to the registry container over the `kind`
Docker network, the same "consistent name that works from both ends" trick
kind's own local-registry docs use.

This is a structural `cluster.yaml` change, not something bolted on after
cluster creation, because `containerdConfigPatches` only takes effect at
`kind create cluster` time - unlike `lab-helpers/nfs-server`'s client
package install, which can be redone against already-running nodes,
enabling registry config_path support requires recreating the cluster.
Applied to all three profiles for the same reason node image digests are
kept in sync across them (see "Node image pinning" below): a structural
capability like this shouldn't silently work on one profile and not
another.

**Checked directly against this repo's pinned node image, not assumed**:
kind's own `kind-with-registry.sh` example script says this patch is "not
necessary with images from kind v0.27.0+" - implying newer node images set
`config_path` themselves. That's not true for `kindest/node:v1.36.1`
(the digest pinned below): `docker exec <node> cat /etc/containerd/config.toml`
on a freshly created node showed no `[plugins."io.containerd.grpc.v1.cri".registry]`
block at all before this patch was added. Worth re-checking on a real node
again before ever removing this patch on the assumption it's now baked in
upstream.

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

## Tutorial content: structure and conventions

`docs/tutorial/` holds a from-scratch, concept-first Kubernetes tutorial -
independent of any course material, aimed at anyone with `kind` and
`kubectl` installed, not just this repo's maintainer. See
`docs/tutorial/README.md` for the chapter list and scope.

**Chapter order follows concept dependency, not an exam's domain list or
a course's lesson order.** A CKA domain breakdown or a course syllabus is
organized for assessment or curriculum-delivery reasons that don't track
what actually needs to be understood first. Storage, for instance, only
makes sense once a Pod exists to mount something into - so storage comes
after workloads here regardless of where any exam blueprint files it.

**Examples live under `tutorial/examples/<topic>/*.yaml`, referenced by
path from the prose, never pasted inline.** Same reasoning as the
profile/manifest split above: an example a reader can't independently
`kubectl apply -f` and diff against the doc's claimed output is just
prose wearing YAML syntax. Keeping them as real files also means they can
be linted/applied in CI later without scraping markdown.

**Each concept section follows why, then example, then expected
output/errors, in that order.** The failure mode this avoids: leading
with YAML trains a reader to pattern-match manifests without
understanding what problem the fields solve, which is exactly the
exam-prep checklist style this tutorial is deliberately not.

**Version-current framing.** Every chapter states what's true for the
Kubernetes version this repo's `kind` profiles currently pin (see "Node
image pinning" above), not as a timeless fact. Anything that changed
recently or is likely to change again gets flagged inline (e.g. "as of
1.24, ..."), the same way this document already flags e.g. Envoy
replacing HAProxy as kind's load balancer. A tutorial that states
version-specific behavior as eternal truth is how stale material like
"Initializers" outlives its own removal by years.

**No exam-prep artifacts.** No domain-percentage tables, no practice
questions, no "exam tip" callouts. If a concept is CKA-relevant, it's
included because it's a concept a working admin needs, not because a
blueprint says so.
