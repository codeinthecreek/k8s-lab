# 14. Advanced and supplementary topics

Chapters 1-13 build on each other in order. This chapter collects four
topics that don't fit that sequence:

- **Scheduling Profiles**: configuring the scheduler itself, rather than
  a Pod's placement.
- **Dynamic Resource Allocation** (DRA): the newer API for requesting
  devices such as GPUs. It became stable (GA) in Kubernetes 1.34.
- **Headlamp**: a web UI for the cluster.
- **krew**: a plugin manager for `kubectl`.

None of them is needed for the earlier chapters, and each is easier to
follow once those are in place.

### From `--policy-config-file` to `KubeSchedulerConfiguration`

**Why**: chapter 7 covered how a Pod influences its own placement
(affinity, taints, resource requests). This section covers the other
side: how the scheduler itself is configured.

Older material describes a `kind: Policy` JSON file passed with
`--policy-config-file`. That flag was deprecated in Kubernetes v1.23 and
has since been removed; `kube-scheduler --help` on this cluster
(v1.36.1) doesn't mention it. Today the scheduler takes a
`KubeSchedulerConfiguration` file
(`apiVersion: kubescheduler.config.k8s.io/v1`, stable since v1.25),
passed with `kube-scheduler --config <file>`.

That file defines one or more **scheduling profiles**. Each profile is a
named scheduling pipeline made of plugins. The pipeline has fixed stages
(extension points) such as `filter`, which rules out nodes, and `score`,
which ranks the ones left, and a profile can add, remove or reconfigure
the plugins at each stage. (The full list is `queueSort`, `preFilter`,
`filter`, `postFilter`, `preScore`, `score`, `reserve`, `permit`,
`preBind`, `bind` and `postBind`, plus `multiPoint`, a shorthand that
enables a plugin at every stage it supports.) Older material calls the
same filter-then-score idea "predicates and priorities".

One scheduler process can run several profiles at once. A Pod picks one
with `spec.schedulerName`. If it's unset, the Pod gets
`default-scheduler`, which is why no earlier chapter had to mention it.

When `--config` is set, some other flags are ignored rather than
rejected. `kube-scheduler --help` marks `--kubeconfig`,
`--kube-api-qps` and a few others "DEPRECATED: ... ignored if a config
file is specified in --config". Their settings move into the config
file's `clientConnection` section.

**Example**: on the `default` profile's cluster, the scheduler runs
with plain flags and no `--config`. Check its static Pod manifest:

```
docker exec k8s-lab-default-control-plane cat /etc/kubernetes/manifests/kube-scheduler.yaml
```

**Expected output**: the manifest kubeadm generated, with the command
made of individual flags:

```
    command:
    - kube-scheduler
    - --authentication-kubeconfig=/etc/kubernetes/scheduler.conf
    - --authorization-kubeconfig=/etc/kubernetes/scheduler.conf
    - --bind-address=127.0.0.1
    - --kubeconfig=/etc/kubernetes/scheduler.conf
    - --leader-elect=true
```

To add a profile, you edit this static Pod manifest on the
control-plane node. `kubectl` can't do it: only the kubelet watches
`/etc/kubernetes/manifests/`, and it restarts the Pod whenever a file
there changes. So the steps below use `docker exec` and `docker cp`, as
chapters 10-12 did for `crictl` and `journalctl`.

**This edits a running control-plane component.** It's safe enough in
this lab: the change only affects how the scheduler starts, it doesn't
touch etcd or any object in the cluster, and the end of this section
puts the original manifest back. On a real cluster, treat it with more
care.

**First, back up the current manifest, but not into
`/etc/kubernetes/manifests/`.** The kubelet treats every file in that
directory as a static Pod. A backup there has the same
`metadata.name: kube-scheduler` as the real manifest, and the two
compete; the backup can win, leaving the old scheduler running.
(That happened while this chapter was being written.) Put the backup one
directory up:

```
docker exec k8s-lab-default-control-plane cp /etc/kubernetes/manifests/kube-scheduler.yaml /etc/kubernetes/kube-scheduler.yaml.orig-backup
```

Now copy in a `KubeSchedulerConfiguration` with two profiles: the
unchanged `default-scheduler`, and a new one called
`bin-packing-scheduler`.
[`scheduler-config-naive.yaml`](examples/scheduling-profiles/scheduler-config-naive.yaml)
changes one thing in the new profile: the `NodeResourcesFit` plugin
scores nodes with `MostAllocated` (prefer the fullest node) instead of
the default `LeastAllocated` (prefer the emptiest). Copy it, and an
edited scheduler manifest, onto the control-plane node:

```
docker cp tutorial/examples/scheduling-profiles/scheduler-config-naive.yaml k8s-lab-default-control-plane:/etc/kubernetes/scheduler-config.yaml
docker cp tutorial/examples/scheduling-profiles/kube-scheduler-static-pod.yaml k8s-lab-default-control-plane:/etc/kubernetes/manifests/kube-scheduler.yaml
```

The second file is kubeadm's manifest with two additions: the flag
`--config=/etc/kubernetes/scheduler-config.yaml`, and a `hostPath`
volume that mounts that file. Everything else is unchanged. The kubelet
sees the new manifest and restarts the scheduler:

```
kubectl get pods -n kube-system -l component=kube-scheduler
```

**Expected output**: `1/1 Running` again within a few seconds:

```
NAME                                           READY   STATUS    RESTARTS   AGE
kube-scheduler-k8s-lab-default-control-plane   1/1     Running   0          9s
```

### Two profiles, one Pod field: `spec.schedulerName`

**Why**: with both profiles running, each Pod chooses one with its
`spec.schedulerName`. Nothing at the cluster level assigns Pods to
profiles. Does `MostAllocated` change where Pods land? The `default`
profile's two workers make a simple test.

**Example**: [`spread-demo-deployment.yaml`](examples/scheduling-profiles/spread-demo-deployment.yaml)
runs six replicas, each requesting `cpu: "1"`, with
`schedulerName: default-scheduler`.
[`pack-demo-deployment.yaml`](examples/scheduling-profiles/pack-demo-deployment.yaml)
is the same with `schedulerName: bin-packing-scheduler`. Run the first:

```
kubectl apply -f tutorial/examples/scheduling-profiles/spread-demo-deployment.yaml
kubectl get pods -l app=scheduling-profiles-spread-demo -o wide
```

**Expected output**: the default profile spreads them evenly across both
workers:

```
NAME                                              READY   STATUS    RESTARTS   AGE   NODE
scheduling-profiles-spread-demo-5fc8d4dd6-7sbrv   1/1     Running   0          12s   k8s-lab-default-worker
scheduling-profiles-spread-demo-5fc8d4dd6-9s77d   1/1     Running   0          12s   k8s-lab-default-worker
scheduling-profiles-spread-demo-5fc8d4dd6-lbvnz   1/1     Running   0          12s   k8s-lab-default-worker2
scheduling-profiles-spread-demo-5fc8d4dd6-pkhl5   1/1     Running   0          12s   k8s-lab-default-worker2
scheduling-profiles-spread-demo-5fc8d4dd6-s6wkz   1/1     Running   0          12s   k8s-lab-default-worker2
scheduling-profiles-spread-demo-5fc8d4dd6-sq5ns   1/1     Running   0          12s   k8s-lab-default-worker
```

Three and three. Delete it, and run the same shape with the bin-packing
profile:

```
kubectl delete -f tutorial/examples/scheduling-profiles/spread-demo-deployment.yaml
kubectl apply -f tutorial/examples/scheduling-profiles/pack-demo-deployment.yaml
kubectl get pods -l app=scheduling-profiles-pack-demo -o wide
```

**Expected output**: still three and three. You might expect all six on
one node, and the setup isn't wrong; the next section explains:

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

**Why**: the `pluginConfig` for `NodeResourcesFit` changes how that one
plugin scores nodes. Every other default plugin is still in the
profile, and still votes. One of them, `PodTopologySpread`, applies a
built-in soft rule to every Pod: spread Pods across nodes
(`topologyKey: kubernetes.io/hostname`,
`whenUnsatisfiable: ScheduleAnyway`), even if the Pod has no
`topologySpreadConstraints` of its own. Its vote outweighed the
bin-packing score.

**Example**: to see the plugin weights, have a scheduler print its full
effective configuration. This runs a separate, throwaway scheduler
container of the same version (v1.36.1) with the naive config, not the
live one. Run it from the repo root.

The config file's `clientConnection.kubeconfig` points at
`/etc/kubernetes/scheduler.conf`, so the container needs a valid
kubeconfig there, or the command stops with an error. It doesn't need a
real one, though, so the first three lines create a kubeconfig in a
temporary file with only a placeholder server address and no
credentials; the last line deletes it:

