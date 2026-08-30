# k8s-lab

A reproducible kind (kubernetes-sigs/kind) Kubernetes lab. See
[DESIGN.md](DESIGN.md) for why it's built the way it is - plain per-profile
config files instead of a templated one, and every add-on (ingress,
metrics, CNI swap) as an explicit manifest instead of a bundled toggle.

## Architecture

```
Workstation (Linux)
==========================================================================
  kind (CLI)          kubectl (CLI)         repo: k8s-lab/
     |                     |                   kind/profiles/<name>/cluster.yaml
     | Docker API          | kubeconfig          -> ~/.kube/config
     | (create/destroy)    | HTTPS to 127.0.0.1:<port>
     v                     v
==========================================================================
Docker daemon
  Two host boundaries get crossed here, not one:
    host <apiserver-port> -----> kube-apiserver (kind's default,
                                  one random port per cluster)
    host 80/443           -----> extraPortMappings for ingress
                                  (fixed in each profile's cluster.yaml)
  Everything else - etcd, inter-node traffic, pod-to-pod networking -
  stays inside the kind bridge network below.

  +----------------------------------------------------------------+
  |  "kind" bridge network                                         |
  |                                                                |
  |  +---------------------------+   +---------------------------+ |
  |  | control-plane container   |   | worker container          | |
  |  |---------------------------|   |---------------------------| |
  |  | containerd                |   | containerd                | |
  |  | kubelet                   |   | kubelet                   | |
  |  | kube-apiserver     <------+---+--- published to host      | |
  |  | etcd                      |   | kube-proxy                | |
  |  | kube-scheduler            |   | (pods scheduled here)     | |
  |  | kube-controller-manager   |   +---------------------------+ |
  |  | kube-proxy                |                                 |
  |  +---------------------------+                                 |
  +----------------------------------------------------------------+

  Container counts per profile (not shown above - each box is one
  container, replicated per profile):
    default:           1 control-plane container,  2 worker containers
    ha-control-plane:   3 control-plane containers (Envoy LB in front
                          of them, see DESIGN.md), 2 worker containers
==========================================================================
                    layered on top, explicit manifests
                    (kubectl apply -f, per profile's manifests.txt)

  CNI            kindnetd (default)  or  Calico (staged, not yet wired
                 pod-to-pod routing across      into a profile - see
                 node containers                DESIGN.md)

  Ingress        ingress-nginx (hostPort variant)
                 bound to the node labeled ingress-ready=true
                 host 80/443 --------> extraPortMappings in cluster.yaml
                 --------> that node's hostPort --------> Service

  Storage        local-path-provisioner (kind default)
                 PVC --------> hostPath dir inside the node container
                 (NOT real network storage - documented limitation)

  Metrics        metrics-server
                 --kubelet-insecure-tls required (kind's kubelet certs
                 aren't signed for container hostnames)
==========================================================================
```

Key relationships this makes explicit:

- **kind talks to Docker, not Kubernetes** - the top-left arrow into the
  daemon is separate from kubectl's arrow into the apiserver.
- **Each node is a full container, not a process** - containerd and kubelet
  run inside it, same as they would on a VM.
