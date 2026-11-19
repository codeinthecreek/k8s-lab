# 7. Scheduling and resource management

So far, the scheduler has picked a node for every Pod without you
having a say. This chapter is about influencing that choice, and about
how much of a node a Pod may use once it's there:

- **Where a Pod can run**: node affinity and pod affinity, which use
  the same labels and selectors as ReplicaSets (chapter 3) and Services
  (chapter 5), and taints and tolerations.
- **How much it may use**: resource requests and limits.
- **Who gets the room when a node is full**: PriorityClass and
  preemption.
- **Limits for a whole namespace**: ResourceQuota and LimitRange.

Configuring the scheduler itself is a separate topic, covered in
chapter 14.

### Labels and selectors on nodes

**Why**: a ReplicaSet finds its Pods by label, and so does a Service.
Node affinity, below, finds **nodes** by label, with the same kind of
selector.

Selectors come in two forms. `matchLabels` lists `key: value` pairs
that must match exactly. `matchExpressions` is more flexible: each
expression has a key, an operator (`In`, `NotIn`, `Exists`,
`DoesNotExist`) and a list of values. Node affinity only uses the
`matchExpressions` form, which is why it looks a little different from
a ReplicaSet's selector.

**Example**: a node is an object like any other, so you can label it:

```
kubectl label node k8s-lab-default-worker scheduling-demo/zone=zone-a
kubectl get nodes -l scheduling-demo/zone=zone-a
```

**Expected output**: only the node you labelled:

```
node/k8s-lab-default-worker labeled

NAME                     STATUS   ROLES    AGE     VERSION
k8s-lab-default-worker   Ready    <none>   6m24s   v1.36.1
```

### Node affinity: choosing nodes by label

**Why**: the simplest way to choose nodes is `nodeSelector`: a list of
labels a node must have, all of them, with exact values. **Node
affinity** does the same job with selector expressions, and comes in
two strengths:

- `requiredDuringSchedulingIgnoredDuringExecution`: a hard rule. If no
  node matches, the Pod stays `Pending`.
- `preferredDuringSchedulingIgnoredDuringExecution`: a preference. The
  scheduler tries to follow it, but uses another node if it has to.

`IgnoredDuringExecution` means the rule is only checked when the Pod is
scheduled. If you change a node's labels later, Pods already running
there stay where they are.

**Example**: [`node-affinity-pod.yaml`](examples/scheduling/node-affinity-pod.yaml)
requires `scheduling-demo/zone=zone-a`, the label you just put on
`k8s-lab-default-worker`:

```
kubectl apply -f tutorial/examples/scheduling/node-affinity-pod.yaml
kubectl get pod scheduling-demo-affinity-pod -o wide
```

**Expected output**: the Pod runs on the labelled node (on a new cluster
it may show `ContainerCreating` for a minute while `nginx:1.27` is
pulled; the `NODE` is already set):

```
NAME                           READY   STATUS    RESTARTS   AGE   IP           NODE                     NOMINATED NODE   READINESS GATES
scheduling-demo-affinity-pod   1/1     Running   0          78s   10.244.2.7   k8s-lab-default-worker   <none>           <none>
```

Now a Pod that requires a label value no node has:

```
kubectl apply -f tutorial/examples/scheduling/node-affinity-impossible-pod.yaml
kubectl get pod scheduling-demo-affinity-impossible-pod
kubectl describe pod scheduling-demo-affinity-impossible-pod | grep -A3 Events:
```

**Expected output**: the Pod stays `Pending`. The `FailedScheduling`
event gives a reason for every node:

```
NAME                                      READY   STATUS    RESTARTS   AGE
scheduling-demo-affinity-impossible-pod   0/1     Pending   0          5s
Events:
  Type     Reason            Age   From               Message
  ----     ------            ----  ----               -------
  Warning  FailedScheduling  5s    default-scheduler  0/3 nodes are available: 1 node(s) had untolerated taint(s), 2 node(s) didn't match Pod's node affinity/selector. no new claims to deallocate, preemption: 0/3 nodes are available: 3 Preemption is not helpful for scheduling.
```

Three nodes, two reasons. The two workers don't have the required
label. The control-plane node is excluded because of its
`NoSchedule` taint (chapter 1; taints are explained later in this
chapter), which keeps ordinary Pods off it whatever their affinity.
The end of the message is about preemption, covered later in this
chapter: evicting other Pods wouldn't help, since no node can ever
match.

### Pod affinity and anti-affinity: placing Pods near or apart from others

**Why**: node affinity looks at the node's labels. **Pod affinity** and
**pod anti-affinity** look at which *Pods* are already running on a
node:

- `podAffinity` puts a new Pod on a node that already runs a Pod
  matching its `labelSelector`. Useful for a cache that should sit next
  to the service that uses it most.
