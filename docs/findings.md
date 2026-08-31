# Findings

Running log of problems hit while building/operating this lab and what
fixed them. Newest entries at the top. Not a changelog of features -
`git log` covers that. This is for things that cost time figuring out.

## 2026-08-30 - kind's "config_path patch not needed on kind v0.27.0+ images" doesn't hold for this repo's pinned image

While building the tutorial's developer-journey chapter
(`docs/tutorial/13-app-deployment.md`) around a real local registry
(`lab-helpers/registry`), started from kind's own
`kind-with-registry.sh` example, which includes a `containerdConfigPatches`
block setting `[plugins."io.containerd.grpc.v1.cri".registry] config_path
= "/etc/containerd/certs.d"` - with a comment saying it's "not necessary
with images from kind v0.27.0+."

Checked directly rather than trusting the comment: created a `default`
profile cluster from this repo's existing `cluster.yaml` (no such patch at
the time) and ran `docker exec <node> cat /etc/containerd/config.toml` on
a live node. No `[plugins."io.containerd.grpc.v1.cri".registry]` block
existed at all - `config_path` was unset, so a `hosts.toml` written under
`/etc/containerd/certs.d/` would have been silently ignored. This repo's
pinned node image is `kindest/node:v1.36.1`, built well after kind
v0.27.0, so the "newer images don't need this" claim doesn't hold for it.

Added the patch to all three profiles' `cluster.yaml` (see DESIGN.md's
"Local registry: containerd config_path patch"), recreated the cluster,
and confirmed `config_path` was present in `config.toml` afterward -
registry pulls only started working once that was in place. Lesson: a
"not necessary as of version X" claim in someone else's example script is
a claim about *their* tested image, not a guarantee about any node image
tagged after version X - verify against `/etc/containerd/config.toml` on
an actual node rather than assuming the comment still applies.

## 2026-08-30 - imagePullPolicy: Always fails outright against a `kind load docker-image`-only image, even though the bits are already on the node

