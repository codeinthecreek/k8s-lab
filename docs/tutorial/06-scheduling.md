# 6. Scheduling and resource management

Every chapter so far has relied on the scheduler placing Pods somewhere
sensible without saying anything about it. This chapter makes that
placement decision itself the subject: the same label/selector mechanism
already used for ReplicaSets (chapter 3) and Services (chapter 5),
applied to nodes; the two ways to influence where a Pod can and can't
land (affinity, taints/tolerations); the resource requests/limits that
shape *how much* of a node a Pod is allowed to consume once it's there;
and, closing the loop from a single Pod to an entire namespace,
ResourceQuota and LimitRange - the mechanism that turns a namespace from
a bare naming scope into an actual resource boundary.

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

### Resource requests and limits

**Why**: `requests` is what the scheduler actually bin-packs against -
a node needs that much allocatable capacity free before a Pod can land
there at all, regardless of what the Pod ends up actually using.
`limits` is a runtime ceiling enforced by the container runtime via
cgroups, checked independently of scheduling. The two together produce
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
