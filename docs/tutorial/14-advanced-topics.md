# 14. Advanced and supplementary topics

Chapters 1-13 build in concept-dependency order, each one assuming
everything before it. This chapter doesn't continue that chain - it
collects four topics that don't fit anywhere earlier for two different
reasons. Dynamic Resource Allocation reached GA late enough (Kubernetes
1.34) that no earlier chapter's "current mechanism" framing could have
included it without being written after the fact. Scheduling Profiles,
Headlamp, and krew aren't version-gated the same way, but they're
supplementary tooling and configuration surface rather than core object
model - the kind of thing worth knowing once chapters 1-13's foundation
is in place, not before it.

### From `--policy-config-file` to `KubeSchedulerConfiguration`

**Why**: chapter 7 covered every mechanism a Pod spec uses to influence
its own placement - affinity, taints, resource requests. This section
covers the other side: how the scheduler *itself* is configured, which
chapter 7 deliberately left out since it's not something a Pod manifest
touches. Older material (including some LFS258-era course content)
describes a `kind: Policy` JSON file passed via `--policy-config-file` -
that flag was deprecated as of Kubernetes v1.23 and is fully removed;
`kube-scheduler --help` on this cluster's v1.36.1 doesn't mention it at
all. The current mechanism is `KubeSchedulerConfiguration`
(`apiVersion: kubescheduler.config.k8s.io/v1`, stable since v1.25),
passed via `kube-scheduler --config <file>`, built around the
**Scheduling Profiles** model: named profiles, each running the same
12-extension-point pipeline (`queueSort`, `preFilter`, `filter`,
`postFilter`, `preScore`, `score`, `reserve`, `permit`, `preBind`,
`bind`, `postBind`, plus the `multiPoint` shorthand that wires a plugin
into several of these at once) where plugins can be added, removed, or
reconfigured. Conceptually this is the same filter-then-score pipeline
older material calls "predicates and priorities" - reorganized around a
plugin system, not a different idea. A single `kube-scheduler` process
can run more than one profile at once, each with its own name; a Pod
picks which one handles it via `spec.schedulerName` (defaulting to
`default-scheduler` if unset, which is why nothing before this chapter
ever had to mention it).

One flag worth naming before touching anything: when `--config` is set,
several other flags become dead weight rather than errors -
`kube-scheduler --help` marks `--kubeconfig`, `--kube-api-qps`, and a
handful of others as "DEPRECATED: ... ignored if a config file is
specified in --config." The client connection those flags used to
configure moves into the config file's own `clientConnection` section
instead.

**Example**: this cluster's `default` profile currently runs
`kube-scheduler` with plain flags, no `--config` at all - confirm that
first, live, before changing anything:

```
docker exec k8s-lab-default-control-plane cat /etc/kubernetes/manifests/kube-scheduler.yaml
```

**Expected output**: the static pod kubeadm generated, `command` built
entirely from individual flags:

```
    command:
    - kube-scheduler
    - --authentication-kubeconfig=/etc/kubernetes/scheduler.conf
    - --authorization-kubeconfig=/etc/kubernetes/scheduler.conf
    - --bind-address=127.0.0.1
    - --kubeconfig=/etc/kubernetes/scheduler.conf
    - --leader-elect=true
```

Wiring in a second, named profile means editing this static pod
directly, the same kind of live `docker exec` poke chapters 10-12
already use for `crictl`, `journalctl`, and `kube-apiserver --help` -
this isn't a `kubectl apply -f`, it's a change to the control-plane
node's own filesystem. `kubectl` has no verb for editing a static pod
manifest; kubelet is the only thing watching
`/etc/kubernetes/manifests/`, and it reacts to file changes there
directly.