```
kubectl config --kubeconfig=/tmp/k8s-lab-scheduler.conf set-cluster dump --server=https://127.0.0.1:1
kubectl config --kubeconfig=/tmp/k8s-lab-scheduler.conf set-context dump --cluster=dump
kubectl config --kubeconfig=/tmp/k8s-lab-scheduler.conf use-context dump
docker run --rm \
  -v "$PWD/tutorial/examples/scheduling-profiles/scheduler-config-naive.yaml:/config.yaml:ro" \
  -v /tmp/k8s-lab-scheduler.conf:/etc/kubernetes/scheduler.conf:ro \
  registry.k8s.io/kube-scheduler:v1.36.1 kube-scheduler --config=/config.yaml --write-config-to=/dev/stdout \
  2>&1 | grep -A1 -E '^      - name: (NodeResourcesFit|PodTopologySpread|DynamicResources)$' | grep -v '^--$' | head -6
rm /tmp/k8s-lab-scheduler.conf
```

The full dump is long (two profiles, 20 plugins each), so the `grep`
keeps the three plugins this section needs, from the first profile. If
nothing prints, run the `docker run` part without the filter to see the
error.

**Expected output**: three confirmations from `kubectl config`, then the
three plugins' default weights. (The second profile shows the same
weights, since the config only changed `NodeResourcesFit`'s scoring.
`DynamicResources` comes back in the DRA section below.)

```
Cluster "dump" set.
Context "dump" created.
Switched to context "dump".
      - name: NodeResourcesFit
        weight: 1
      - name: PodTopologySpread
        weight: 2
      - name: DynamicResources
        weight: 2
```

`PodTopologySpread` has twice the weight of `NodeResourcesFit`, so its
spreading won over bin-packing.
[`scheduler-config.yaml`](examples/scheduling-profiles/scheduler-config.yaml)
fixes that by disabling `PodTopologySpread` in the `score` stage of the
`bin-packing-scheduler` profile only. `default-scheduler` keeps it: each
profile has its own plugin list.

```
docker cp tutorial/examples/scheduling-profiles/scheduler-config.yaml k8s-lab-default-control-plane:/etc/kubernetes/scheduler-config.yaml
```

Copying in a new config file isn't enough. The scheduler reads it only
at startup, and the kubelet restarts the static Pod only when the
*manifest* changes, not a file the manifest mounts. So make a small
change to the manifest, here adding a label:

```
docker exec k8s-lab-default-control-plane sh -c "sed -i 's/tier: control-plane/tier: control-plane\n    scheduler-config-generation: \"2\"/' /etc/kubernetes/manifests/kube-scheduler.yaml"
kubectl delete -f tutorial/examples/scheduling-profiles/pack-demo-deployment.yaml
kubectl apply -f tutorial/examples/scheduling-profiles/pack-demo-deployment.yaml
kubectl get pods -l app=scheduling-profiles-pack-demo -o wide
```

**Expected output**: all six replicas on one node this time:

```
NAME                                             READY   STATUS    RESTARTS   AGE   NODE
scheduling-profiles-pack-demo-7876b68494-4x45v   1/1     Running   0          14s   k8s-lab-default-worker
scheduling-profiles-pack-demo-7876b68494-ffrwf   1/1     Running   0          15s   k8s-lab-default-worker
scheduling-profiles-pack-demo-7876b68494-knhjw   1/1     Running   0          14s   k8s-lab-default-worker
scheduling-profiles-pack-demo-7876b68494-mk64z   1/1     Running   0          14s   k8s-lab-default-worker
scheduling-profiles-pack-demo-7876b68494-st766   1/1     Running   0          15s   k8s-lab-default-worker
scheduling-profiles-pack-demo-7876b68494-tjw6l   1/1     Running   0          15s   k8s-lab-default-worker
```

The only difference between the two `pack-demo` runs was whether
`PodTopologySpread` was still scoring. A scoring change to one plugin is
never the whole story: every other plugin in the `score` stage still
gets a vote.

### Reverting: back to a single default profile

**Why**: these edits changed the running cluster's control-plane node,
not any file in this repo, so the cluster no longer matches what
`make up PROFILE=default` creates. Put it back.

**Example**: delete the demo Deployment, copy the backup over the
edited manifest, and remove the backup and the config file:

```
kubectl delete -f tutorial/examples/scheduling-profiles/pack-demo-deployment.yaml
docker exec k8s-lab-default-control-plane cp /etc/kubernetes/kube-scheduler.yaml.orig-backup /etc/kubernetes/manifests/kube-scheduler.yaml
docker exec k8s-lab-default-control-plane rm -f /etc/kubernetes/kube-scheduler.yaml.orig-backup /etc/kubernetes/scheduler-config.yaml
kubectl get pods -n kube-system -l component=kube-scheduler
```

