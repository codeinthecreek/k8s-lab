# k8s-lab

A reproducible kind (kubernetes-sigs/kind) Kubernetes lab. See
[DESIGN.md](DESIGN.md) for why it's built the way it is - plain per-profile
config files instead of a templated one, and every add-on (ingress,
metrics, CNI swap) as an explicit manifest instead of a bundled toggle.

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