**Before editing anything, back up the current manifest - but not into
`/etc/kubernetes/manifests/` itself.** kubelet treats every file in that
directory as a static pod definition; a backup copy left in the same
directory, carrying the same `metadata.name: kube-scheduler`, competes
with the real one for the same pod identity. (This isn't a hypothetical
caution - it's what happened once while preparing this chapter: a
backup saved as `kube-scheduler.yaml.orig-backup` inside the manifests
directory silently won a race against the intended edit, and the
scheduler kept running its original flags for several checks afterward
before `crictl inspect`'s reported container args caught the
discrepancy.)

```
docker exec k8s-lab-default-control-plane cp /etc/kubernetes/manifests/kube-scheduler.yaml /etc/kubernetes/kube-scheduler.yaml.orig-backup
```

Now stage a `KubeSchedulerConfiguration` defining a second profile,
`bin-packing-scheduler`, alongside the untouched `default-scheduler`
profile - `tutorial/examples/scheduling-profiles/scheduler-config-naive.yaml`
scores `NodeResourcesFit` with `MostAllocated` instead of the compiled-in
default (`LeastAllocated`), and changes nothing else:

```
docker cp tutorial/examples/scheduling-profiles/scheduler-config-naive.yaml k8s-lab-default-control-plane:/etc/kubernetes/scheduler-config.yaml
docker cp tutorial/examples/scheduling-profiles/kube-scheduler-static-pod.yaml k8s-lab-default-control-plane:/etc/kubernetes/manifests/kube-scheduler.yaml
```

The second file is a copy of kubeadm's own manifest with two additions:
`--config=/etc/kubernetes/scheduler-config.yaml` on the command line,
and a matching `hostPath` volume/mount for that file - everything else
(image tag, probes, the other flags) is unchanged. kubelet notices the
manifest change and restarts the static pod automatically, no `kubectl`
involved:

```
kubectl get pods -n kube-system -l component=kube-scheduler
```

**Expected output**: back to `1/1 Running` within a few seconds of the
`docker cp`:

```
NAME                                           READY   STATUS    RESTARTS   AGE
kube-scheduler-k8s-lab-default-control-plane   1/1     Running   0          9s
```

### Two profiles, one Pod field: `spec.schedulerName`

**Why**: with both profiles live in the same process, a Pod's own
`spec.schedulerName` field is what picks between them - nothing at the
cluster level routes Pods to a profile, each Pod says which one it
wants. This is the natural place to see whether `MostAllocated` actually
changes anything observable, using both workers of this repo's `default`
profile as the test bed.

**Example**: six replicas under `default-scheduler`
(`tutorial/examples/scheduling-profiles/spread-demo-deployment.yaml`,
`cpu: "1"` per replica, `schedulerName: default-scheduler`), then the
same shape under the new profile
(`tutorial/examples/scheduling-profiles/pack-demo-deployment.yaml`,
`schedulerName: bin-packing-scheduler`) - deleting the first before
applying the second so the two runs don't share the same nodes at once:

```
kubectl apply -f tutorial/examples/scheduling-profiles/spread-demo-deployment.yaml
kubectl get pods -l app=scheduling-profiles-spread-demo -o wide
```

**Expected output**: `LeastAllocated`'s usual behavior, spread evenly
across both workers:

```
NAME                                              READY   STATUS    RESTARTS   AGE   NODE
scheduling-profiles-spread-demo-5fc8d4dd6-7sbrv   1/1     Running   0          12s   k8s-lab-default-worker
scheduling-profiles-spread-demo-5fc8d4dd6-9s77d   1/1     Running   0          12s   k8s-lab-default-worker
scheduling-profiles-spread-demo-5fc8d4dd6-lbvnz   1/1     Running   0          12s   k8s-lab-default-worker2
scheduling-profiles-spread-demo-5fc8d4dd6-pkhl5   1/1     Running   0          12s   k8s-lab-default-worker2
scheduling-profiles-spread-demo-5fc8d4dd6-s6wkz   1/1     Running   0          12s   k8s-lab-default-worker2
scheduling-profiles-spread-demo-5fc8d4dd6-sq5ns   1/1     Running   0          12s   k8s-lab-default-worker
```