- `podAntiAffinity` keeps a new Pod off such a node. Useful for spreading
  replicas, so that one node failing can't take them all down.

Both have the same `required...` and `preferred...` strengths as node
affinity. They also need a `topologyKey`: a node label that defines what
"the same place" means. With `kubernetes.io/hostname` it means the same
node. On a cloud cluster, `topology.kubernetes.io/zone` would mean the
same zone. kind nodes have no zone labels, so the examples here use
`kubernetes.io/hostname`.

**Example**: first an ordinary Pod labelled `app=scheduling-demo-colocate`,
[`pod-affinity-anchor-pod.yaml`](examples/scheduling/pod-affinity-anchor-pod.yaml),
with no rules of its own. The other Pods will be placed relative to
it:

```
kubectl apply -f tutorial/examples/scheduling/pod-affinity-anchor-pod.yaml
kubectl get pod scheduling-demo-colocate-anchor -o wide
```

**Expected output**: it runs on whichever worker the scheduler picks,
here `k8s-lab-default-worker2`:

```
NAME                              READY   STATUS    RESTARTS   AGE   IP           NODE                      NOMINATED NODE   READINESS GATES
scheduling-demo-colocate-anchor   1/1     Running   0          65s   10.244.1.5   k8s-lab-default-worker2   <none>           <none>
```

[`pod-affinity-pod.yaml`](examples/scheduling/pod-affinity-pod.yaml)
requires a node that already runs a Pod labelled
`app=scheduling-demo-colocate`:

```
kubectl apply -f tutorial/examples/scheduling/pod-affinity-pod.yaml
kubectl get pod scheduling-demo-affinity-copod -o wide
```

**Expected output**: it runs on the same node as the first Pod:

```
NAME                             READY   STATUS    RESTARTS   AGE   IP           NODE                      NOMINATED NODE   READINESS GATES
scheduling-demo-affinity-copod   1/1     Running   0          56s   10.244.1.6   k8s-lab-default-worker2   <none>           <none>
```

[`pod-anti-affinity-pod.yaml`](examples/scheduling/pod-anti-affinity-pod.yaml)
does the opposite: it requires a node that does *not* run a Pod
labelled `app=scheduling-demo-colocate`:

```
kubectl apply -f tutorial/examples/scheduling/pod-anti-affinity-pod.yaml
kubectl get pod scheduling-demo-antiaffinity-pod -o wide
```

**Expected output**: it runs on the other worker:

```
NAME                               READY   STATUS    RESTARTS   AGE   IP           NODE                     NOMINATED NODE   READINESS GATES
scheduling-demo-antiaffinity-pod   1/1     Running   0          48s   10.244.2.8   k8s-lab-default-worker   <none>           <none>
```

Both rules matched the same label, `app=scheduling-demo-colocate`, and
placed their Pods in opposite places. Nothing about the nodes
themselves was involved.

### Taints and tolerations: nodes turning Pods away

**Why**: affinity is a Pod choosing nodes. A **taint** works the other
way round: a node turns Pods away, except Pods that **tolerate** the
taint. You've already met one: kind's control-plane node has the taint
`node-role.kubernetes.io/control-plane:NoSchedule`, so ordinary Pods
don't run there.

A taint has a key, an optional value, and an **effect**. There are
three effects, and the API documentation describes them:

```
kubectl explain node.spec.taints.effect
```

```
KIND:       Node
VERSION:    v1

FIELD: effect <string>
ENUM:
    NoExecute
    NoSchedule
    PreferNoSchedule

DESCRIPTION:
    Required. The effect of the taint on pods that do not tolerate the taint.
    Valid effects are NoSchedule, PreferNoSchedule and NoExecute.
    
    Possible enum values:
     - `"NoExecute"` Evict any already-running pods that do not tolerate the
    taint. Currently enforced by NodeController.
     - `"NoSchedule"` Do not allow new pods to schedule onto the node unless
    they tolerate the taint, but allow all pods submitted to Kubelet without
    going through the scheduler to start, and allow all already-running pods to
    continue running. Enforced by the scheduler.
     - `"PreferNoSchedule"` Like TaintEffectNoSchedule, but the scheduler tries
    not to schedule new pods onto the node, rather than prohibiting new pods
    from scheduling onto the node entirely. Enforced by the scheduler.
```

So `NoSchedule` only stops *new* Pods; Pods already on the node keep
running. `NoExecute` also evicts the Pods already running there.
Removing a taint doesn't undo anything: evicted Pods don't come back,
and nothing moves back to the node just because it now could.

**Example**: start a Pod with no toleration on the labelled node:

```
kubectl apply -f tutorial/examples/scheduling/taint-pretaint-pod.yaml
kubectl get pod scheduling-demo-notoleration-pod -o wide
```

