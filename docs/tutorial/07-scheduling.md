# 7. Scheduling and resource management

Every chapter so far has relied on the scheduler placing Pods somewhere
sensible without saying anything about it. This chapter makes that
placement decision itself the subject: the same label/selector mechanism
already used for ReplicaSets (chapter 3) and Services (chapter 5),
applied to nodes and, in a second form, to other Pods; the ways to
influence where a Pod can and can't land (node affinity, pod
affinity/anti-affinity, taints/tolerations); the resource requests/limits that
shape *how much* of a node a Pod is allowed to consume once it's there;
and, closing the loop from a single Pod to an entire namespace,
ResourceQuota and LimitRange - the mechanism that turns a namespace from
a bare naming scope into an actual resource boundary. This chapter
covers what a Pod spec can say to influence *its own* placement;
configuring the scheduler itself - `KubeSchedulerConfiguration`,
multiple named Scheduling Profiles selected via `spec.schedulerName` -
is a separate topic, covered in chapter 14.

### Labels and selectors: one mechanism, used everywhere

**Why**: nothing new here mechanically - a ReplicaSet's `spec.selector`
matches Pods by label, a Service's `spec.selector` matches Pods by
label, and this chapter's node affinity matches **nodes** by label,
using the exact same underlying selector semantics. It's worth naming
that consistency directly rather than re-deriving it per feature.
Selectors come in two forms: equality-based `matchLabels` (`key: value`,
exact match only) and the more expressive `matchExpressions` (`In`,
`NotIn`, `Exists`, `DoesNotExist`, with a list of values) - node
affinity below only supports the `matchExpressions` form, which is why
it looks slightly different from a ReplicaSet's `matchLabels`.

**Example**: label a node directly - nodes are just objects with
metadata like anything else:

```
kubectl label node k8s-lab-default-worker scheduling-demo/zone=zone-a
kubectl get nodes -l scheduling-demo/zone=zone-a
```

**Expected output**: exactly one node - the one labeled, nothing else:

```
node/k8s-lab-default-worker labeled

NAME                     STATUS   ROLES    AGE   VERSION
k8s-lab-default-worker   Ready    <none>   17h   v1.36.1
```

With that selector mechanism established, the next two subsections -
node affinity, then pod affinity/anti-affinity - both extend it to
answer where a Pod is allowed to land.

### Node affinity: constraining where a Pod can be scheduled

**Why**: `nodeSelector` (the older, simpler mechanism - still valid, a
flat map of required labels) only supports exact-match AND semantics.
Node affinity does the same job with more expressiveness -
`requiredDuringSchedulingIgnoredDuringExecution` is a hard constraint
(no matching node, Pod stays unscheduled), while
`preferredDuringSchedulingIgnoredDuringExecution` is a soft ranking hint
the scheduler tries to honor but won't block on. The `IgnoredDuringExecution`
half of both names matters: like a taint (below), affinity is only
evaluated at scheduling time - relabeling a node, or changing a running
Pod's affinity, doesn't retroactively evict or move anything.

**Example**: `tutorial/examples/scheduling/node-affinity-pod.yaml`
requires `scheduling-demo/zone=zone-a`, matching the label just applied
to `k8s-lab-default-worker`:

```
kubectl apply -f tutorial/examples/scheduling/node-affinity-pod.yaml
kubectl get pod scheduling-demo-affinity-pod -o wide
```

**Expected output**: scheduled onto exactly the labeled node, not
wherever the scheduler would otherwise have picked:

```
NAME                           READY   STATUS    RESTARTS   AGE   IP           NODE
scheduling-demo-affinity-pod   1/1     Running   0          3s    10.244.1.9   k8s-lab-default-worker
```

Now the failure mode - a Pod requiring a label value that matches no
node at all:

```
kubectl apply -f tutorial/examples/scheduling/node-affinity-impossible-pod.yaml
kubectl get pod scheduling-demo-affinity-impossible-pod
kubectl describe pod scheduling-demo-affinity-impossible-pod | grep -A3 Events:
```