Three and three. Now delete it and run the bin-packing profile against
the identical shape:

```
kubectl delete -f tutorial/examples/scheduling-profiles/spread-demo-deployment.yaml
kubectl apply -f tutorial/examples/scheduling-profiles/pack-demo-deployment.yaml
kubectl get pods -l app=scheduling-profiles-pack-demo -o wide
```

**Expected output** - and this is the genuinely useful surprise, not a
mistake in the setup: still three and three, not the six-on-one-node
result `MostAllocated` alone would suggest:

```
NAME                                              READY   STATUS    RESTARTS   AGE   NODE
scheduling-profiles-pack-demo-7876b68494-44x75   1/1     Running   0          18s   k8s-lab-default-worker2
scheduling-profiles-pack-demo-7876b68494-4b7k8   1/1     Running   0          19s   k8s-lab-default-worker
scheduling-profiles-pack-demo-7876b68494-j55g2   1/1     Running   0          18s   k8s-lab-default-worker2
scheduling-profiles-pack-demo-7876b68494-l796n   1/1     Running   0          19s   k8s-lab-default-worker
scheduling-profiles-pack-demo-7876b68494-w4bmx   1/1     Running   0          18s   k8s-lab-default-worker
scheduling-profiles-pack-demo-7876b68494-w9v9c   1/1     Running   0          19s   k8s-lab-default-worker2
```

### Why the naive config didn't bin-pack: a competing default plugin

**Why**: `pluginConfig` for `NodeResourcesFit` only changes how *that
one plugin* scores a node - it doesn't touch anything else in the
profile's plugin list, and every profile still gets the rest of the
default plugin set unless something explicitly removes it. One of those
defaults, `PodTopologySpread`, applies a system-wide soft spread
constraint (`topologyKey: kubernetes.io/hostname`,
`whenUnsatisfiable: ScheduleAnyway`) to every Pod automatically, with no
`topologySpreadConstraints` needed in the Pod spec at all - and at its
default weight, it was actively outvoting `NodeResourcesFit`'s
bin-packing signal.

**Example**: dump the scheduler's own effective configuration (writing
it out on an unrelated, disposable process, not the live one) to see the
weights side by side, confirmed live against this exact cluster's
kube-scheduler v1.36.1 image:

```
docker run --rm \
  -v tutorial/examples/scheduling-profiles/scheduler-config-naive.yaml:/config.yaml:ro \
  -v <a-valid-kubeconfig>:/etc/kubernetes/scheduler.conf:ro \
  registry.k8s.io/kube-scheduler:v1.36.1 kube-scheduler --config=/config.yaml --write-config-to=/dev/stdout
```

**Expected output** (relevant excerpt from the `multiPoint.enabled`
list, three plugins with their compiled-in default weights - the third,
`DynamicResources`, is the one the DRA section below comes back to):

```
    - name: NodeResourcesFit
      weight: 1
    - name: PodTopologySpread
      weight: 2
    - name: DynamicResources
      weight: 2
```

`PodTopologySpread` outweighs `NodeResourcesFit` two to one by default -
which is exactly why the "naive" config above changed how each *node*
was scored without changing where the pods actually landed: the spread
constraint's score dominated the vote.
`tutorial/examples/scheduling-profiles/scheduler-config.yaml` fixes
this by disabling `PodTopologySpread` outright for the
`bin-packing-scheduler` profile's `score` phase (it's still active for
`default-scheduler` - this is a per-profile plugin list, not a global
one):

```
docker cp tutorial/examples/scheduling-profiles/scheduler-config.yaml k8s-lab-default-control-plane:/etc/kubernetes/scheduler-config.yaml
```

Changing the config file's *content* alone isn't enough to take effect -
`kube-scheduler` reads it once at startup, and kubelet only watches the
static pod *manifest* file, not whatever it happens to mount. Forcing a
restart means touching the manifest itself - here, a harmless label
addition works as well as any other change:

```
docker exec k8s-lab-default-control-plane sh -c "sed -i 's/tier: control-plane/tier: control-plane\n    scheduler-config-generation: \"2\"/' /etc/kubernetes/manifests/kube-scheduler.yaml"
kubectl delete -f tutorial/examples/scheduling-profiles/pack-demo-deployment.yaml
kubectl apply -f tutorial/examples/scheduling-profiles/pack-demo-deployment.yaml
kubectl get pods -l app=scheduling-profiles-pack-demo -o wide
```

**Expected output**: all six replicas on the same node this time - the
bin-packing result the naive config implied but never actually produced:

```
NAME                                             READY   STATUS    RESTARTS   AGE   NODE
scheduling-profiles-pack-demo-7876b68494-4x45v   1/1     Running   0          14s   k8s-lab-default-worker
scheduling-profiles-pack-demo-7876b68494-ffrwf   1/1     Running   0          15s   k8s-lab-default-worker
scheduling-profiles-pack-demo-7876b68494-knhjw   1/1     Running   0          14s   k8s-lab-default-worker
scheduling-profiles-pack-demo-7876b68494-mk64z   1/1     Running   0          14s   k8s-lab-default-worker
scheduling-profiles-pack-demo-7876b68494-st766   1/1     Running   0          15s   k8s-lab-default-worker
scheduling-profiles-pack-demo-7876b68494-tjw6l   1/1     Running   0          15s   k8s-lab-default-worker
```

Same Deployment shape, same node capacities, same cluster - the only
thing that changed between the two `pack-demo` runs was whether
`PodTopologySpread` was still scoring alongside `NodeResourcesFit`. A
custom scoring strategy on one plugin is never evaluated in isolation;
every other plugin still in the profile's `score` phase gets a vote too.

### Reverting: back to a single default profile

**Why**: this section's edits are live, in-session changes to the
running `default` cluster's control-plane node, not a change to any file
this repo tracks - unlike everything else in this chapter, leaving them
in place would mean the cluster no longer matches what `make up
PROFILE=default` actually produces. This is worth its own explicit
revert step rather than folding into a general teardown, the same way
chapter 12 treats a live etcd directory swap as high-enough-stakes to
document on its own.

**Example**: delete the demo Deployment, restore the backed-up manifest
over the edited one, and remove the now-unused config file:

```
kubectl delete -f tutorial/examples/scheduling-profiles/pack-demo-deployment.yaml
docker exec k8s-lab-default-control-plane cp /etc/kubernetes/kube-scheduler.yaml.orig-backup /etc/kubernetes/manifests/kube-scheduler.yaml
docker exec k8s-lab-default-control-plane rm -f /etc/kubernetes/kube-scheduler.yaml.orig-backup /etc/kubernetes/scheduler-config.yaml
kubectl get pods -n kube-system -l component=kube-scheduler
```

**Expected output**: kubelet restarts the static pod once more, and this
time the running container's actual process args - confirmed via
`crictl inspect`, not just the manifest file's own text - are back to
the original, `--config`-free flags:

```
['kube-scheduler', '--authentication-kubeconfig=/etc/kubernetes/scheduler.conf', '--authorization-kubeconfig=/etc/kubernetes/scheduler.conf', '--bind-address=127.0.0.1', '--kubeconfig=/etc/kubernetes/scheduler.conf', '--leader-elect=true']
```

A plain sanity Pod confirms ordinary scheduling still works with no
named `schedulerName` at all:

```
kubectl run scheduling-profiles-sanity --image=busybox --restart=Never --command -- sleep 5
kubectl get pod scheduling-profiles-sanity -o wide
```

```
NAME                         READY   STATUS    RESTARTS   AGE   NODE
scheduling-profiles-sanity   1/1     Running   0          5s    k8s-lab-default-worker2
```

## Dynamic Resource Allocation (`resource.k8s.io`)