```
pod/scheduling-demo-notoleration-pod created
NAME                               READY   STATUS    RESTARTS   AGE   IP           NODE                     NOMINATED NODE   READINESS GATES
scheduling-demo-notoleration-pod   1/1     Running   0          6s    10.244.2.9   k8s-lab-default-worker   <none>           <none>
```

Now give the node a `NoExecute` taint:

```
kubectl taint node k8s-lab-default-worker scheduling-demo=maintenance:NoExecute
```

```
node/k8s-lab-default-worker tainted
```

A few seconds later, the Pod has been evicted and deleted. (If you look
quickly, you may see it as `Completed` first: nginx exits cleanly when
it's told to stop.)

```
kubectl get pod scheduling-demo-notoleration-pod
```

```
Error from server (NotFound): pods "scheduling-demo-notoleration-pod" not found
```

The taint applies to every Pod on the node, so
`scheduling-demo-affinity-pod` and `scheduling-demo-antiaffinity-pod`
from the affinity sections, which also ran on `k8s-lab-default-worker`,
were evicted too. `kubectl get pods -o wide` no longer lists them.

A Pod that tolerates the taint can be scheduled on the node and
stays there:

```
kubectl apply -f tutorial/examples/scheduling/toleration-pod.yaml
kubectl get pod scheduling-demo-toleration-pod -o wide
```

**Expected output**: it runs on the tainted node:

```
pod/scheduling-demo-toleration-pod created
NAME                             READY   STATUS    RESTARTS   AGE   IP            NODE                     NOMINATED NODE   READINESS GATES
scheduling-demo-toleration-pod   1/1     Running   0          4s    10.244.2.13   k8s-lab-default-worker   <none>           <none>
```

Run the `get` again after 10 seconds or so: it's still running, not
evicted.

Removing the taint doesn't bring back the evicted Pod. It was a bare Pod
(chapter 3), with no controller to recreate it:

```
kubectl taint node k8s-lab-default-worker scheduling-demo:NoExecute-
kubectl get pod scheduling-demo-notoleration-pod
```

**Expected output**: the Pod is still gone. Removing a taint only
changes what can happen from now on:

```
node/k8s-lab-default-worker untainted
Error from server (NotFound): pods "scheduling-demo-notoleration-pod" not found
```

### Resource requests and limits

**Why**: each container can declare **requests** and **limits** for CPU
and memory.

- A **request** is what the scheduler uses. A Pod only goes on a node
  that has at least that much CPU and memory not yet requested by other
  Pods, whatever the Pod actually uses later.
- A **limit** is a ceiling, enforced while the container runs, through
  the Linux kernel's control groups (cgroups). A container that goes
  over its memory limit is killed (`OOMKilled`, out of memory). One that
  tries to go over its CPU limit is slowed down (throttled) instead: CPU
  time can simply be withheld, but memory a process holds can't be
  taken back without killing it.

From the requests and limits, Kubernetes gives each Pod a **QoS class**
(quality of service):

- `Guaranteed`: every container has requests equal to its limits.
- `Burstable`: at least one request or limit is set, but it isn't
  `Guaranteed`.
- `BestEffort`: no requests or limits at all.

The QoS class decides which Pods the kubelet evicts first when a node
runs short of memory. It isn't the same as priority, which is the next
section.

**Example**: [`resource-qos-pod.yaml`](examples/scheduling/resource-qos-pod.yaml)
sets requests equal to limits:

```
kubectl apply -f tutorial/examples/scheduling/resource-qos-pod.yaml
kubectl get pod scheduling-demo-qos-pod -o jsonpath='{.status.qosClass}'
```

**Expected output**:

```
Guaranteed
```

[`resource-oom-pod.yaml`](examples/scheduling/resource-oom-pod.yaml)
has a memory limit of 100Mi and uses the `polinux/stress` image to
allocate 150M, more than the limit:

```
kubectl apply -f tutorial/examples/scheduling/resource-oom-pod.yaml
kubectl get pod scheduling-demo-oom-pod -o jsonpath='{.status.qosClass}'
```

**Expected output**: `Burstable` (requests are set, but lower than the
limits):

```
pod/scheduling-demo-oom-pod created
Burstable
```

Watch the Pod for a minute with `-w`, then stop with Ctrl-C:

```
kubectl get pod scheduling-demo-oom-pod -w
```

**Expected output**: each time the container starts, it's killed for
using too much memory (`OOMKilled`) and restarted, with longer waits in
`CrashLoopBackOff` in between:

```
NAME                      READY   STATUS    RESTARTS   AGE
scheduling-demo-oom-pod   0/1     Pending   0          0s
scheduling-demo-oom-pod   0/1     ContainerCreating   0          0s
scheduling-demo-oom-pod   0/1     ContainerCreating   0          1s
scheduling-demo-oom-pod   1/1     Running             0          12s
scheduling-demo-oom-pod   0/1     OOMKilled           0          13s
scheduling-demo-oom-pod   1/1     Running             1 (5s ago)   16s
scheduling-demo-oom-pod   0/1     OOMKilled           1 (5s ago)   16s
scheduling-demo-oom-pod   0/1     CrashLoopBackOff    1 (15s ago)   30s
scheduling-demo-oom-pod   1/1     Running             2 (18s ago)   33s
scheduling-demo-oom-pod   0/1     OOMKilled           2 (18s ago)   33s
scheduling-demo-oom-pod   0/1     CrashLoopBackOff    2 (23s ago)   55s
scheduling-demo-oom-pod   1/1     Running             3 (26s ago)   58s
scheduling-demo-oom-pod   0/1     OOMKilled           3 (27s ago)   59s
```

`kubectl describe` shows how the last run ended:

```
kubectl describe pod scheduling-demo-oom-pod | grep -A5 "Last State"
```

```
    Last State:     Terminated
      Reason:       OOMKilled
      Exit Code:    137
      Started:      Thu, 19 Nov 2026 11:32:24 +0000
      Finished:     Thu, 19 Nov 2026 11:32:24 +0000
    Ready:          False
```

Exit code 137 means the process was killed by signal 9, `SIGKILL`
(137 = 128 + 9). The kernel sent it when the container reached its
memory limit. A process can't catch `SIGKILL`, so it gets no chance to
clean up.

Requests decide whether a Pod fits on a node. What happens when a node
is full and a more important Pod arrives? That's what priority is
for.

### PriorityClass and preemption

**Why**: normally, a Pod that fits on no node stays `Pending`, even if
the room it needs is used by much less important Pods. **Pod priority**
changes that.

A **PriorityClass** gives a name to a number, its `value`. It's
cluster-wide (it has no namespace). A Pod chooses a class with
`spec.priorityClassName`, and the API server copies the class's number
into the Pod's `spec.priority`. When a Pod with a higher number fits on
no node, the scheduler looks for a node where evicting lower-priority
Pods would make enough room. If it finds one, it evicts them and puts
the new Pod there. That's **preemption**.

A class's `preemptionPolicy` controls this. The default,
`PreemptLowerPriority`, allows it. With `Never`, a Pod gets the same
priority number, but if it doesn't fit, it waits rather than evicting
anything.

Every cluster has two built-in classes, `system-cluster-critical` and
`system-node-critical`, for Kubernetes's own components. Classes you
create can't have a value above 1000000000; the range above that is
reserved for those two.

A Pod that names no class gets priority `0`. You can mark one class
`globalDefault: true`, and then Pods created afterwards without a class
get that class instead. Only one class can be the global default. This
chapter doesn't try it, because it affects every new Pod in the
cluster.

**Example**: list the built-in classes, then add three:
[`priorityclasses.yaml`](examples/scheduling/priorityclasses.yaml)
defines a low class, a high class, and a second high class with
`preemptionPolicy: Never`:

```
kubectl get priorityclass
kubectl apply -f tutorial/examples/scheduling/priorityclasses.yaml
kubectl get priorityclass
```

**Expected output**:

```
NAME                      VALUE        GLOBAL-DEFAULT   AGE   PREEMPTIONPOLICY
system-cluster-critical   2000000000   false            11m   PreemptLowerPriority
system-node-critical      2000001000   false            11m   PreemptLowerPriority
priorityclass.scheduling.k8s.io/scheduling-demo-low created
priorityclass.scheduling.k8s.io/scheduling-demo-high created
priorityclass.scheduling.k8s.io/scheduling-demo-high-nopreempt created
NAME                             VALUE        GLOBAL-DEFAULT   AGE   PREEMPTIONPOLICY
scheduling-demo-high             100000       false            0s    PreemptLowerPriority
scheduling-demo-high-nopreempt   100000       false            0s    Never
scheduling-demo-low              1000         false            0s    PreemptLowerPriority
system-cluster-critical          2000000000   false            11m   PreemptLowerPriority
system-node-critical             2000001000   false            11m   PreemptLowerPriority
```

A Pod that names no class, for comparison
([`priority-default-pod.yaml`](examples/scheduling/priority-default-pod.yaml)):

```
kubectl apply -f tutorial/examples/scheduling/priority-default-pod.yaml
kubectl get pod scheduling-demo-priority-default -o jsonpath='{.spec.priority}{"\n"}'
kubectl delete pod scheduling-demo-priority-default
```

**Expected output**:

```
pod/scheduling-demo-priority-default created
0
pod "scheduling-demo-priority-default" deleted from default namespace
```

**Filling a node**: preemption only happens when a Pod doesn't fit. How
much CPU a kind node has depends on your machine, since kind nodes share
the host's CPUs, so the demo works out its Pod sizes from the node's
own numbers. Everything below uses `k8s-lab-default-worker`, the node
used earlier in this chapter.

First, check what's running on the worker apart from system Pods. The
scheduler can evict any lower-priority Pod to make room, so a Pod left
over from an earlier section would also be at risk. The listing leaves
out the `kube-system` namespace and Pods that have finished:

```
NODE=k8s-lab-default-worker
kubectl get pods -A --field-selector spec.nodeName=$NODE,metadata.namespace!=kube-system,status.phase!=Succeeded,status.phase!=Failed
```

**Expected output**: if you've followed the chapter so far, three Pods
from earlier sections are still on the worker:

```
NAMESPACE   NAME                             READY   STATUS      RESTARTS      AGE
default     scheduling-demo-oom-pod          0/1     OOMKilled   3 (38s ago)   70s
default     scheduling-demo-qos-pod          1/1     Running     0             70s
default     scheduling-demo-toleration-pod   1/1     Running     0             89s
```

Delete every Pod from earlier in this chapter (`--ignore-not-found`
skips the ones that are already gone), then list again until nothing
is left. Pods you've just deleted can show as `Terminating` for a
while:

```
kubectl delete pod --ignore-not-found scheduling-demo-affinity-pod scheduling-demo-affinity-impossible-pod scheduling-demo-colocate-anchor scheduling-demo-affinity-copod scheduling-demo-antiaffinity-pod scheduling-demo-notoleration-pod scheduling-demo-toleration-pod scheduling-demo-qos-pod scheduling-demo-oom-pod
kubectl get pods -A --field-selector spec.nodeName=$NODE,metadata.namespace!=kube-system,status.phase!=Succeeded,status.phase!=Failed
```

```
No resources found
```

Pods from other chapters would be at risk too. If the listing shows
any, delete them, or start from a fresh cluster with `make reset`.

Then work out the sizes. The low-priority "filler" Pod will take 60% of
the worker's free CPU, and the high-priority Pod will ask for 50%. So
the high-priority Pod can't fit next to the filler, but fits easily
once the filler is gone. Look up the worker's allocatable CPU and how
much is already requested:

```
kubectl get node $NODE -o jsonpath='{.status.allocatable.cpu}{"\n"}'
kubectl describe node $NODE | grep -A6 "^Allocated resources"
```

**Expected output**: these numbers come from a machine with 8 CPUs;
yours will differ:

```
8
Allocated resources:
  (Total limits may be over 100 percent, i.e., overcommitted.)
  Resource           Requests   Limits
  --------           --------   ------
  cpu                100m (1%)  100m (1%)
  memory             50Mi (0%)  50Mi (0%)
  ephemeral-storage  0 (0%)     0 (0%)
```

CPU is counted in millicores: `8` CPUs is `8000m`. Here the free CPU is
8000m - 100m = 7900m, so the filler gets 60% of that, 4740m, and the
high-priority Pod 50%, 3950m. Set them for the commands below, with
your own numbers:

```
FILL_CPU=4740m
HIGH_CPU=3950m
```

**Example**: start the low-priority filler,
[`priority-filler-pod.yaml`](examples/scheduling/priority-filler-pod.yaml).
The file has a placeholder, `__FILL_CPU__`, which `sed` replaces with
your number, so you can't apply the file as it is:

```
sed "s/__FILL_CPU__/$FILL_CPU/" tutorial/examples/scheduling/priority-filler-pod.yaml | kubectl apply -f -
```

```
pod/scheduling-demo-priority-filler created
```

When it's running:

```
kubectl get pod scheduling-demo-priority-filler -o wide
```

```
NAME                              READY   STATUS    RESTARTS   AGE   IP            NODE                     NOMINATED NODE   READINESS GATES
scheduling-demo-priority-filler   1/1     Running   0          6s    10.244.2.16   k8s-lab-default-worker   <none>           <none>
```

First, a high-priority Pod that isn't allowed to preempt.
[`priority-nopreempt-pod.yaml`](examples/scheduling/priority-nopreempt-pod.yaml)
uses the class with `preemptionPolicy: Never`, and requests
`HIGH_CPU`, which is more than the 40% of `FREE` that's left:

```
sed "s/__HIGH_CPU__/$HIGH_CPU/" tutorial/examples/scheduling/priority-nopreempt-pod.yaml | kubectl apply -f -
kubectl get pods -o wide
kubectl describe pod scheduling-demo-priority-nopreempt | grep -A3 Events:
```

**Expected output**: the new Pod is `Pending`, the filler is untouched,
and the event says why nothing was preempted:

```
pod/scheduling-demo-priority-nopreempt created
NAME                                 READY   STATUS    RESTARTS   AGE   IP            NODE                     NOMINATED NODE   READINESS GATES
scheduling-demo-priority-filler      1/1     Running   0          10s   10.244.2.16   k8s-lab-default-worker   <none>           <none>
scheduling-demo-priority-nopreempt   0/1     Pending   0          3s    <none>        <none>                   <none>           <none>
Events:
  Type     Reason            Age   From               Message
  ----     ------            ----  ----               -------
  Warning  FailedScheduling  3s    default-scheduler  0/3 nodes are available: 1 Insufficient cpu, 1 node(s) didn't match Pod's node affinity/selector, 1 node(s) had untolerated taint(s). no new claims to deallocate, preemption: not eligible due to preemptionPolicy=Never.
```

Three nodes, three reasons: the worker doesn't have enough CPU, the
other worker doesn't match the Pod's `nodeSelector`, and the
control-plane node has its taint. The last part, `not eligible due to
preemptionPolicy=Never`, is the one that matters here. If you wait,
nothing changes.

Now the same request with the default policy. Delete the `Never` Pod
first, so it can't take the room that's about to be freed. Then apply
[`priority-preempt-pod.yaml`](examples/scheduling/priority-preempt-pod.yaml),
which uses `scheduling-demo-high`, and look straight away:

```
kubectl delete pod scheduling-demo-priority-nopreempt
sed "s/__HIGH_CPU__/$HIGH_CPU/" tutorial/examples/scheduling/priority-preempt-pod.yaml | kubectl apply -f -
kubectl get pods -o wide
kubectl get pod scheduling-demo-priority-filler -o jsonpath='{range .status.conditions[?(@.type=="DisruptionTarget")]}{.reason}: {.message}{"\n"}{end}'
```

**Expected output**: the new Pod is `Pending`, with `NOMINATED NODE`
set: the scheduler has picked the worker for it and is waiting for room.
The filler may still show `Running`, but its `DisruptionTarget`
condition already says it's being removed, and why:

```
pod "scheduling-demo-priority-nopreempt" deleted from default namespace
pod/scheduling-demo-priority-preempt created
NAME                               READY   STATUS    RESTARTS   AGE   IP            NODE                     NOMINATED NODE           READINESS GATES
scheduling-demo-priority-filler    1/1     Running   0          15s   10.244.2.16   k8s-lab-default-worker   <none>                   <none>
scheduling-demo-priority-preempt   0/1     Pending   0          0s    <none>        <none>                   k8s-lab-default-worker   <none>
PreemptionByScheduler: default-scheduler: preempting to accommodate a higher priority pod
```

A few seconds later, `kubectl get pods -o wide` shows the filler
`Terminating`:

```
NAME                               READY   STATUS        RESTARTS   AGE   IP            NODE                     NOMINATED NODE           READINESS GATES
scheduling-demo-priority-filler    1/1     Terminating   0          20s   10.244.2.16   k8s-lab-default-worker   <none>                   <none>
scheduling-demo-priority-preempt   0/1     Pending       0          5s    <none>        <none>                   k8s-lab-default-worker   <none>
```

The filler stays `Terminating` for about 30 seconds. Its only process,
`sleep`, ignores the `SIGTERM` that asks it to stop, so Kubernetes
waits for the default 30-second grace period before killing it.
Preemption waits too: the new Pod isn't started until the filler is
gone. After about 30 seconds, run `kubectl get pods -o wide` again:

```
NAME                               READY   STATUS    RESTARTS   AGE   IP            NODE                     NOMINATED NODE   READINESS GATES
scheduling-demo-priority-preempt   1/1     Running   0          35s   10.244.2.17   k8s-lab-default-worker   <none>           <none>
```

The filler is gone, and `NOMINATED NODE` is empty again, because the
Pod is now actually running on the node. The record of the preemption
is an event on the evicted Pod, not on the new one, and it identifies
the new Pod by its UID rather than its name:

```
kubectl get events --field-selector reason=Preempted
kubectl get pod scheduling-demo-priority-preempt -o jsonpath='{.metadata.uid}{"\n"}'
```

**Expected output**:

```
LAST SEEN   TYPE     REASON      OBJECT                                MESSAGE
35s         Normal   Preempted   pod/scheduling-demo-priority-filler   Preempted by pod d3714dd3-042f-45a4-ba18-cb420ff15799 on node k8s-lab-default-worker
d3714dd3-042f-45a4-ba18-cb420ff15799
```

The UIDs match. If you've run the demo before, you may also see older
`Preempted` events; the newest is the one to compare.

Only the filler was evicted. `kindnet` and `kube-proxy`, the other Pods
on the worker, weren't restarted. The scheduler evicts as few Pods as it
can, but any lower-priority Pod is a candidate if its room is needed.

#### Teardown

Delete the Pods (some are already gone) and the three PriorityClasses.
The built-in classes stay:

```
kubectl delete pod --ignore-not-found scheduling-demo-priority-preempt scheduling-demo-priority-filler scheduling-demo-priority-nopreempt scheduling-demo-priority-default
kubectl delete -f tutorial/examples/scheduling/priorityclasses.yaml
kubectl get priorityclass
```

**Expected output**: only the two built-in classes are left:

```
pod "scheduling-demo-priority-preempt" deleted from default namespace
priorityclass.scheduling.k8s.io "scheduling-demo-low" deleted
priorityclass.scheduling.k8s.io "scheduling-demo-high" deleted
priorityclass.scheduling.k8s.io "scheduling-demo-high-nopreempt" deleted
NAME                      VALUE        GLOBAL-DEFAULT   AGE   PREEMPTIONPOLICY
system-cluster-critical   2000000000   false            12m   PreemptLowerPriority
system-node-critical      2000001000   false            12m   PreemptLowerPriority
```

### ResourceQuota: totals for a namespace

**Why**: requests and limits are set Pod by Pod, and nothing stops a
namespace from creating as many Pods, as large as it likes, until the
nodes are full. A **ResourceQuota** sets totals for a whole namespace:
the sum of all CPU and memory requests (`requests.cpu`,
`requests.memory`), the sum of all limits (`limits.cpu`,
`limits.memory`), and counts of objects such as `pods`.

It has a second effect that's easy to miss. Once a quota covers a
resource, for example `limits.memory`, every Pod in the namespace must
declare it. A Pod that doesn't is rejected, even if it would easily fit
in what's left of the quota.

**Example**: create a namespace,
[`governance-namespace.yaml`](examples/scheduling/governance-namespace.yaml),
and a quota for it,
[`resourcequota.yaml`](examples/scheduling/resourcequota.yaml), with
these limits: `requests.cpu: 500m`, `requests.memory: 256Mi`,
`limits.cpu: 1`, `limits.memory: 512Mi`, `pods: 3`. Then try two Pods
that each fail for a different reason:

```
kubectl apply -f tutorial/examples/scheduling/governance-namespace.yaml
kubectl apply -f tutorial/examples/scheduling/resourcequota.yaml
kubectl apply -f tutorial/examples/scheduling/quota-noresources-pod.yaml
kubectl apply -f tutorial/examples/scheduling/quota-exceeding-pod.yaml
kubectl describe resourcequota scheduling-demo-quota -n scheduling-demo-governance
```

**Expected output**: both Pods are rejected and never created, for two
different reasons, and the quota shows nothing used:

```
namespace/scheduling-demo-governance created
resourcequota/scheduling-demo-quota created
Error from server (Forbidden): error when creating "tutorial/examples/scheduling/quota-noresources-pod.yaml": pods "scheduling-demo-noresources-pod" is forbidden: failed quota: scheduling-demo-quota: must specify limits.cpu for: nginx; limits.memory for: nginx; requests.cpu for: nginx; requests.memory for: nginx
Error from server (Forbidden): error when creating "tutorial/examples/scheduling/quota-exceeding-pod.yaml": pods "scheduling-demo-exceeding-pod" is forbidden: exceeded quota: scheduling-demo-quota, requested: limits.memory=600Mi,requests.memory=300Mi, used: limits.memory=0,requests.memory=0, limited: limits.memory=512Mi,requests.memory=256Mi
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

The first Pod declares no resources, and the error lists exactly which
ones it must declare. The second declares them all, but asks for too
much. The error spells out `requested`, `used` and `limited`: this Pod
alone would have needed 600Mi of `limits.memory`, against a limit of
512Mi.

**Storage quotas**: a quota can also limit storage.
`persistentvolumeclaims` limits the number of PVCs, as `pods` limits
the number of Pods, and `requests.storage` limits the total size that
the namespace's PVCs ask for. A namespace can have several
ResourceQuota objects, and each one is enforced, so
[`resourcequota-storage.yaml`](examples/scheduling/resourcequota-storage.yaml)
adds a second quota instead of changing the first.

`requests.storage` counts the size written in each PVC, not how much
data is actually stored. A PVC counts in full from the moment it's
created, even before it's bound to a volume, and however much or
little is written to it later.

**Example**: apply the storage quota and
[`quota-storage-pvc.yaml`](examples/scheduling/quota-storage-pvc.yaml),
a PVC asking for `1Gi`, and look at the quota before anything uses the
PVC:

```
kubectl apply -f tutorial/examples/scheduling/resourcequota-storage.yaml
kubectl apply -f tutorial/examples/scheduling/quota-storage-pvc.yaml
kubectl get pvc scheduling-demo-quota-pvc -n scheduling-demo-governance
kubectl describe resourcequota scheduling-demo-storage-quota -n scheduling-demo-governance
```

**Expected output**: the PVC is `Pending`, because this repo's default
StorageClass waits until a Pod uses a PVC before creating the volume
(`WaitForFirstConsumer`, chapter 4). The quota already counts the full
`1Gi`:

```
resourcequota/scheduling-demo-storage-quota created
persistentvolumeclaim/scheduling-demo-quota-pvc created
NAME                        STATUS    VOLUME   CAPACITY   ACCESS MODES   STORAGECLASS   VOLUMEATTRIBUTESCLASS   AGE
scheduling-demo-quota-pvc   Pending                                      standard       <unset>                 0s
Name:                   scheduling-demo-storage-quota
Namespace:              scheduling-demo-governance
Resource                Used  Hard
--------                ----  ----
persistentvolumeclaims  1     2
requests.storage        1Gi   2Gi
```

Now start a Pod that uses the PVC and writes a few bytes to it,
[`quota-storage-pod.yaml`](examples/scheduling/quota-storage-pod.yaml).
It declares small CPU and memory requests and limits, because the
first quota requires every Pod in this namespace to:

```
kubectl apply -f tutorial/examples/scheduling/quota-storage-pod.yaml
```

When it's running, compare what's on disk with what the quota shows:

```
kubectl exec -n scheduling-demo-governance scheduling-demo-quota-storage-pod -- du -sh /data
kubectl describe resourcequota scheduling-demo-storage-quota -n scheduling-demo-governance
```

**Expected output**: 8 KB on disk, against a PVC of `1Gi`. (This lab's
volumes are plain directories on the node, so nothing enforces the size
in either direction.) The quota still shows `1Gi` used, as it did
before the PVC was bound:

```
8.0K	/data
Name:                   scheduling-demo-storage-quota
Namespace:              scheduling-demo-governance
Resource                Used  Hard
--------                ----  ----
persistentvolumeclaims  1     2
requests.storage        1Gi   2Gi
```

A ResourceQuota adds up what objects *declare*, as requests and limits
do. It doesn't measure what's actually being used.

### LimitRange: default requests and limits

**Why**: having to declare resources in every Pod is tedious. A
**LimitRange** sets defaults for a namespace: `default` for limits and
`defaultRequest` for requests. When a container doesn't declare its
own, the defaults are filled in as the Pod is admitted. A LimitRange
can also set a minimum and maximum per container. With defaults in
place, the Pod the quota rejected above, which declares no resources,
gets them filled in and passes the quota check.

**Example**: [`limitrange.yaml`](examples/scheduling/limitrange.yaml)
sets `default` (500m CPU, 256Mi memory) and `defaultRequest` (250m CPU,
128Mi memory) for the namespace. Then apply the same
`quota-noresources-pod.yaml` that was rejected above:

```
kubectl apply -f tutorial/examples/scheduling/limitrange.yaml
kubectl apply -f tutorial/examples/scheduling/quota-noresources-pod.yaml
kubectl get pod scheduling-demo-noresources-pod -n scheduling-demo-governance -o jsonpath='{.spec.containers[0].resources}'
```

**Expected output**: this time the Pod is created, and its spec has the
LimitRange's values, although the manifest doesn't mention resources:

```
limitrange/scheduling-demo-limits created
pod/scheduling-demo-noresources-pod created
{"limits":{"cpu":"500m","memory":"256Mi"},"requests":{"cpu":"250m","memory":"128Mi"}}
```

The defaults were filled in before the quota was checked, so the Pod
passed. Look at the quota again:

```
kubectl describe resourcequota scheduling-demo-quota -n scheduling-demo-governance
```

**Expected output**: two Pods now count against it: the storage Pod
(50m and 32Mi requested, 100m and 64Mi limits) and this one, with the
LimitRange's amounts:

```
Name:            scheduling-demo-quota
Namespace:       scheduling-demo-governance
Resource         Used   Hard
--------         ----   ----
limits.cpu       600m   1
limits.memory    320Mi  512Mi
pods             2      3
requests.cpu     300m   500m
requests.memory  160Mi  256Mi
```

### Cleaning up

Deleting the namespace deletes everything in it: the quotas, the
LimitRange, the PVC and both Pods. Then remove the label from the
worker:

```
kubectl delete namespace scheduling-demo-governance
kubectl label node k8s-lab-default-worker scheduling-demo/zone-
```

```
namespace "scheduling-demo-governance" deleted
node/k8s-lab-default-worker unlabeled
```