While demonstrating imagePullPolicy failure modes for the same chapter:
built `app-deployment-demo:v1` locally, loaded it into the `default`
profile with `kind load docker-image` (no registry involved), then ran a
Pod referencing that image with `imagePullPolicy: Always`. Expected it to
either work (image's already there) or behave like a plain "not found"
- instead it failed with `ErrImagePull`/`ImagePullBackOff`:

```
Failed to pull image "app-deployment-demo:v1": failed to pull and unpack
image "docker.io/library/app-deployment-demo:v1": failed to resolve
reference "docker.io/library/app-deployment-demo:v1": pull access denied,
repository does not exist or may require authorization: server message:
insufficient_scope: authorization failed
```

`Always` doesn't fall back to an already-present local image if the
registry check itself fails - and an unqualified image name defaults to
`docker.io/library/<name>`, a real registry that has no idea this image
exists, regardless of what `kind load docker-image` already put in
containerd's local content store on every node. `IfNotPresent` against
the identical locally-loaded image works fine (no pull attempted at all).
This is exactly why `lab-helpers/registry` (a real registry the node
actually pulls from) exists as this tutorial's answer for testing
`imagePullPolicy: Always` against a self-built image, rather than `kind
load docker-image` - see `docs/tutorial/13-app-deployment.md`.

Separately, and worth knowing if the "already present" messaging looks
inconsistent across nodes: `kind load docker-image` deduplicates by image
ID/digest across the *entire* node, not per-tag - a node that had already
pulled `localhost:5001/app-deployment-demo:v1` (same layers, different
tag) reported the `docker.io/library/...`-tagged load as "already present
... re-tagging" instead of transferring anything, while nodes without that
digest cached did a real load. Not a bug, just containerd's content-
addressed storage doing what it's designed to do - but confusing if you
expect `kind load`'s output to be identical across every node every time.

## 2026-08-28 - kindnetd now enforces NetworkPolicy - "kindnet doesn't enforce it" is no longer a safe assumption

While writing the tutorial's security chapter (`docs/tutorial/09-security.md`),
applied a NetworkPolicy on the `default` profile expecting kindnetd to
silently ignore it (the API accepts a NetworkPolicy object regardless of
whether any CNI enforces it - only genuinely testing traffic proves
anything either way). A Pod deliberately excluded by the policy's
`podSelector` was actually blocked - real, reproducible enforcement, not a
fluke: toggled the policy off/on twice against the same two Pods and got
consistent allow/block results both times.

This directly contradicted this repo's own `DESIGN.md`, which stated
kindnetd doesn't enforce NetworkPolicy as the reason the `calico` profile
exists. Confirmed the actual mechanism via kindnet's own pod logs on
`default`:

```
kubectl logs -n kube-system <a-kindnet-pod> | grep -i "network-polic"
"Starting controller" name="kube-network-policies"
"Policy engine is ready."
"Syncing nftables rules" logger="nftables-sync"
```

kindnetd has gained an embedded, nftables-based enforcer (the
upstream `kube-network-policies` project) at some point since this repo's
"kindnetd doesn't enforce NetworkPolicy" reasoning was written - the node
image is digest-pinned (`kindest/node:v1.36.1`) and hasn't changed, so
this is real upstream drift baked into that pinned image's bundled
kindnetd, not a fluke of this specific test run or a locally-cached image
mismatch (`imagePullPolicy: IfNotPresent`, image build date confirmed via
`crictl inspecti` as `2026-05-28`, well before this was first hit).

Lesson: don't assume a CNI's NetworkPolicy support (or lack of it) without
checking `kubectl logs` on its node-agent Pods, or better, an actual
allow/block test with two real Pods - "kindnetd is minimal and doesn't do
NetworkPolicy" was accurate for a long time and still appears in plenty of
current material, but it stopped being true for this repo's pinned image
without any change on this repo's side. See `DESIGN.md`'s "kindnetd stays
the default CNI" section for the corrected reasoning.

## 2026-08-24 - ImagePullBackOff on kube-webhook-certgen was a host DNS problem, not a manifest problem

While restoring the vendored ingress-nginx manifest after a Helm-based
exercise, the `kube-webhook-certgen` Job pod sat in `ImagePullBackOff`.
`kubectl describe pod` showed:

```
failed to resolve reference "<registry>/<image>@sha256:...":
failed to do request: Head "https://<mirror-domain>/...":
dial tcp: lookup <mirror-domain> on <docker-embedded-resolver>:53: server misbehaving
```

Not a bad manifest or a bad digest - the host's DNS resolver was failing to
resolve the image registry's domain, and Docker's embedded resolver just
surfaces that as `server misbehaving`. Confirmed by resolving the same
domain directly on the host and seeing it also fail there, independent of
Docker/kind entirely.

Fix: restarted the host's DNS resolver service, confirmed the domain
resolved again, then `kubectl delete pod ...` on the stuck pod so the Job
controller retried immediately instead of waiting out kubelet's image-pull
backoff.

If you hit `ImagePullBackOff` with a `server misbehaving` DNS error during
`make up` or a manifest re-apply, check host DNS resolution for the image
registry's domain before assuming the manifest or digest is wrong.

## 2026-08-21 - itsthenetwork/nfs-server-alpine is NFSv4-only, so showmount can never work against it

Built `lab-helpers/nfs-server/` (NFS-backed PV/PVC lab helper) around
`itsthenetwork/nfs-server-alpine`. Tried `showmount -e` against it as a
"confirm the export list" check and got `clnt_create: RPC: Program not
registered` even though the container logs said `Startup successful` and
`exportfs -v` showed the export correctly. `rpcinfo -p <container-ip>`
confirmed why: only `100000` (portmapper) and `100003 vers 4` (nfs) are
registered - no `100005` (mountd/MOUNT protocol). `docker exec ... ps aux`
showed why: `rpc.mountd --no-udp --no-nfs-version 2 --no-nfs-version 3` -
this image runs NFSv4-only by default, and NFSv4 doesn't use the separate
MOUNT protocol at all (it's folded into the main NFS protocol via the
`fsid=0` pseudo-root). `showmount` only ever speaks MOUNT protocol, so it
can't list exports here regardless of server health - not a timing issue,
not fixable by waiting longer or retrying.

Separately: `showmount -e k8s-lab-nfs-server` (by container name) also
fails on its own, independent of the above - Docker's embedded DNS only
resolves container names *between* containers on the same user-defined
network, not from the host. Had to resolve the container's IP via `docker
inspect ... NetworkSettings.Networks` and use that instead. The container
name works fine as the NFS server address from *inside* other containers
on the `kind` network (e.g. `mount -t nfs k8s-lab-nfs-server:/ ...` from a
kind node), just not from the host shell.

Fix: `make nfs-status` uses the container's IP (not name) for `showmount`,
and treats a `showmount` failure as expected/non-fatal, printing an
explanation instead of a bare RPC error. The actual verification that
matters is a real `mount -t nfs k8s-lab-nfs-server:/ ...` from a node
container (documented in `lab-helpers/nfs-server/README.md`), not
`showmount`.

## 2026-08-13 - ha-control-plane's ingress-nginx takes noticeably longer to become Ready than default's

Re-ran the manual verification in `docs/testing.md` for both profiles back
to back (full run: ~13.5 minutes). On `default`, ingress-nginx's controller
pod was already `1/1 Running` by the time it got checked - no extra
waiting needed beyond the manifests being applied. On `ha-control-plane`,
`kubectl wait --for=condition=ready` on that same pod timed out at 120s,
and `kubectl describe pod` showed:

```
Warning  FailedMount  74s (x7 over 106s)  kubelet  MountVolume.SetUp failed for volume "webhook-cert" : secret "ingress-nginx-admission" not found
```

Not a bug - this is startup ordering, not a broken manifest. The
controller Deployment's pod spec mounts a Secret
(`ingress-nginx-admission`) that only exists once the
`ingress-nginx-admission-create`/`-patch` Jobs finish running, so the
`FailedMount` events are expected right up until those Jobs complete; only
after that does the controller pod even start pulling its own image. It
resolves on its own - a longer `kubectl wait` timeout (120s was enough)
or just re-checking after a minute is all that's needed, not any config
change.

Rough timing observed, for budgeting future test runs (varies by machine
and Docker image cache state - these numbers assume a warm cache):

- `default`: kind reports control-plane `Ready` in ~20-30s; `make up`
  itself takes a bit longer than that (image checks, `Preparing nodes`);
  ingress-nginx needs no extra wait on top. Teardown: well under 30s.
- `ha-control-plane`: kind reports the first control-plane node `Ready` in
  ~1-1.5min, but joining the other 2 control-plane nodes + LB container +
  2 workers means `make up` takes noticeably longer than `default`'s
  single-node case to actually return. ingress-nginx then needs another
  ~1-2 minutes on top of that for the `FailedMount`/image-pull sequencing
  above. Teardown: still well under 30s.

Budget at least 10-15 minutes to run through both profiles in
`docs/testing.md`, more on a fully cold image cache (first-ever run, or
after `docker system prune`).

## 2026-08-12 - default and ha-control-plane can't run at the same time

Brought up `default`, verified it end-to-end (nodes Ready, ingress
reachable through hostPort 80, `kubectl top` working), left it running,
then tried `make up PROFILE=ha-control-plane`. It failed partway through
node creation:

```
docker: Error response from daemon: failed to set up container networking:
driver failed programming external connectivity on endpoint
k8s-lab-ha-control-plane-worker: Bind for 0.0.0.0:80 failed: port is
already allocated
```

Both profiles' `cluster.yaml` publish host ports 80/443 for the
ingress-nginx `extraPortMappings` (default: on the control-plane node;
ha-control-plane: on the worker node - see DESIGN.md). Those are real
Docker `-p 80:80` bindings on the host, and only one container anywhere
can hold a given host port. Cluster *names* and API server ports don't
collide between profiles (each gets its own randomly-assigned host port
for 6443/the Envoy LB), but the ingress hostPorts do, unconditionally.

Fix used: `make down PROFILE=default` before bringing up
`ha-control-plane`. There's no config change that fixes this while keeping
both profiles' ingress on 80/443 - the real fix, if running both
simultaneously together ever becomes a real need, would be to give one
profile different host ports in its `extraPortMappings` (e.g. 8080/8443)
and document that its ingress lives at a different URL. Not done here
since it wasn't asked for and adds a profile-specific special case.
Verified against a real `kind create cluster` failure, not inferred -
README's "profiles run side by side" claim has been corrected to call out
this exception.

## 2026-08-12 - metrics-server no longer ships a flat `components.yaml`

Went to fetch
`https://raw.githubusercontent.com/kubernetes-sigs/metrics-server/v0.9.0/deploy/kubernetes/components.yaml`
(the well-known single-file install manifest) and got a 404. As of v0.9.0
the repo moved to a kustomize layout under `manifests/base` +
`manifests/overlays/*`, with no equivalent flat file committed anywhere in
the repo.

Fix: rendered it locally with kubectl's built-in kustomize support instead
of hand-assembling it:

```
kubectl kustomize "https://github.com/kubernetes-sigs/metrics-server/manifests/overlays/release?ref=v0.9.0" > manifests/metrics/metrics-server.yaml
```

then added `--kubelet-insecure-tls` on top. If metrics-server bumps again,
re-render with the new tag rather than hand-editing the existing file, to
avoid drifting from what upstream's overlay actually produces.

## 2026-08-12 - ingress-nginx's kind manifest no longer self-selects a node

Expected upstream's kind-provider `deploy.yaml` to include a
`nodeSelector: {ingress-ready: "true"}` on the controller pod spec (this
was standard in earlier kind ingress guides). Checked the actual fetched
file at controller-v1.15.1 and it isn't there - only
`kubernetes.io/os: linux`. The Deployment is `replicas: 1` with no anti-
affinity, so without a selector pinning it to the node with the
`extraPortMappings`, the scheduler is free to place it on a worker with no
80/443 published to the Docker host, and `curl localhost` would just hang
with nothing listening.

Fix: added the `ingress-ready: "true"` nodeSelector back manually in
`manifests/ingress/ingress-nginx.yaml`, and label the intended node
`ingress-ready=true` via `kubeadmConfigPatches` in each profile's
`cluster.yaml`. See `DESIGN.md`'s ingress section for which node gets the
label in each profile. If this trips you up after `make up`: run
`kubectl get pods -n ingress-nginx -o wide` and check the pod actually
landed on the node with the port mapping (`docker ps` shows published
ports per kind node container).

## 2026-08-12 - digests are too long to trust a summarized fetch

While pulling the kind node image digest, an initial summarized fetch of
the release page and a follow-up raw fetch of the same release body (via
`curl .../releases/latest | jq -r .body`) needed to be cross-checked
character-for-character before being trusted in `cluster.yaml` - a
summarization pass over a 64-hex-char string is exactly the kind of value
that can get silently mangled without looking wrong. Whatever fetches a
digest next time (Calico, a metrics-server bump, a different node image)
should pull it from a raw/API source and diff it against the summarized
version rather than taking either alone.