**This section is optional.** Everything through "What's live and
unconditional" below needs nothing beyond this repo's `default` profile
as-is. The rest - seeing a `ResourceClaim` actually get allocated -
depends on installing a real, external, unvendored Helm chart
(`kubernetes-sigs/dra-example-driver`), which is a different category of
dependency from anything else in this tutorial: everything under
`manifests/` is fetched from an exact upstream tag and applied as part
of a profile's own `manifests.txt` (see DESIGN.md); this driver is
neither. Skip straight to "Cluster web UI: Headlamp" below if seeing the
live objects is enough.

### What's live and unconditional, no driver required

**Why**: Dynamic Resource Allocation (DRA) is how a Pod requests
hardware - GPUs, or anything else a vendor writes a driver for - by
*attribute* rather than by a fixed resource name like `nvidia.com/gpu`.
Its core API group, `resource.k8s.io`, went GA in Kubernetes 1.34; this
repo's pinned node image is v1.36.1, comfortably past that, and the
group appears with no feature gates, no `--runtime-config`, nothing set
in either profile's `cluster.yaml` - it's compiled into `kube-apiserver`
unconditionally on any 1.34+ cluster, whether or not a single device
driver is ever installed.

**Example**: confirm the group and its types exist right now, with
nothing installed:

```
kubectl api-resources --api-group=resource.k8s.io
kubectl get --raw /apis/resource.k8s.io
kubectl get deviceclasses,resourceslices,resourceclaims -A
```

**Expected output**: four real, registered types, and confirmation
they're empty - not missing, just unused:

```
NAME                     SHORTNAMES   APIVERSION           NAMESPACED   KIND
deviceclasses                         resource.k8s.io/v1   false        DeviceClass
resourceclaims                        resource.k8s.io/v1   true         ResourceClaim
resourceclaimtemplates                resource.k8s.io/v1   true         ResourceClaimTemplate
resourceslices                        resource.k8s.io/v1   false        ResourceSlice

{"kind":"APIGroup","apiVersion":"v1","name":"resource.k8s.io","versions":[{"groupVersion":"resource.k8s.io/v1","version":"v1"}],"preferredVersion":{"groupVersion":"resource.k8s.io/v1","version":"v1"}}

No resources found
```

