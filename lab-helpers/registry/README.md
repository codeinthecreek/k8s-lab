# registry lab helper

Lab-only infrastructure for tutorial chapter 12 (source code -> running
Kubernetes workload). Not part of normal `make up` - see the top-level
README's "Lab helpers" section for how this fits into the rest of the
repo.

A real `registry:3` image registry container, attached to the `kind`
Docker network so cluster nodes can pull from it, and with its port also
published on the Docker host so `docker build`/`tag`/`push` from outside
the cluster can reach it too - the same shape as kind's own
[local-registry docs](https://kind.sigs.k8s.io/docs/user/local-registry/),
adapted to this repo's Makefile-driven helper pattern.

## Usage

From the repo root:

```
make registry-up                              # start the registry container
make registry-client-install PROFILE=default   # wire up containerd on that profile's nodes
make registry-status                           # confirm it's running + list pushed repositories
make registry-down                             # stop and remove the container (data/ persists)
```

`registry-up` is profile-independent, same as `nfs-up` - one registry
container, shared across whichever profile you're using. `registry-up`
does **not** require a kind cluster to already exist (unlike `nfs-up`):
the registry container starts on the `bridge` network first and only joins
`kind` once `registry-client-install` runs and finds that network.

Build, tag, and push an image against it exactly as kind's docs describe:

```
docker build -t myapp:v1 .
docker tag myapp:v1 localhost:5001/myapp:v1
docker push localhost:5001/myapp:v1
```

Then reference `localhost:5001/myapp:v1` directly in a Pod/Deployment
spec's `image:` field - see `docs/tutorial/12-app-deployment.md` and
`tutorial/examples/app-deployment/` for a full worked example.

## Why this needs a cluster.yaml change, unlike nfs-server

Reaching `localhost:5001` from *inside* a node container and having that
actually mean "the registry container, not the node's own loopback"
requires containerd to be configured with `config_path =
"/etc/containerd/certs.d"` - and that can only be set via
`containerdConfigPatches` at `kind create cluster` time, not added to an
already-running node the way `nfs-client-install` installs a package
after the fact. All three of this repo's profiles carry that patch - see
`DESIGN.md`'s "Local registry: containerd config_path patch" section for
the full reasoning, including a real surprise: kind's own docs say this
patch is unnecessary on node images from kind v0.27.0+, which turned out
not to be true for this repo's pinned `kindest/node:v1.36.1` image.

`registry-client-install PROFILE=x` does the rest: writes
`/etc/containerd/certs.d/localhost:5001/hosts.toml` on every node of that
profile (pointing at the registry container by Docker name,
`k8s-lab-registry:5000`) and connects the registry container to the
`kind` network if it isn't already. Like `nfs-client-install`, this has to
be re-run any time that profile's nodes are recreated (`make reset`, or
`down` then `up`) - node containers are ephemeral and don't retain
`/etc/containerd/certs.d` contents across recreation, even though the
`cluster.yaml` patch that makes `config_path` itself work is baked in from
creation.

## imagePullPolicy still matters

Wiring up the registry doesn't make `imagePullPolicy` irrelevant - see
`docs/tutorial/12-app-deployment.md` for two real demonstrated failure
modes: `Always` against an image that was only ever `kind load
docker-image`-d (never actually pushed anywhere) fails outright even
though the bits are already on the node, and `IfNotPresent` against a
locally-built image silently keeps serving old code after a rebuild that
reused the same tag, on every node that already had that tag cached.

## data/

`data/` is created on first `make registry-up` and bind-mounted into the
registry container as its backing store (`/var/lib/registry`), so pushed
images survive a `make registry-down` / `make registry-up` cycle.