**Expected output**: the kubelet restarts the scheduler once more. Its
running process is back to the original flags, without `--config`, as
`crictl inspect` on the node shows:

```
['kube-scheduler', '--authentication-kubeconfig=/etc/kubernetes/scheduler.conf', '--authorization-kubeconfig=/etc/kubernetes/scheduler.conf', '--bind-address=127.0.0.1', '--kubeconfig=/etc/kubernetes/scheduler.conf', '--leader-elect=true']
```

A Pod with no `schedulerName` still gets scheduled:

```
kubectl run scheduling-profiles-sanity --image=busybox --restart=Never --command -- sleep 5
kubectl get pod scheduling-profiles-sanity -o wide
```

```
NAME                         READY   STATUS    RESTARTS   AGE   NODE
scheduling-profiles-sanity   1/1     Running   0          5s    k8s-lab-default-worker2
```

The cluster is back to a single default profile. The next topic is
unrelated.

## Dynamic Resource Allocation (`resource.k8s.io`)

**This section is optional.** The first part, "What's there with no
driver", needs only the `default` profile. The rest installs an external
Helm chart, `kubernetes-sigs/dra-example-driver`, to see a device
actually allocated. Unlike everything under `manifests/`, that chart is
not pinned in this repo or applied by a profile (see DESIGN.md). Skip to
"Cluster web UI: Headlamp" if the first part is enough.

### What's there with no driver

**Why**: Dynamic Resource Allocation (DRA) lets a Pod request hardware,
such as a GPU, by its *attributes* rather than by a resource name and a
count like `nvidia.com/gpu: 1` (chapters 15-18). Its API group,
`resource.k8s.io`, went GA in Kubernetes 1.34. This cluster runs
v1.36.1, and the group is there without any feature gates or settings in
`cluster.yaml`: it's built into the apiserver, whether or not any device
driver is installed.

**Example**: list the group's types, with nothing installed:

```
kubectl api-resources --api-group=resource.k8s.io
kubectl get --raw /apis/resource.k8s.io
kubectl get deviceclasses,resourceslices,resourceclaims -A
```

**Expected output**: four types, all present and all empty:

```
NAME                     SHORTNAMES   APIVERSION           NAMESPACED   KIND
deviceclasses                         resource.k8s.io/v1   false        DeviceClass
resourceclaims                        resource.k8s.io/v1   true         ResourceClaim
resourceclaimtemplates                resource.k8s.io/v1   true         ResourceClaimTemplate
resourceslices                        resource.k8s.io/v1   false        ResourceSlice

{"kind":"APIGroup","apiVersion":"v1","name":"resource.k8s.io","versions":[{"groupVersion":"resource.k8s.io/v1","version":"v1"}],"preferredVersion":{"groupVersion":"resource.k8s.io/v1","version":"v1"}}

No resources found
```

**How this differs from chapter 11.** Chapter 11 showed two ways a new
API group appears: a CRD, and an aggregated API (such as
`metrics.k8s.io`, which the apiserver forwards to another Deployment).
`resource.k8s.io` is neither. It's built into the apiserver, like
`batch` or `discovery.k8s.io`, and nothing was applied to create it. It
just does nothing until a device driver uses it.

### Seeing it allocate a real device

**Why**: the DRA types do nothing until a driver publishes
`ResourceSlice` objects describing its devices, and a kind cluster has no
real devices to publish. `kubernetes-sigs/dra-example-driver` fills the
gap: a reference driver from a Kubernetes SIG that publishes fake "GPU"
devices on each node. It's meant for demos like this one, not for
production.

This chapter uses its tag **v0.4.0**, the latest when this was written.
Its chart requires Kubernetes 1.33 or later. The chart's default values
use a published image,
`registry.k8s.io/dra-example-driver/dra-example-driver:v0.4.0`, so
installing it on an existing cluster needs no image build. (The
upstream README builds the image locally, but only for its own
kind-cluster demo script.)

**Example**: clone the driver at that tag and install its chart with no
value overrides. That leaves its validating webhook off, which is the
default; the webhook would need cert-manager:

```
git clone --depth 1 --branch v0.4.0 https://github.com/kubernetes-sigs/dra-example-driver.git
helm upgrade -i --create-namespace --namespace dra-example-driver \
  dra-example-driver dra-example-driver/deployments/helm/dra-example-driver
kubectl get pods -n dra-example-driver -o wide
kubectl get deviceclass
kubectl get resourceslices
```

**Expected output**: one driver Pod per worker (the `default` profile
has two), a `DeviceClass` called `gpu.example.com`, and one
`ResourceSlice` per worker describing its fake device:

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