- **Two host boundaries get crossed, not one**: the apiserver port (one
  random port per cluster, kind's default) and host 80/443 via each
  profile's `extraPortMappings` for ingress. Everything else - etcd,
  inter-node traffic, pod-to-pod networking - stays inside the kind bridge
  network. Since 80/443 are fixed host ports named explicitly in each
  profile's `cluster.yaml` (unlike the auto-assigned apiserver port),
  ingress is what actually blocks two ingress-enabled profiles from running
  at once - see the port-conflict note below and [docs/findings.md](docs/findings.md).
- **Ingress traffic makes two hops**: host port -> node container's
  hostPort -> Service/Pod - worth remembering when debugging a 502 that
  "should" be a simple Service issue.
- **The four add-on rows are independent knobs** - each profile's
  `manifests.txt` picks which of these get applied, which is the whole
  point of keeping them as separate files rather than a template.

See [DESIGN.md](DESIGN.md) for the reasoning behind each of these pieces.

## Prerequisites

- [Docker](https://docs.docker.com/get-docker/) (or Podman configured as
  kind's provider) - kind runs cluster nodes as containers.
- [kind](https://kind.sigs.k8s.io/docs/user/quick-start/#installation) -
  built and tested against kind v0.32.0.
- `kubectl`.
- `make`.

## Quickstart

```
make up                       # PROFILE defaults to "default"
make status                   # auto-detects whichever profile is running
```

That creates a 1 control-plane + 2 worker cluster named
`k8s-lab-default`, then applies ingress-nginx and metrics-server against
it in the order listed in `kind/profiles/default/manifests.txt`.

To tear it down:

```
make down
```

## Running a specific profile

Every `make` target takes `PROFILE=<name>`, matching a directory under
`kind/profiles/`:

```
make up PROFILE=ha-control-plane
make status PROFILE=ha-control-plane
make down PROFILE=ha-control-plane
```

Profiles are independent clusters (`k8s-lab-<profile>`), and their cluster
API ports don't conflict with each other. **But only one can be up at a
time in practice**: every current profile also publishes host ports 80/443
for ingress-nginx (`default` and `calico` on their control-plane node,
`ha-control-plane` on a worker), and Docker will only let one container
anywhere hold a given host port. Bringing up a second one while the first
is still running fails with:

```
docker: Error response from daemon: failed to set up container networking:
... Bind for 0.0.0.0:80 failed: port is already allocated
```

`make down PROFILE=<other>` first if you hit that - see
[docs/findings.md](docs/findings.md) for how this was found and why it's
not fixed in config. A future profile could avoid the clash by mapping
ingress to different host ports, but none here do.

Available profiles:

| Profile           | Topology                        | Notes |
|--------------------|----------------------------------|-------|
| `default`          | 1 control-plane + 2 workers      | kindnetd CNI |
| `ha-control-plane`  | 3 control-plane + 2 workers      | kindnetd CNI; Envoy load-balances the 3 apiservers |
| `calico`            | 1 control-plane + 2 workers      | Calico CNI (kindnetd disabled); alternative CNI demo - kindnetd on current node images also enforces NetworkPolicy, see DESIGN.md |

Run `make list-profiles` to list them from the filesystem directly.

## Makefile targets

| Target                       | Action | If `PROFILE` is omitted |
|-------------------------------|--------|--------------------------|
| `make up PROFILE=x`           | `kind create cluster` with the profile's `cluster.yaml`, then `kubectl apply -f` each path in the profile's `manifests.txt`, in order | Uses `default` |
| `make down PROFILE=x`         | `kind delete cluster` for that profile | Uses `default` |
| `make reset PROFILE=x`        | `down` then `up` | Uses `default` |
| `make list-profiles`          | List `kind/profiles/*` | n/a - no `PROFILE` |
| `make kubeconfig PROFILE=x`   | `kind export kubeconfig` for that profile | Uses `default` |
| `make status PROFILE=x`       | `kubectl get nodes -o wide` and `get pods -A` against that profile's context (errors clearly if it isn't up) | Auto-detects whichever profile's cluster is currently running |

## Tutorial

`docs/tutorial/` is a from-scratch, concept-first Kubernetes tutorial
written directly against this repo rather than alongside it: manifest-
driven chapters use real YAML under `tutorial/examples/`, applied to one
of this repo's profiles (`default`, `ha-control-plane`, or `calico`);
command/concept-driven chapters (architecture, Helm, observability, HA)
work directly against a live cluster via `kubectl`/`docker` instead.
Every example, manifest or command, is verified against real cluster
output before being written up - nothing is written from memory.

Chapters run in concept-dependency order - architecture and the API
model first, then workloads, configuration/storage, networking,
scheduling, Helm, security, observability, CRDs, and finally
multi-control-plane HA as the capstone chapter. Each concept section
follows the same shape: why the feature exists, a runnable example, then
real expected output, including at least one instructive failure mode
where there is one.

See [docs/tutorial/README.md](docs/tutorial/README.md) for the full
chapter list, per-chapter scope, and verification status, and [DESIGN.md](DESIGN.md)'s
"Tutorial content: structure and conventions" section for the reasoning
behind how it's structured.

## Lab helpers

`lab-helpers/` holds infrastructure that supports working through this
repo's own material but isn't itself part of the reproducible lab - it's
never referenced from a profile's `manifests.txt` and never touched by
`make up`/`down`/`reset`.

`lab-helpers/nfs-server/` is a real NFS server (container, on the `kind`
Docker network), used by the tutorial's storage chapter
([docs/tutorial/04-config-storage.md](docs/tutorial/04-config-storage.md))
for its PersistentVolume/PersistentVolumeClaim examples. See
[lab-helpers/nfs-server/README.md](lab-helpers/nfs-server/README.md) for
usage and a load-bearing gotcha (the export's `fsid=0` means clients mount
at path `/`, not `/nfsshare`).

| Target                                  | Does |
|-------------------------------------------|------|
| `make nfs-up`                             | Start the NFS server container (idempotent; requires a kind cluster already up, any profile) |
| `make nfs-down`                           | Stop and remove it (`lab-helpers/nfs-server/data/` persists) |
| `make nfs-status`                         | Show the container's status and, if `showmount` is installed on the host, attempt to list exports |
| `make nfs-client-install PROFILE=x`       | Install `nfs-common` into every node container of that profile (idempotent) |

`nfs-client-install` must be re-run any time the target profile's nodes
are recreated (`make reset`, or `down` then `up`) - node containers are
ephemeral and don't retain packages installed into them after creation.

## Adding a new profile

No code changes needed - the Makefile and manifests are profile-agnostic.

1. `cp -r kind/profiles/default kind/profiles/<new-name>`
2. Edit `kind/profiles/<new-name>/cluster.yaml` - node counts, roles,
   whichever node gets `extraPortMappings`/the `ingress-ready` label if
   you're keeping ingress, `disableDefaultCNI` if you're swapping CNI.
3. Edit `kind/profiles/<new-name>/manifests.txt` - the ordered list of
   manifest paths (relative to repo root) to apply after cluster creation.
   If you disable the default CNI, a CNI manifest must be the first line,
   or nodes will stay `NotReady` and nothing else will schedule.
4. `make up PROFILE=<new-name>`.

See [DESIGN.md](DESIGN.md)'s "kindnetd stays the default CNI" section for a concrete
worked example (adding a `calico` profile using the already-staged
`manifests/cni/calico.yaml`).

## Repo layout

```
DESIGN.md                      architecture decisions and rationale
docs/findings.md                running log of issues hit and fixes
docs/testing.md                 manual verification commands
docs/tutorial/                  from-scratch Kubernetes tutorial (see docs/tutorial/README.md)
tutorial/examples/<topic>/       manifests referenced by the tutorial's manifest-driven chapters
kind/profiles/<name>/
  cluster.yaml                  kind cluster config for this profile
  manifests.txt                 ordered list of manifest paths to apply
manifests/
  cni/calico.yaml                staged, not applied by any profile yet
  ingress/ingress-nginx.yaml      kind hostPort variant, applied by both profiles
  metrics/metrics-server.yaml     applied by both profiles
lab-helpers/
  nfs-server/                    NFS server for a PV/PVC lab exercise (not part of make up)
Makefile
```