**A note back to chapter 11**: `resource.k8s.io` is a *built-in* API
group, registered directly in `kube-apiserver` the same way `batch` or
`discovery.k8s.io` are - it is neither a CRD (chapter 11's main subject)
nor an aggregated API (chapter 11's closing aside, where `metrics.k8s.io`
is proxied to a separate Deployment via an `APIService`). Nothing here
proxies to another process and nothing here was registered by applying
a manifest; it's part of the apiserver binary itself, unconditionally,
on any cluster new enough. Worth stating plainly since chapter 11 covers
both of the *other* two ways a new API group can show up, and DRA is a
good example of the third: a group that ships in the apiserver but does
nothing without something else - here, a device driver - actually using
it.

### Seeing it allocate a real device

**Why**: `resource.k8s.io`'s types are inert without a driver publishing
`ResourceSlice` objects - nothing on a stock kind cluster has physical
GPUs to expose. `kubernetes-sigs/dra-example-driver` exists specifically
to fill that gap: a SIG-maintained reference driver that publishes mock
"GPU" devices per node, built for exactly this kind of demo, not a
production device driver. This chapter pins it at git tag **v0.4.0**
(latest as of this writing) - its chart declares `kubeVersion:
">=1.33.0-0"`, comfortably satisfied by this cluster's v1.36.1. Its
default `values.yaml` points at a published image,
`registry.k8s.io/dra-example-driver/dra-example-driver:v0.4.0` - the
upstream README's own quickstart builds the driver image locally via
`docker buildx`, but that's only needed for its own bundled kind-cluster
demo script; installing straight from the chart's own defaults onto an
existing cluster (this repo's `default` profile, in this case) pulls the
already-published image instead, no local build step required.

**Example**: clone the driver at the pinned tag and install its Helm
chart directly - no values overrides, so the validating webhook (which
needs cert-manager) stays off, matching its documented default:

```
git clone --depth 1 --branch v0.4.0 https://github.com/kubernetes-sigs/dra-example-driver.git
helm upgrade -i --create-namespace --namespace dra-example-driver \
  dra-example-driver dra-example-driver/deployments/helm/dra-example-driver
kubectl get pods -n dra-example-driver -o wide
kubectl get deviceclass
kubectl get resourceslices
```

**Expected output**: one kubelet-plugin Pod per worker (this repo's
`default` profile has two), a `DeviceClass` named `gpu.example.com` (the
chart's default `deviceProfile: gpu`, turned into a driver name via
`<profile>.example.com`), and one `ResourceSlice` per worker publishing
its mock device:

```
NAME                                     READY   STATUS    RESTARTS   AGE
dra-example-driver-kubeletplugin-w82qm   1/1     Running   0          6s
dra-example-driver-kubeletplugin-zlqjn   1/1     Running   0          6s

NAME              AGE
gpu.example.com   6s

NAME                                                  NODE                      DRIVER            POOL
00000-gpu.example.com-k8s-lab-default-worker-rpp7s    k8s-lab-default-worker    gpu.example.com   k8s-lab-default-worker
00000-gpu.example.com-k8s-lab-default-worker2-j7x2z   k8s-lab-default-worker2   gpu.example.com   k8s-lab-default-worker2
```

Now request one, via
`tutorial/examples/dra/dra-demo.yaml` - adapted from the driver's own
`demo/examples/basic-resourceclaimtemplate` at the same tag: a
`ResourceClaimTemplate` asking for one device from `gpu.example.com`,
and a Pod that claims it through `spec.resourceClaims` plus a matching
`resources.claims` entry on the container:

```
kubectl apply -f tutorial/examples/dra/dra-demo.yaml
kubectl get pod -n dra-demo dra-demo-pod -o wide
kubectl get resourceclaims -n dra-demo
kubectl describe resourceclaims -n dra-demo
```

**Expected output**: the Pod runs, and the `ResourceClaim` it generated
(one per `resourceClaimTemplateName` reference, named after the Pod) is
`allocated,reserved`, with the scheduler's actual decision recorded -
which physical device, on which node's pool:

```
NAME           READY   STATUS    RESTARTS   AGE   NODE
dra-demo-pod   1/1     Running   0          8s    k8s-lab-default-worker2

NAME                     STATE                AGE
dra-demo-pod-gpu-jvz8j   allocated,reserved   8s

  Allocation:
    Devices:
      Results:
        Device:   gpu-0
        Driver:   gpu.example.com
        Pool:     k8s-lab-default-worker2
        Request:  gpu
  Reserved For:
    Name:      dra-demo-pod
    Resource:  pods
```

The plugin responsible for that placement decision is `DynamicResources`
- one of the same default `multiPoint` plugins the earlier section's
effective-config dump already showed running alongside
`NodeResourcesFit` and `PodTopologySpread`, at weight 2. A DRA claim
isn't scheduled by a separate mechanism from everything else in this
chapter - it's one more plugin in the identical pipeline, filtering
nodes down to the ones whose `ResourceSlice`s can satisfy the claim, the
same filter-then-score cycle chapter 7's affinity rules go through.

The device identity also reaches the container itself, injected as
environment variables - real values the driver computed, not anything
the Pod spec declared:

```
kubectl exec -n dra-demo dra-demo-pod -- env | grep -i "gpu\|device"
```

```
DRA_RESOURCE_DRIVER_NAME=gpu.example.com
GPU_DEVICE_GPU_0_RESOURCE_CLAIM=cea54d23-8cc3-4a84-bbbc-ab4725ae8728
GPU_DEVICE_0=gpu-0
GPU_DEVICE_0_SHARING_STRATEGY=TimeSlicing
GPU_DEVICE_0_TIMESLICE_INTERVAL=Default
```

### Teardown

**Why**: like chapter 13's registry, this section's driver is real state
outside anything `manifests.txt` manages - a Helm release, not part of
any profile, that needs its own explicit removal.

**Example**:

```
kubectl delete -f tutorial/examples/dra/dra-demo.yaml
helm uninstall dra-example-driver -n dra-example-driver
kubectl delete namespace dra-example-driver
kubectl get resourceslices,deviceclass,resourceclaims,resourceclaimtemplates -A
```

**Expected output**: deleting the namespace kills the kubelet-plugin
Pods without giving them a chance to unpublish their own
`ResourceSlice`s first - they're left behind as orphaned objects rather
than being garbage-collected automatically, a real gap worth knowing
about rather than assuming teardown is always clean:

```
NAME                                                                                NODE                      DRIVER
resourceslice.resource.k8s.io/00000-gpu.example.com-k8s-lab-default-worker-rpp7s    k8s-lab-default-worker    gpu.example.com
resourceslice.resource.k8s.io/00000-gpu.example.com-k8s-lab-default-worker2-j7x2z   k8s-lab-default-worker2   gpu.example.com
```

They don't come back on their own, and nothing else in the cluster
depends on them once the driver is gone - delete them directly:

```
kubectl delete resourceslices --all
```

## Cluster web UI: Headlamp

**Why**: `kubernetes/dashboard`, the project's original web UI, was
archived by its maintainers on January 21, 2026, citing lack of active
maintainers - any material describing it as the current option is
already out of date. **Headlamp** (`kubernetes-sigs/headlamp`) is the
Kubernetes project's own recommended replacement, an official SIG UI
sub-project: a from-scratch rewrite (React + Material UI), actively
released, with RBAC-aware views, multi-cluster support, and a plugin
architecture.

Two install paths, not one: in-cluster via Helm
(`helm repo add headlamp https://kubernetes-sigs.github.io/headlamp/`,
then `helm install`), or as a standalone desktop application that reads
a local kubeconfig directly, with zero in-cluster deployment at all.
The desktop app is worth considering for general workstation use - it's
not tied to any single cluster's lifecycle the way the in-cluster
Deployment is, so it survives a `make down` unlike anything this
tutorial has deployed into the cluster itself.

Auth for the in-cluster install follows the same pattern the old
Dashboard used: a ServiceAccount token
(`kubectl create token <name>`), which is chapter 9's RBAC and
ServiceAccount material directly, not a new mechanism this chapter
introduces. One thing worth checking before installing rather than
after: the current Helm chart provisions a `cluster-admin`
ClusterRoleBinding by default for its own ServiceAccount - fine for this
lab, but exactly the kind of over-broad grant chapter 9's RBAC section
already covered how to narrow (a `Role`/`RoleBinding` scoped to specific
namespaces and verbs instead of the default `ClusterRoleBinding`).

## krew: a kubectl plugin manager

Installed via the official one-liner from `kubernetes-sigs/krew`
releases (an install method that's stayed unchanged for years); once
installed, `kubectl krew search <term>` and `kubectl krew install
<plugin>` pull plugins that then run as `kubectl <plugin-name>`. The one
plugin worth naming directly is `neat`
(`kubectl get <resource> -o yaml | kubectl neat`), which strips
`creationTimestamp`/`resourceVersion`/`uid`/`status`/empty-placeholder
noise from live object YAML - genuinely useful against this repo's own
scratch-manifest workflow, where a `kubectl get -o yaml` dump is often
the fastest way to capture a real object's shape as a starting point for
a new example file. `kubectl`'s own verb grammar isn't fully consistent
- resource-generic verbs (`get`, `describe`, `delete`) require a
resource-type argument since they can target anything, while
Pod-specific verbs (`logs`, `exec`, `attach`, `debug`, `cp`,
`port-forward`) skip it since there's no ambiguity - longstanding,
organic inconsistency in the CLI, not something to second-guess. It's
part of why the plugin ecosystem `krew` manages exists at all: a way to
add commands with their own grammar without waiting for `kubectl`
itself to grow them.