Now ask for a device.
[`dra-demo.yaml`](examples/dra/dra-demo.yaml) is adapted from the
driver's `demo/examples/basic-resourceclaimtemplate` at the same tag. It
has a `ResourceClaimTemplate` that asks for one device from
`gpu.example.com`, and a Pod that uses it through `spec.resourceClaims`
and a matching `resources.claims` entry on the container:

```
kubectl apply -f tutorial/examples/dra/dra-demo.yaml
kubectl get pod -n dra-demo dra-demo-pod -o wide
kubectl get resourceclaims -n dra-demo
kubectl describe resourceclaims -n dra-demo
```

**Expected output**: the Pod runs. Kubernetes created a
`ResourceClaim` for it from the template (named after the Pod), and the
claim is `allocated,reserved`. Its description records which device was
chosen, from which node's pool:

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

The scheduler plugin that made this decision is `DynamicResources`,
which appeared in the configuration dump earlier in this chapter. DRA
claims aren't scheduled by a separate mechanism: `DynamicResources` is
one more plugin in the same pipeline, ruling out nodes whose
`ResourceSlice`s can't satisfy the claim.

The driver also tells the container which device it got, through
environment variables the Pod spec never declared:

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

**Why**: the driver is a Helm release outside any profile, like
chapter 13's registry, so it needs removing by hand.

**Example**:

```
kubectl delete -f tutorial/examples/dra/dra-demo.yaml
helm uninstall dra-example-driver -n dra-example-driver
kubectl delete namespace dra-example-driver
kubectl get resourceslices,deviceclass,resourceclaims,resourceclaimtemplates -A
```

**Expected output**: some objects are left behind. Deleting the
namespace stops the driver Pods before they can remove their
`ResourceSlice`s, and nothing cleans them up automatically:

```
NAME                                                                                NODE                      DRIVER
resourceslice.resource.k8s.io/00000-gpu.example.com-k8s-lab-default-worker-rpp7s    k8s-lab-default-worker    gpu.example.com
resourceslice.resource.k8s.io/00000-gpu.example.com-k8s-lab-default-worker2-j7x2z   k8s-lab-default-worker2   gpu.example.com
```

Nothing uses them once the driver is gone. Delete them:

```
kubectl delete resourceslices --all
```

The last two topics are tools that work on top of everything covered so
far.

## Cluster web UI: Headlamp

**Why**: the original web UI, `kubernetes/dashboard`, was archived by
its maintainers on January 21, 2026, for lack of maintainers. Material
that presents it as the current option is out of date. Its recommended
replacement is **Headlamp** (`kubernetes-sigs/headlamp`), an official
Kubernetes SIG UI project. It's actively released, shows only what your
RBAC permissions allow, supports multiple clusters, and can be extended
with plugins.

There are two ways to install it:

- **In the cluster, with Helm**: `helm repo add headlamp
  https://kubernetes-sigs.github.io/headlamp/`, then `helm install`.
- **As a desktop application** that reads your local kubeconfig, with
  nothing installed in the cluster. It isn't tied to one cluster, so it
  survives a `make down`. For everyday use on a workstation, it's the
  simpler choice.

The in-cluster version logs you in with a ServiceAccount token
(`kubectl create token <name>`), the ServiceAccount and RBAC material
from chapter 9. Check one thing before installing: by default the Helm
chart binds its own ServiceAccount to `cluster-admin`. That's fine for
this lab, but on a real cluster you'd narrow it with a `Role` and
`RoleBinding` limited to specific namespaces and verbs, as chapter 9
shows.

From a web UI to the other end of the scale: adding commands to
`kubectl`.

## krew: a kubectl plugin manager

krew installs and manages `kubectl` plugins. Install it with the
one-line installer from the `kubernetes-sigs/krew` releases. Then
`kubectl krew search <term>` finds plugins, `kubectl krew install
<plugin>` installs one, and it runs as `kubectl <plugin-name>`.

One plugin worth knowing is `neat`: `kubectl get <resource> -o yaml |
kubectl neat` strips the noise from a live object's YAML
(`creationTimestamp`, `resourceVersion`, `uid`, `status` and empty
fields). That's handy for using a real object as the starting point for
a new example file.

Plugins also explain some of `kubectl`'s uneven command style. Generic
verbs such as `get`, `describe` and `delete` take a resource type,
because they work on anything. Pod-only verbs such as `logs`, `exec`,
`attach`, `debug`, `cp` and `port-forward` don't, because the target is
always a Pod. Plugins let people add commands, with their own style,
without waiting for `kubectl` to grow them.
