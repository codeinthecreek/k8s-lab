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
  +----------------------------------------------------------------+
  |  "kind" bridge network                                         |
  |                                                                 |
  |  +---------------------------+   +---------------------------+ |
  |  | control-plane container   |   | worker container          | |
  |  |---------------------------|   |---------------------------| |
  |  | containerd                |   | containerd                | |
  |  | kubelet                   |   | kubelet                   | |
  |  | kube-apiserver     <------+---+--- published to host       | |
  |  | etcd                      |   | kube-proxy                | |
  |  | kube-scheduler            |   | (pods scheduled here)      | |
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
make status
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

Profiles are independent clusters (`k8s-lab-<profile>`) and their cluster
API ports don't conflict, so they can generally run side by side. **Both
current profiles are the exception**, though: each publishes host ports
80/443 for ingress-nginx (`default` on its control-plane node,
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
ingress to different host ports, but neither profile here does.

Available profiles:

| Profile           | Topology                        | Notes |
|--------------------|----------------------------------|-------|
| `default`          | 1 control-plane + 2 workers      | kindnetd CNI |
| `ha-control-plane`  | 3 control-plane + 2 workers      | kindnetd CNI; Envoy load-balances the 3 apiservers |

Run `make list-profiles` to list them from the filesystem directly.

## Makefile targets

| Target                       | Does |
|-------------------------------|------|
| `make up PROFILE=x`           | `kind create cluster` with the profile's `cluster.yaml`, then `kubectl apply -f` each path in the profile's `manifests.txt`, in order |
| `make down PROFILE=x`         | `kind delete cluster` for that profile |
| `make reset PROFILE=x`        | `down` then `up` |
| `make list-profiles`          | List `kind/profiles/*` |
| `make kubeconfig PROFILE=x`   | `kind export kubeconfig` for that profile |
| `make status PROFILE=x`       | `kubectl get nodes -o wide` and `get pods -A` against that profile's context |

`PROFILE` defaults to `default` if omitted.

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

See DESIGN.md's "kindnetd stays the default CNI" section for a concrete
worked example (adding a `calico` profile using the already-staged
`manifests/cni/calico.yaml`).

## Repo layout

```
DESIGN.md                      architecture decisions and rationale
docs/findings.md                running log of issues hit and fixes
kind/profiles/<name>/
  cluster.yaml                  kind cluster config for this profile
  manifests.txt                 ordered list of manifest paths to apply
manifests/
  cni/calico.yaml                staged, not applied by any profile yet
  ingress/ingress-nginx.yaml      kind hostPort variant, applied by both profiles
  metrics/metrics-server.yaml     applied by both profiles
Makefile
```