**Expected output**: stuck `Pending`, with a `FailedScheduling` event
that names the actual reason for every node - and, as a bonus, real
confirmation that the control-plane node's own `NoSchedule` taint from
chapter 1 is still doing its job on an entirely unrelated Pod:

```
NAME                                       READY   STATUS    RESTARTS   AGE
scheduling-demo-affinity-impossible-pod   0/1     Pending   0          14s

Events:
  Type     Reason            Age   From               Message
  ----     ------            ----  ----               -------
  Warning  FailedScheduling  17s   default-scheduler  0/3 nodes are available: 1 node(s) had untolerated taint(s), 2 node(s) didn't match Pod's node affinity/selector.
```

Three nodes, two different reasons: the two workers didn't match the
(impossible) affinity requirement, and the control-plane node was
excluded for a completely different, pre-existing reason - its taint,
unrelated to anything this chapter added.

### Pod affinity and anti-affinity: co-locating or spreading by Pod labels

**Why**: node affinity (above) matches **node** labels - it answers "which
nodes qualify" with no regard for what else is running there. Pod
affinity and anti-affinity answer a different question: where are
*other Pods* running, identified by their own labels, regardless of
which node happens to have them. `podAffinity` pulls a new Pod toward
whatever node already runs a Pod matching its `labelSelector` (useful
for a cache next to the service that hits it hardest); `podAntiAffinity`
pushes it away from one (useful for spreading replicas so a single node
failure can't take out all of them). Both share node affinity's two
strictness levels (`required`/`preferredDuringSchedulingIgnoredDuringExecution`)
and add one more field neither node affinity nor `nodeSelector` has:
`topologyKey` - the node label whose *value* defines "same place."
`kubernetes.io/hostname` means "the same node"; a label like
`topology.kubernetes.io/zone` on a real multi-zone cluster would mean
"the same zone" without requiring the exact same node. This tutorial's
kind nodes carry no zone labels, so every example below uses
`kubernetes.io/hostname`.

**Example**: `tutorial/examples/scheduling/pod-affinity-anchor-pod.yaml`
is a plain Pod labeled `app=scheduling-demo-colocate` - no affinity
rules of its own, it just needs to land somewhere first:

```
kubectl apply -f tutorial/examples/scheduling/pod-affinity-anchor-pod.yaml
kubectl get pod scheduling-demo-colocate-anchor -o wide
```

**Expected output**: scheduled onto whichever eligible worker the
scheduler happened to pick - live, this cluster put it on
`k8s-lab-default-worker2`:

```
NAME                              READY   STATUS    RESTARTS   AGE   IP           NODE
scheduling-demo-colocate-anchor   1/1     Running   0          2s    10.244.1.3   k8s-lab-default-worker2
```

`tutorial/examples/scheduling/pod-affinity-pod.yaml` requires
scheduling onto whatever node already runs a Pod labeled
`app=scheduling-demo-colocate`:

```
kubectl apply -f tutorial/examples/scheduling/pod-affinity-pod.yaml
kubectl get pod scheduling-demo-affinity-copod -o wide
```

**Expected output**: lands on the exact same node as the anchor, not
just any eligible node - `podAffinity` matched the anchor's label, not
any node label:

```
NAME                              READY   STATUS    RESTARTS   AGE   IP           NODE
scheduling-demo-affinity-copod    1/1     Running   0          3s    10.244.1.4   k8s-lab-default-worker2
```

Now the opposite constraint - `tutorial/examples/scheduling/pod-anti-affinity-pod.yaml`
requires scheduling onto a node that does *not* already run a Pod
labeled `app=scheduling-demo-colocate`:

```
kubectl apply -f tutorial/examples/scheduling/pod-anti-affinity-pod.yaml
kubectl get pod scheduling-demo-antiaffinity-pod -o wide
```

**Expected output**: lands on the *other* worker - the one neither the
anchor nor the affinity Pod occupies - even though the anti-affinity
Pod itself never specifies a node:

```
NAME                                READY   STATUS    RESTARTS   AGE   IP           NODE
scheduling-demo-antiaffinity-pod   1/1     Running   0          44s   10.244.2.5   k8s-lab-default-worker
```

Three Pods, one shared label, two opposite rules against it - `podAffinity`
and `podAntiAffinity` both matched on `app=scheduling-demo-colocate`,
and the scheduler placed each Pod exactly where its own rule required,
independent of anything about the nodes themselves.

### Taints and tolerations: the opposite direction

**Why**: affinity is a Pod opting **in** to certain nodes; taints are a
node opting **out** everything by default, unless a Pod explicitly
tolerates it. Chapter 1 already showed one in practice - kind's
control-plane node carries `node-role.kubernetes.io/control-plane:NoSchedule`
so ordinary Pods don't land there. There are three distinct effects, not
one, straight from the API schema (`kubectl explain
node.spec.taints.effect`):

```
- NoExecute:        Evict any already-running pods that do not tolerate the
                     taint. Currently enforced by NodeController.
- NoSchedule:        Do not allow new pods to schedule onto the node unless
                     they tolerate the taint, but allow all already-running
                     pods to continue running. Enforced by the scheduler.
- PreferNoSchedule:  Like NoSchedule, but the scheduler tries not to
                     schedule new pods onto the node rather than
                     prohibiting it entirely. Enforced by the scheduler.
```

`NoSchedule` (chapter 1's example) only blocks *new* scheduling -
anything already running stays. `NoExecute` is the only effect that
actively evicts Pods already running there. Removing a taint doesn't
undo anything that already happened because of it - eviction isn't
reversed, and nothing gets rescheduled back onto a newly-detainted node
just because it now could be.

**Example**: apply a bare, non-tolerating Pod to the labeled node
*before* tainting it, confirm it's running, then taint the node and
watch what happens to a Pod that was already there:

```
kubectl apply -f tutorial/examples/scheduling/taint-pretaint-pod.yaml
kubectl get pod scheduling-demo-notoleration-pod -o wide
kubectl taint node k8s-lab-default-worker scheduling-demo=maintenance:NoExecute
kubectl get pod scheduling-demo-notoleration-pod
```

**Expected output**: running fine right up until the taint lands, then
gone - not `Terminating`, not caught mid-eviction, already `NotFound` by
the very first check afterward:

```
NAME                               READY   STATUS    RESTARTS   AGE   IP            NODE
scheduling-demo-notoleration-pod   1/1     Running   0          3s    10.244.1.10   k8s-lab-default-worker

node/k8s-lab-default-worker tainted

Error from server (NotFound): pods "scheduling-demo-notoleration-pod" not found
```

A Pod with a matching toleration, applied *after* the taint exists, both
schedules and stays:

```
kubectl apply -f tutorial/examples/scheduling/toleration-pod.yaml
kubectl get pod scheduling-demo-toleration-pod -o wide
```

**Expected output**: schedules straight onto the tainted node (the
toleration makes it eligible, same as `NoSchedule` would) and is still
running, unevicted, a full 10+ seconds later:

```
NAME                             READY   STATUS    RESTARTS   AGE   IP            NODE
scheduling-demo-toleration-pod   1/1     Running   0          2s    10.244.1.11   k8s-lab-default-worker

# ~10s later
scheduling-demo-toleration-pod   1/1     Running   0          14s   10.244.1.11   k8s-lab-default-worker
```

And removing the taint doesn't bring back what it evicted - the earlier
Pod is a bare Pod (chapter 3), so there was never a controller to
recreate it in the first place:

```
kubectl taint node k8s-lab-default-worker scheduling-demo:NoExecute-
kubectl get pod scheduling-demo-notoleration-pod
```

**Expected output**: still gone - untainting a node doesn't undo a past
eviction, it only changes what's allowed to happen going forward:

```
node/k8s-lab-default-worker untainted

Error from server (NotFound): pods "scheduling-demo-notoleration-pod" not found
```

That's the last of the placement mechanisms - the rest of this chapter
shifts from where a Pod can land to how much of a node it's allowed to
consume once it's there, and from a single Pod's own spec to limits
enforced across an entire namespace.

### Resource requests and limits

**Why**: `requests` is what the scheduler actually bin-packs against -
a node needs that much allocatable capacity free before a Pod can land
there at all, regardless of what the Pod ends up actually using.
`limits` is a runtime ceiling enforced by the container runtime via
cgroups (Linux kernel control groups - the mechanism that actually
constrains a process's resource usage), checked independently of
scheduling. The two together produce
a Pod's **QoS class**: `Guaranteed` (every container's requests equal
its limits), `Burstable` (requests set but lower than limits, or only
some containers have both), `BestEffort` (neither set at all) - which
matters most under real node memory pressure, where `BestEffort` and
`Burstable` Pods are evicted before `Guaranteed` ones. Exceeding a
memory limit gets a container `OOMKilled` outright; exceeding a CPU
limit only throttles it - CPU can't be "killed" the way memory can,
there's nothing to reclaim by force.

**Example**: `tutorial/examples/scheduling/resource-qos-pod.yaml` sets
requests equal to limits:

```
kubectl apply -f tutorial/examples/scheduling/resource-qos-pod.yaml
kubectl get pod scheduling-demo-qos-pod -o jsonpath='{.status.qosClass}'
```

**Expected output**:

```
Guaranteed
```

`tutorial/examples/scheduling/resource-oom-pod.yaml` deliberately
allocates more memory (150M) than its limit (100Mi) allows, using the
`polinux/stress` image (the standard tool for this exact demonstration):

```
kubectl apply -f tutorial/examples/scheduling/resource-oom-pod.yaml
kubectl get pod scheduling-demo-oom-pod -o jsonpath='{.status.qosClass}'
kubectl get pod scheduling-demo-oom-pod
kubectl describe pod scheduling-demo-oom-pod | grep -A5 "Last State"
```

**Expected output**: `Burstable` (requests set, lower than limits), then
a real, repeated OOMKill as the container tries to allocate 150M against
a 100Mi limit, restarting into `CrashLoopBackOff` as it keeps hitting
the same wall:

```
Burstable
```

```
NAME                      READY   STATUS      RESTARTS      AGE
scheduling-demo-oom-pod   0/1     OOMKilled   0             6s
scheduling-demo-oom-pod   0/1     OOMKilled   1 (6s ago)    9s
scheduling-demo-oom-pod   0/1     CrashLoopBackOff   1 (14s ago)   21s
scheduling-demo-oom-pod   0/1     OOMKilled   2 (17s ago)   24s
```

```
    Last State:     Terminated
      Reason:       OOMKilled
      Exit Code:    137
      Started:      Fri, 28 Aug 2026 15:20:54 +1000
      Finished:     Fri, 28 Aug 2026 15:20:54 +1000
    Ready:          False
    Restart Count:  2
```

`Exit Code: 137` is `128 + 9` - `SIGKILL`, sent by the kernel's cgroup
OOM killer, not something the process could catch or clean up after.
Unlike the CPU case, there's no throttling option for memory: once a
cgroup hits its hard limit, the kernel has to reclaim the memory by
force, and the only way to do that to a process is to kill it.

### ResourceQuota: capping aggregate consumption per namespace

**Why**: everything in the previous section is per-Pod and voluntary -
nothing stops a namespace from accumulating an unbounded number of
Pods, or Pods with arbitrarily large requests/limits, until the
*node's* real capacity runs out. ResourceQuota caps totals across an
entire namespace instead - aggregate `requests.cpu`/`requests.memory`,
aggregate `limits.cpu`/`limits.memory`, object counts like `pods` - and
it has a second, easy-to-miss effect: once a ResourceQuota constrains a
compute resource (`limits.cpu`/`limits.memory` here), the apiserver
requires *every* Pod created in that namespace to explicitly declare
that resource, rejecting any Pod that doesn't, even one that would
easily fit within the remaining quota.

**Example**: `tutorial/examples/scheduling/governance-namespace.yaml`
and `tutorial/examples/scheduling/resourcequota.yaml` (hard caps:
`requests.cpu: 500m`, `requests.memory: 256Mi`, `limits.cpu: 1`,
`limits.memory: 512Mi`, `pods: 3`), then two Pods that each fail for a
different reason:

```
kubectl apply -f tutorial/examples/scheduling/governance-namespace.yaml
kubectl apply -f tutorial/examples/scheduling/resourcequota.yaml
kubectl apply -f tutorial/examples/scheduling/quota-noresources-pod.yaml
kubectl apply -f tutorial/examples/scheduling/quota-exceeding-pod.yaml
kubectl describe resourcequota scheduling-demo-quota -n scheduling-demo-governance
```

**Expected output**: both Pods rejected outright, before either is ever
stored - but for two distinguishable reasons, worth seeing verbatim
rather than assuming they'd look the same:

```
$ kubectl apply -f tutorial/examples/scheduling/quota-noresources-pod.yaml
Error from server (Forbidden): error when creating "tutorial/examples/scheduling/quota-noresources-pod.yaml": pods "scheduling-demo-noresources-pod" is forbidden: failed quota: scheduling-demo-quota: must specify limits.cpu for: nginx; limits.memory for: nginx; requests.cpu for: nginx; requests.memory for: nginx
```

That one lists exactly which fields are missing - nothing about
capacity, purely "you didn't declare this." The exceeding Pod, which
*does* declare everything, fails on the numbers instead:

```
$ kubectl apply -f tutorial/examples/scheduling/quota-exceeding-pod.yaml
Error from server (Forbidden): error when creating "tutorial/examples/scheduling/quota-exceeding-pod.yaml": pods "scheduling-demo-exceeding-pod" is forbidden: exceeded quota: scheduling-demo-quota, requested: limits.memory=600Mi,requests.memory=300Mi, used: limits.memory=0,requests.memory=0, limited: limits.memory=512Mi,requests.memory=256Mi
```

`requested`/`used`/`limited` spelled out explicitly - this Pod alone
would have pushed `limits.memory` to 600Mi against a 512Mi hard cap.
Since both applies were rejected, nothing was ever actually created:

```
$ kubectl describe resourcequota scheduling-demo-quota -n scheduling-demo-governance
Name:            scheduling-demo-quota
Namespace:       scheduling-demo-governance
Resource         Used  Hard
--------         ----  ----
limits.cpu       0     1
limits.memory    0     512Mi
pods             0     3
requests.cpu     0     500m
requests.memory  0     256Mi
```

**Storage has its own quota dimension**, separate from the CPU/memory
one above: `persistentvolumeclaims` caps the PVC *count* the same way
`pods` caps Pod count, and `requests.storage` caps the aggregate of
every PVC's `spec.resources.requests.storage` in the namespace. A
namespace can carry more than one ResourceQuota object - every one that
applies to a given resource is enforced independently - so
`tutorial/examples/scheduling/resourcequota-storage.yaml` adds a second
quota object to the same namespace rather than editing the one above.
The caveat worth stating plainly: `requests.storage` tracks the
*declared* size on each PVC's spec, not any actual bytes written to the
backing volume - a PVC counts fully against quota the moment it's
created, whether or not it's even bound yet, and stays counted at its
full declared size no matter how little (or how much, if the storage
backend doesn't enforce capacity) ends up written to it.

**Example**: apply the storage quota, then
`tutorial/examples/scheduling/quota-storage-pvc.yaml` (a PVC declaring
`1Gi`) - and check the quota's `Used` column *before* anything binds
it:

```
kubectl apply -f tutorial/examples/scheduling/resourcequota-storage.yaml
kubectl apply -f tutorial/examples/scheduling/quota-storage-pvc.yaml
kubectl get pvc scheduling-demo-quota-pvc -n scheduling-demo-governance
kubectl describe resourcequota scheduling-demo-storage-quota -n scheduling-demo-governance
```

**Expected output**: the PVC is `Pending` - this repo's default
StorageClass uses `WaitForFirstConsumer` (chapter 4), so nothing is
provisioned until a Pod actually mounts it - yet the quota already
shows the full `1Gi` used, counted from the claim's spec alone:

```
NAME                        STATUS    VOLUME   CAPACITY   ACCESS MODES   STORAGECLASS   AGE
scheduling-demo-quota-pvc   Pending                                      standard       0s

Name:                   scheduling-demo-storage-quota
Namespace:              scheduling-demo-governance
Resource                Used  Hard
--------                ----  ----
persistentvolumeclaims  1     2
requests.storage        1Gi   2Gi
```

Now bind it with `tutorial/examples/scheduling/quota-storage-pod.yaml`
(mounts the PVC, writes a handful of bytes) and compare what's actually
on disk to what the quota still reports:

```
kubectl apply -f tutorial/examples/scheduling/quota-storage-pod.yaml
kubectl exec -n scheduling-demo-governance scheduling-demo-quota-storage-pod -- du -sh /data
kubectl describe resourcequota scheduling-demo-storage-quota -n scheduling-demo-governance
```

**Expected output**: `8.0K` of real content against a `1Gi` declared
claim - this lab's `local-path-provisioner` backing store is a plain
hostPath directory with no real capacity enforcement at all, so nothing
stops it from holding far less (or, unenforced, far more) than
declared - and the quota's `Used` is unchanged, still `1Gi`, exactly
what it showed while the PVC was still unbound and empty:

```
8.0K	/data

Resource                Used  Hard
--------                ----  ----
persistentvolumeclaims  1     2
requests.storage        1Gi   2Gi
```

ResourceQuota is bookkeeping against declared intent, the identical
principle the requests/limits section above already established for CPU
and memory - not a live measurement of what a namespace's Pods and PVCs
are actually consuming right now.

### LimitRange: defaults so Pods don't have to specify resources every time

**Why**: the previous section's first rejection is exactly what
LimitRange resolves - it sets a `default` (limits) and `defaultRequest`
(requests) that get injected into any container in the namespace that
doesn't specify its own, and can additionally enforce per-container
min/max bounds. Once a LimitRange exists, a Pod that mentions no
resources at all - the same one ResourceQuota rejected above - gets
the LimitRange's defaults filled in automatically at admission time and
satisfies the quota's "must declare limits" requirement without ever
mentioning resources itself.

**Example**: `tutorial/examples/scheduling/limitrange.yaml` sets
`default` (500m CPU / 256Mi memory) and `defaultRequest` (250m CPU /
128Mi memory) for the namespace, then the exact same
`quota-noresources-pod.yaml` that was rejected above is re-applied:

```
kubectl apply -f tutorial/examples/scheduling/limitrange.yaml
kubectl apply -f tutorial/examples/scheduling/quota-noresources-pod.yaml
kubectl get pod scheduling-demo-noresources-pod -n scheduling-demo-governance -o jsonpath='{.spec.containers[0].resources}'
```

**Expected output**: the exact same manifest that was rejected in the
previous section now succeeds, with the LimitRange's `default`/
`defaultRequest` values injected into the Pod spec even though the
manifest itself never mentions `resources` at all:

```
$ kubectl apply -f tutorial/examples/scheduling/limitrange.yaml
limitrange/scheduling-demo-limits created

$ kubectl apply -f tutorial/examples/scheduling/quota-noresources-pod.yaml
pod/scheduling-demo-noresources-pod created

$ kubectl get pod scheduling-demo-noresources-pod -n scheduling-demo-governance -o jsonpath='{.spec.containers[0].resources}'
{"limits":{"cpu":"500m","memory":"256Mi"},"requests":{"cpu":"250m","memory":"128Mi"}}
```

Exactly the LimitRange's `default` (500m/256Mi) and `defaultRequest`
(250m/128Mi) values, admission-injected before the ResourceQuota check
even ran - which is why the same Pod that failed the "must specify"
check above now clears it automatically. The quota's own `Used` column
confirms one Pod is now actually running, consuming exactly those
defaulted amounts:

```
$ kubectl describe resourcequota scheduling-demo-quota -n scheduling-demo-governance
Name:            scheduling-demo-quota
Namespace:       scheduling-demo-governance
Resource         Used   Hard
--------         ----   ----
limits.cpu       500m   1
limits.memory    256Mi  512Mi
pods             1      3
requests.cpu     250m   500m
requests.memory  128Mi  256Mi
```
