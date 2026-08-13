# Findings

Running log of problems hit while building/operating this lab and what
fixed them. Newest entries at the top. Not a changelog of features -
`git log` covers that. This is for things that cost time figuring out.

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
