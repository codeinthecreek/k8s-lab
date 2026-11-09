# 16. GPU node labels and taints: steering GPU Pods, keeping other Pods off

Chapter 15 made the scheduler count a resource that no hardware backs:
a node advertised `nvidia.com/gpu`, a Pod asked for some, and the
scheduler matched the two. That is enough to place a GPU Pod *somewhere
with a free GPU*. It says nothing about *which kind* of GPU, and nothing
about keeping Pods that don't need a GPU off the nodes that have one.
Both are ordinary scheduling questions, answered with mechanisms chapter
7 already taught - node labels, `nodeSelector`, node affinity, taints
and tolerations. This chapter applies them to GPU nodes.

**What is real here and what is a stand-in.** On a real cluster, GPU
node labels such as `nvidia.com/gpu.product` are produced by NVIDIA's
GPU Feature Discovery (GFD), which ships in the
[`NVIDIA/k8s-device-plugin`](https://github.com/NVIDIA/k8s-device-plugin)
repository. This lab has no GPU, so there is nothing to discover: we
apply the same label names by hand, as a stand-in for what GFD manages
on a real cluster. The label names and the example values come from
GFD's own documentation for its
[generated labels](https://github.com/NVIDIA/k8s-device-plugin/blob/v0.20.1/docs/gpu-feature-discovery/README.md#generated-labels)
(checked in November 2026 against tag v0.20.1). Specifically:

| Label | Meaning (per the GFD docs) | Values used here |
|---|---|---|
| `nvidia.com/gpu.product` | Model of the GPU | `Tesla-T4`, `A100-SXM4-40GB` |
| `nvidia.com/gpu.count` | Number of GPUs | `2`, `1` |
| `nvidia.com/gpu.memory` | Memory of the GPU in mebibytes (MiB) | `15360`, `39538` |

The values are taken from examples in those docs, not measured on any
hardware: `Tesla-T4` with `2` and `15360` is the example column of the
docs' label table, and `A100-SXM4-40GB` with `39538` is from the docs'
sample Node output. A real node's values are whatever its driver and
GFD report. GFD generates more labels than these three; the rest are not
used here. One product name below, `H100-SXM5-80GB`, is illustrative
only - it appears so a Pod can ask for a model that no node in the lab
has.

**In scope**: those three labels applied by hand, `nodeSelector` and node
affinity on them, a taint on a GPU node, and tolerations on GPU Pods.
**Not covered here**: the labels' automatic generation, device plugins
([chapter 17](17-real-gpu-device-plugin.md) takes those up with a real GPU),
ResourceQuota for GPUs, queueing systems, GPU sharing. Dynamic Resource
Allocation is in chapter 14's section "Dynamic Resource Allocation
(`resource.k8s.io`)"; nothing here depends on it.

Chapter 7 is the reference for the mechanisms ("Labels and selectors:
one mechanism, used everywhere", "Node affinity: constraining where a Pod
can be scheduled", and "Taints and tolerations: the opposite direction"
there), and chapter 1's
"Control-plane scheduling exclusion" for the taint every control-plane
node already carries. This chapter does not repeat them; it uses them.
`Gt` and `Lt` are new here; the affinity section below introduces them.

Verified against: kind v0.33.0, `kindest/node:v1.36.1` (the `gpu-fake`
profile), kubectl client v1.37.1.

**How the output is shown.** The Pod tables below leave out the
`RESTARTS`, `AGE`, `IP`, `NOMINATED NODE` and `READINESS GATES`
columns, and the node tables leave out `AGE`; nothing in this chapter
uses them. For events, the command is
shown and the `...` before the message stands for the `LAST SEEN`,
`TYPE`, `REASON` and `OBJECT` columns, which are left out. Each scheduling message starts with a
count of nodes and the reasons they were excluded; the sentences after
that first one are not used in this chapter (chapter 7's PriorityClass
and preemption section covers preemption).

### Starting state: two GPU workers

**Why**: this chapter's experiments need the two workers to look like GPU
nodes of different kinds, so first put chapter 15's advertised counts
back: 2 on `k8s-lab-gpu-fake-worker` and 1 on
`k8s-lab-gpu-fake-worker2`. The patch command and the reason it needs
`--subresource=status` are chapter 15's "Advertising a resource the node
doesn't have"; they are not re-explained here. Two `kubectl wait` forms
appear for the first time:

- `kubectl wait --for=condition=Ready node --all` blocks until every node
  reports `Ready`, so the patches don't race a worker that is still
  joining.
- `kubectl wait --for=jsonpath='{...}'=2 node/...` blocks until the named
  field has that value. Here the field is `allocatable`.

**Example**: on a fresh `gpu-fake` cluster (`make up PROFILE=gpu-fake`),
from the repository root:

```
kubectl wait --for=condition=Ready node --all --timeout=120s
kubectl patch node k8s-lab-gpu-fake-worker --subresource=status --type=json -p '[{"op":"add","path":"/status/capacity/nvidia.com~1gpu","value":"2"}]'
kubectl patch node k8s-lab-gpu-fake-worker2 --subresource=status --type=json -p '[{"op":"add","path":"/status/capacity/nvidia.com~1gpu","value":"1"}]'
kubectl wait --for=jsonpath='{.status.allocatable.nvidia\.com/gpu}'=2 node/k8s-lab-gpu-fake-worker --timeout=60s
kubectl wait --for=jsonpath='{.status.allocatable.nvidia\.com/gpu}'=1 node/k8s-lab-gpu-fake-worker2 --timeout=60s
kubectl get nodes -o custom-columns='NAME:.metadata.name,CAPACITY:.status.capacity.nvidia\.com/gpu,ALLOCATABLE:.status.allocatable.nvidia\.com/gpu'
kubectl apply -f tutorial/examples/gpu/gpu-sched-namespace.yaml
```

**Expected output**:

```
$ kubectl wait --for=condition=Ready node --all --timeout=120s
node/k8s-lab-gpu-fake-control-plane condition met
node/k8s-lab-gpu-fake-worker condition met
node/k8s-lab-gpu-fake-worker2 condition met

$ kubectl patch node k8s-lab-gpu-fake-worker --subresource=status --type=json -p '[{"op":"add","path":"/status/capacity/nvidia.com~1gpu","value":"2"}]'
node/k8s-lab-gpu-fake-worker patched

$ kubectl patch node k8s-lab-gpu-fake-worker2 --subresource=status --type=json -p '[{"op":"add","path":"/status/capacity/nvidia.com~1gpu","value":"1"}]'
node/k8s-lab-gpu-fake-worker2 patched

$ kubectl wait --for=jsonpath='{.status.allocatable.nvidia\.com/gpu}'=2 node/k8s-lab-gpu-fake-worker --timeout=60s
node/k8s-lab-gpu-fake-worker condition met

$ kubectl wait --for=jsonpath='{.status.allocatable.nvidia\.com/gpu}'=1 node/k8s-lab-gpu-fake-worker2 --timeout=60s
node/k8s-lab-gpu-fake-worker2 condition met

$ kubectl get nodes -o custom-columns='NAME:.metadata.name,CAPACITY:.status.capacity.nvidia\.com/gpu,ALLOCATABLE:.status.allocatable.nvidia\.com/gpu'
NAME                             CAPACITY   ALLOCATABLE
k8s-lab-gpu-fake-control-plane   <none>     <none>
k8s-lab-gpu-fake-worker          2          2
k8s-lab-gpu-fake-worker2         1          1

$ kubectl apply -f tutorial/examples/gpu/gpu-sched-namespace.yaml
namespace/gpu-sched created
```

Namespace `gpu-sched` holds every
Pod and Deployment this chapter creates.

### GPU node labels, applied by hand

**Why**: a count says how many; a label says what kind. The scheduler
treats node labels as plain key/value metadata (chapter 7, "Labels and
selectors"), so the stand-in is a `kubectl label`. The worker with 2
advertised GPUs gets the T4 values, the worker with 1 gets the A100
values, so each node's `gpu.count` label matches the count advertised
on it.

**Example**:

```
kubectl label node k8s-lab-gpu-fake-worker nvidia.com/gpu.product=Tesla-T4 nvidia.com/gpu.count=2 nvidia.com/gpu.memory=15360
kubectl label node k8s-lab-gpu-fake-worker2 nvidia.com/gpu.product=A100-SXM4-40GB nvidia.com/gpu.count=1 nvidia.com/gpu.memory=39538
kubectl get nodes -L nvidia.com/gpu.product,nvidia.com/gpu.count,nvidia.com/gpu.memory
```

`-L` adds one column per named label.

**Expected output**:

```
$ kubectl label node k8s-lab-gpu-fake-worker nvidia.com/gpu.product=Tesla-T4 nvidia.com/gpu.count=2 nvidia.com/gpu.memory=15360
node/k8s-lab-gpu-fake-worker labeled

$ kubectl label node k8s-lab-gpu-fake-worker2 nvidia.com/gpu.product=A100-SXM4-40GB nvidia.com/gpu.count=1 nvidia.com/gpu.memory=39538
node/k8s-lab-gpu-fake-worker2 labeled

$ kubectl get nodes -L nvidia.com/gpu.product,nvidia.com/gpu.count,nvidia.com/gpu.memory
NAME                             STATUS   ROLES           VERSION   GPU.PRODUCT      GPU.COUNT   GPU.MEMORY
k8s-lab-gpu-fake-control-plane   Ready    control-plane   v1.36.1
k8s-lab-gpu-fake-worker          Ready    <none>          v1.36.1   Tesla-T4         2           15360
k8s-lab-gpu-fake-worker2         Ready    <none>          v1.36.1   A100-SXM4-40GB   1           39538
```

(The `AGE` column of `get nodes` is left out here too.) Everything
after this section asks for one of these labels, or for the advertised
count from chapter 15, or both.

### Steering with a nodeSelector

**Why**: chapter 7 introduced `nodeSelector` as the flat, exact-match form
of "only nodes with these labels". On GPU nodes it is the shortest way to
ask for a model. `gpu-sched-selector-t4-pod.yaml` and
`gpu-sched-selector-a100-pod.yaml` each ask for one GPU
(`nvidia.com/gpu: 1`) and name a `nvidia.com/gpu.product` value under
`nodeSelector`. `gpu-sched-selector-h100-pod.yaml` names
`H100-SXM5-80GB`, a product no node carries.

One more `kubectl wait` form appears here:
`kubectl wait --for=condition=PodScheduled=false pod/...` blocks until the
Pod's `PodScheduled` condition is `False`, which means the scheduler has
made at least one attempt to place the Pod and has not yet succeeded.

**Example**:

```
kubectl apply -f tutorial/examples/gpu/gpu-sched-selector-t4-pod.yaml -f tutorial/examples/gpu/gpu-sched-selector-a100-pod.yaml
kubectl wait --for=condition=Ready pod/gpu-sel-t4 pod/gpu-sel-a100 -n gpu-sched --timeout=120s
kubectl get pods -n gpu-sched -o wide
kubectl apply -f tutorial/examples/gpu/gpu-sched-selector-h100-pod.yaml
kubectl wait --for=condition=PodScheduled=false pod/gpu-sel-h100 -n gpu-sched --timeout=60s
kubectl get pod gpu-sel-h100 -n gpu-sched
kubectl get events -n gpu-sched --field-selector involvedObject.name=gpu-sel-h100,reason=FailedScheduling
```

**Expected output**: each Pod is on the node that carries its product
label, and the H100 Pod is `Pending`:

```
$ kubectl get pods -n gpu-sched -o wide
NAME           READY   STATUS    NODE
gpu-sel-a100   1/1     Running   k8s-lab-gpu-fake-worker2
gpu-sel-t4     1/1     Running   k8s-lab-gpu-fake-worker

$ kubectl get pod gpu-sel-h100 -n gpu-sched
NAME           READY   STATUS
gpu-sel-h100   0/1     Pending
```

The event (the `...` stands for the columns left out):

```
$ kubectl get events -n gpu-sched --field-selector involvedObject.name=gpu-sel-h100,reason=FailedScheduling
... 0/3 nodes are available: 1 node(s) had untolerated taint(s), 2 node(s) didn't match Pod's node affinity/selector. no new claims to deallocate, preemption: 0/3 nodes are available: 3 Preemption is not helpful for scheduling.
```

The `1 node(s) had untolerated taint(s)` is the control-plane node,
whose taint is chapter 1's. The two workers are the `2 node(s) didn't
match Pod's node affinity/selector` - neither carries the H100 label.
(A `nodeSelector` is reported under "node affinity/selector"; the two
mechanisms share that clause.)

### A label is not capacity

**Why**: the labels say what a node is; they do not say how much of it
is left. What decides that is the advertised count from chapter 15. To
see the two come apart, delete the H100 Pod, then
ask for a second GPU on the A100 node, which advertises one and is
already running `gpu-sel-a100`.
`gpu-sched-selector-a100-second-pod.yaml` is that Pod.

**Example**:

```
kubectl delete pod gpu-sel-h100 -n gpu-sched
kubectl apply -f tutorial/examples/gpu/gpu-sched-selector-a100-second-pod.yaml
kubectl wait --for=condition=PodScheduled=false pod/gpu-sel-a100-second -n gpu-sched --timeout=60s
kubectl get pods -n gpu-sched -o wide
kubectl get events -n gpu-sched --field-selector involvedObject.name=gpu-sel-a100-second,reason=FailedScheduling
kubectl describe node k8s-lab-gpu-fake-worker2 | sed -n '/^Allocated resources:/,/^Events:/{/^Events:/!p}'
```

**Expected output**:

```
$ kubectl get pods -n gpu-sched -o wide
NAME                  READY   STATUS    NODE
gpu-sel-a100          1/1     Running   k8s-lab-gpu-fake-worker2
gpu-sel-a100-second   0/1     Pending   <none>
gpu-sel-t4            1/1     Running   k8s-lab-gpu-fake-worker
```

The event (the `...` stands for the columns left out):

```
$ kubectl get events -n gpu-sched --field-selector involvedObject.name=gpu-sel-a100-second,reason=FailedScheduling
... 0/3 nodes are available: 1 Insufficient nvidia.com/gpu, 1 node(s) didn't match Pod's node affinity/selector, 1 node(s) had untolerated taint(s). no new claims to deallocate, preemption: 0/3 nodes are available: 1 No preemption victims found for incoming pod, 2 Preemption is not helpful for scheduling.
```

```
$ kubectl describe node k8s-lab-gpu-fake-worker2 | sed -n '/^Allocated resources:/,/^Events:/{/^Events:/!p}'
Allocated resources:
  (Total limits may be over 100 percent, i.e., overcommitted.)
  Resource           Requests   Limits
  --------           --------   ------
  cpu                100m (1%)  100m (1%)
  memory             50Mi (0%)  50Mi (0%)
  ephemeral-storage  0 (0%)     0 (0%)
  hugepages-1Gi      0 (0%)     0 (0%)
  hugepages-2Mi      0 (0%)     0 (0%)
  nvidia.com/gpu     1          1
```

The selector matched the A100 node, and the Pod still waits: the first
clause of the message, `1 Insufficient nvidia.com/gpu`, is that node,
and the allocated-resources table shows its one GPU already taken. The
T4 worker is the `1 node(s) didn't match Pod's node affinity/selector`.
The labels chose the node; the advertised count decided whether it had
room. A label such as `gpu.count` only describes the node; it does not
reserve anything.

### Node affinity: ranges and preferences

**Why**: `nodeSelector` can only say "equal to this". Node affinity (chapter
7, "Node affinity") can say more, and GPU labels are where that pays off:
`gpu.memory` is a number, and "at least this much memory" is a more
natural request than naming a model. Two things are new here.

- `Gt` and `Lt` are new here. `kubectl explain` says what they take:

  ```
  $ kubectl explain pod.spec.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms.matchExpressions.values
  ...
      An array of string values. If the operator is In or NotIn, the values array
      must be non-empty. If the operator is Exists or DoesNotExist, the values
      array must be empty. If the operator is Gt or Lt, the values array must have
      a single element, which will be interpreted as an integer.
  ```

  So the node's label value and the one value in the list are strings
  holding integers, compared as integers.
- `required...` and `preferred...` (chapter 7) are used on GPU labels:
  `required` excludes nodes, `preferred` only ranks them.

The Pods, all `nvidia.com/gpu: 1`:

- `gpu-sched-affinity-memory-gt-20000-pod.yaml` requires `gpu.memory`
  `Gt` `"20000"`. The T4 worker's `15360` fails it; the A100 worker's
  `39538` passes.
- `gpu-sched-affinity-memory-gt-50000-pod.yaml` requires `Gt` `"50000"`,
  which no node meets.
- `gpu-sched-affinity-in-pod.yaml` requires `gpu.product` `In`
  `["Tesla-T4", "A100-SXM4-40GB"]` - both workers qualify.
- `gpu-sched-affinity-preferred-a100-first-pod.yaml` and
  `...-second-pod.yaml` *prefer* the A100 product (weight 100) and
  require nothing.

**Example**: the namespace is emptied first so every GPU is free.

```
kubectl delete pod --all -n gpu-sched
kubectl apply -f tutorial/examples/gpu/gpu-sched-affinity-memory-gt-20000-pod.yaml
kubectl wait --for=condition=Ready pod/gpu-aff-gt-20000 -n gpu-sched --timeout=120s
kubectl get pod gpu-aff-gt-20000 -n gpu-sched -o wide
kubectl apply -f tutorial/examples/gpu/gpu-sched-affinity-memory-gt-50000-pod.yaml
kubectl wait --for=condition=PodScheduled=false pod/gpu-aff-gt-50000 -n gpu-sched --timeout=60s
kubectl get pod gpu-aff-gt-50000 -n gpu-sched
kubectl get events -n gpu-sched --field-selector involvedObject.name=gpu-aff-gt-50000,reason=FailedScheduling
kubectl delete pod gpu-aff-gt-20000 gpu-aff-gt-50000 -n gpu-sched
kubectl apply -f tutorial/examples/gpu/gpu-sched-affinity-in-pod.yaml
kubectl wait --for=condition=Ready pod/gpu-aff-in -n gpu-sched --timeout=120s
kubectl get pod gpu-aff-in -n gpu-sched -o wide
kubectl delete pod gpu-aff-in -n gpu-sched
kubectl apply -f tutorial/examples/gpu/gpu-sched-affinity-preferred-a100-first-pod.yaml
kubectl wait --for=condition=Ready pod/gpu-aff-pref-first -n gpu-sched --timeout=120s
kubectl apply -f tutorial/examples/gpu/gpu-sched-affinity-preferred-a100-second-pod.yaml
kubectl wait --for=condition=Ready pod/gpu-aff-pref-second -n gpu-sched --timeout=120s
kubectl get pods -n gpu-sched -o wide
```

**Expected output** (`apply`, `wait` and `delete` lines omitted):

```
$ kubectl get pod gpu-aff-gt-20000 -n gpu-sched -o wide
NAME               READY   STATUS    NODE
gpu-aff-gt-20000   1/1     Running   k8s-lab-gpu-fake-worker2

$ kubectl get pod gpu-aff-gt-50000 -n gpu-sched
NAME               READY   STATUS
gpu-aff-gt-50000   0/1     Pending
```

The `gt-50000` event (the `...` stands for the columns left out):

```
$ kubectl get events -n gpu-sched --field-selector involvedObject.name=gpu-aff-gt-50000,reason=FailedScheduling
... 0/3 nodes are available: 1 node(s) had untolerated taint(s), 2 node(s) didn't match Pod's node affinity/selector. no new claims to deallocate, preemption: 0/3 nodes are available: 3 Preemption is not helpful for scheduling.
```

```
$ kubectl get pod gpu-aff-in -n gpu-sched -o wide
NAME         READY   STATUS    NODE
gpu-aff-in   1/1     Running   k8s-lab-gpu-fake-worker

$ kubectl get pods -n gpu-sched -o wide
NAME                  READY   STATUS    NODE
gpu-aff-pref-first    1/1     Running   k8s-lab-gpu-fake-worker2
gpu-aff-pref-second   1/1     Running   k8s-lab-gpu-fake-worker
```

Reading it off:

- `Gt 20000` passed only the A100 worker, and the Pod is there. `Gt 50000`
  passed neither; the message is the same one-taint, two-didn't-match
  shape as the unknown-product Pod earlier.
- The `In` Pod qualified for both workers; this run put it on the T4
  worker. Other verification runs placed it on the A100 worker. The node
  is shown as output only - the affinity rule does not say which
  qualifying node wins.
- The preferred Pods: the first landed on the A100 worker. The A100
  worker advertises one GPU, so the second could not go there; because the
  preference does not exclude anything, it ran on the T4 worker. (The
  `nodeSelector` Pod in "A label is not capacity", aimed at the same full
  A100 worker, stayed `Pending`.)

### Making worker2 a CPU node, and tainting worker

**Why**: so far both workers are GPU nodes, so there is no ordinary node
for non-GPU Pods to go to. To show a GPU node keeping ordinary Pods off,
the cluster needs one GPU node and one ordinary node. `worker2` becomes
the ordinary one: take its count and its three labels off (the reverse of
chapter 15's advertise step and of the labels above). `worker` stays the
only GPU node and gets a taint, chapter 7's mechanism, with key
`nvidia.com/gpu` and effect `NoSchedule` and no value. The taint is applied
by hand here. NVIDIA's own manifests *tolerate* that key (see the next
section); this chapter does not say where the taint comes from on a real
cluster.

To wait for the removal, this chapter uses a shell loop instead of
`kubectl wait`: `until [ -z "$(kubectl get node
... -o jsonpath=...)" ]; do sleep 1; done` re-reads the field once a second
and stops when it is empty. The loop prints nothing; the table after it
is the check.

Two Pods show the taint's effect. `gpu-sched-pre-taint-pod.yaml` has no GPU
request and is pinned to `worker` by hostname, applied before the taint.
`gpu-sched-cpu-deployment.yaml` is four ordinary Pods (no GPU request, no
toleration), applied after.

**Example**:

```
kubectl delete pod --all -n gpu-sched
kubectl patch node k8s-lab-gpu-fake-worker2 --subresource=status --type=json -p '[{"op":"remove","path":"/status/capacity/nvidia.com~1gpu"}]'
kubectl label node k8s-lab-gpu-fake-worker2 nvidia.com/gpu.product- nvidia.com/gpu.count- nvidia.com/gpu.memory-
until [ -z "$(kubectl get node k8s-lab-gpu-fake-worker2 -o jsonpath='{.status.allocatable.nvidia\.com/gpu}')" ]; do sleep 1; done
kubectl get nodes -o custom-columns='NAME:.metadata.name,CAPACITY:.status.capacity.nvidia\.com/gpu,ALLOCATABLE:.status.allocatable.nvidia\.com/gpu'
kubectl get nodes -L nvidia.com/gpu.product,nvidia.com/gpu.count,nvidia.com/gpu.memory
kubectl apply -f tutorial/examples/gpu/gpu-sched-pre-taint-pod.yaml
kubectl wait --for=condition=Ready pod/gpu-pre-taint -n gpu-sched --timeout=120s
kubectl taint node k8s-lab-gpu-fake-worker nvidia.com/gpu:NoSchedule
kubectl get nodes -o custom-columns='NAME:.metadata.name,TAINT:.spec.taints[*].key,EFFECT:.spec.taints[*].effect'
kubectl get pod gpu-pre-taint -n gpu-sched -o wide
kubectl apply -f tutorial/examples/gpu/gpu-sched-cpu-deployment.yaml
kubectl rollout status deployment/cpu-demo -n gpu-sched --timeout=120s
kubectl get pods -n gpu-sched -o wide
```

**Expected output** (`delete`, `patch`, `apply`, `wait` and
`rollout status` lines omitted):

```
$ kubectl get nodes -o custom-columns='NAME:.metadata.name,CAPACITY:.status.capacity.nvidia\.com/gpu,ALLOCATABLE:.status.allocatable.nvidia\.com/gpu'
NAME                             CAPACITY   ALLOCATABLE
k8s-lab-gpu-fake-control-plane   <none>     <none>
k8s-lab-gpu-fake-worker          2          2
k8s-lab-gpu-fake-worker2         <none>     <none>

$ kubectl get nodes -L nvidia.com/gpu.product,nvidia.com/gpu.count,nvidia.com/gpu.memory
NAME                             STATUS   ROLES           VERSION   GPU.PRODUCT   GPU.COUNT   GPU.MEMORY
k8s-lab-gpu-fake-control-plane   Ready    control-plane   v1.36.1
k8s-lab-gpu-fake-worker          Ready    <none>          v1.36.1   Tesla-T4      2           15360
k8s-lab-gpu-fake-worker2         Ready    <none>          v1.36.1

$ kubectl taint node k8s-lab-gpu-fake-worker nvidia.com/gpu:NoSchedule
node/k8s-lab-gpu-fake-worker tainted

$ kubectl get nodes -o custom-columns='NAME:.metadata.name,TAINT:.spec.taints[*].key,EFFECT:.spec.taints[*].effect'
NAME                             TAINT                                   EFFECT
k8s-lab-gpu-fake-control-plane   node-role.kubernetes.io/control-plane   NoSchedule
k8s-lab-gpu-fake-worker          nvidia.com/gpu                          NoSchedule
k8s-lab-gpu-fake-worker2         <none>                                  <none>

$ kubectl get pod gpu-pre-taint -n gpu-sched -o wide
NAME            READY   STATUS    NODE
gpu-pre-taint   1/1     Running   k8s-lab-gpu-fake-worker

$ kubectl get pods -n gpu-sched -o wide
NAME                       READY   STATUS    NODE
cpu-demo-9498c4b9f-brfk2   1/1     Running   k8s-lab-gpu-fake-worker2
cpu-demo-9498c4b9f-mkrk2   1/1     Running   k8s-lab-gpu-fake-worker2
cpu-demo-9498c4b9f-rjkkm   1/1     Running   k8s-lab-gpu-fake-worker2
cpu-demo-9498c4b9f-sdv27   1/1     Running   k8s-lab-gpu-fake-worker2
gpu-pre-taint              1/1     Running   k8s-lab-gpu-fake-worker
```

(The Deployment's Pod name suffixes differ every run.) `worker2` has no
GPU count and no GPU labels. The Pod that was already on `worker` stayed
there - `NoSchedule` does not evict (chapter 7), and all four new
ordinary Pods landed on `worker2`, none on the tainted `worker`.

### GPU Pods and the taint

**Why**: with `worker` the only node with GPUs, and tainted, a Pod that
asks for a GPU has to get past the taint. Three Pods show the pieces:

- `gpu-sched-no-toleration-pod.yaml` asks for one GPU and has no
  toleration.
- `gpu-sched-toleration-pod.yaml` asks for one GPU and tolerates key
  `nvidia.com/gpu`, operator `Exists`, effect `NoSchedule`, with no
  `nodeSelector`. That is the same key, operator and effect NVIDIA's
  manifests tolerate: the sample Pod in the
  [device plugin README](https://github.com/NVIDIA/k8s-device-plugin/blob/v0.20.1/README.md#running-gpu-jobs)
  and the default `tolerations` of the plugin's
  [Helm chart](https://github.com/NVIDIA/k8s-device-plugin/blob/v0.20.1/deployments/helm/nvidia-device-plugin/values.yaml)
  (both at v0.20.1).
- `gpu-sched-toleration-only-deployment.yaml` is six Pods with the same
  toleration and *no* GPU request.

The example first deletes the previous section's ordinary Pods, so the
placements below start from nodes that carry only this section's Pods.

**Example**:

```
kubectl delete deployment cpu-demo -n gpu-sched
kubectl delete pod gpu-pre-taint -n gpu-sched
kubectl apply -f tutorial/examples/gpu/gpu-sched-no-toleration-pod.yaml
kubectl wait --for=condition=PodScheduled=false pod/gpu-no-toleration -n gpu-sched --timeout=60s
kubectl get pod gpu-no-toleration -n gpu-sched
kubectl get events -n gpu-sched --field-selector involvedObject.name=gpu-no-toleration,reason=FailedScheduling
kubectl apply -f tutorial/examples/gpu/gpu-sched-toleration-pod.yaml
kubectl wait --for=condition=Ready pod/gpu-toleration -n gpu-sched --timeout=120s
kubectl get pods -n gpu-sched -o wide
kubectl apply -f tutorial/examples/gpu/gpu-sched-toleration-only-deployment.yaml
kubectl rollout status deployment/toleration-only -n gpu-sched --timeout=120s
kubectl get pods -n gpu-sched -l app=toleration-only -o wide
```

**Expected output** (`delete`, `apply`, `wait` and `rollout status`
lines omitted):

```
$ kubectl get pod gpu-no-toleration -n gpu-sched
NAME                READY   STATUS
gpu-no-toleration   0/1     Pending
```

The event (the `...` stands for the columns left out):

```
$ kubectl get events -n gpu-sched --field-selector involvedObject.name=gpu-no-toleration,reason=FailedScheduling
... 0/3 nodes are available: 1 Insufficient nvidia.com/gpu, 2 node(s) had untolerated taint(s). no new claims to deallocate, preemption: 0/3 nodes are available: 3 Preemption is not helpful for scheduling.
```

```
$ kubectl get pods -n gpu-sched -o wide
NAME                READY   STATUS    NODE
gpu-no-toleration   0/1     Pending   <none>
gpu-toleration      1/1     Running   k8s-lab-gpu-fake-worker

$ kubectl get pods -n gpu-sched -l app=toleration-only -o wide
NAME                              READY   STATUS    NODE
toleration-only-c557cb849-6qms4   1/1     Running   k8s-lab-gpu-fake-worker2
toleration-only-c557cb849-bxmhv   1/1     Running   k8s-lab-gpu-fake-worker2
toleration-only-c557cb849-slb4f   1/1     Running   k8s-lab-gpu-fake-worker
toleration-only-c557cb849-x7hqc   1/1     Running   k8s-lab-gpu-fake-worker2
toleration-only-c557cb849-xlznx   1/1     Running   k8s-lab-gpu-fake-worker
toleration-only-c557cb849-xxcp7   1/1     Running   k8s-lab-gpu-fake-worker
```

What to take from it:

- **The tainted GPU node is reported under the taint.** In the
  `no-toleration` message `2 node(s) had untolerated taint(s)` is the
  control-plane node *and* `worker`, the only node that has GPUs, which
  has two free. `1 Insufficient nvidia.com/gpu` is `worker2`, which has no
  GPU count. So `worker` does not appear under `Insufficient
  nvidia.com/gpu` at all: in this message, the taint is what excludes it.
  (That is what this run's message shows; the chapter does not go
  further into how the scheduler orders its checks.)
- **Request plus toleration is the working pattern.** `gpu-toleration`
  has no `nodeSelector` and still ran on `worker`: only `worker` has a GPU
  count, and the toleration lets the Pod past the taint. The request is
  what asks for a GPU node; the toleration is what lets it in. A selector
  or affinity from the earlier sections would add *which model* on top of
  that - this lab has one GPU model left after `worker2` stopped being a
  GPU node, so there is nothing to choose between here. The
  `gpu-no-toleration` Pod stays `Pending` next to it: a toleration belongs
  to the Pod it is written on.
- **A toleration alone.** The six `toleration-only` Pods have no GPU
  request and no selector, just the toleration; this run placed three on
  each worker. That is where they landed this time, shown as output. What
  the spec shows is the point: the toleration names a taint the Pod can
  put up with and nothing else - it contains no node name, no label and
  no GPU - so it can only make `worker` allowed, which chapter 7's
  "Taints and tolerations" already says in as many words ("the toleration
  makes it eligible"); it is not an instruction to go there.

### Is `ExtendedResourceToleration` on?

**Why**: Kubernetes has an admission plugin named
`ExtendedResourceToleration`. In the v1.36.1 source its comment says that
if a Pod requests an extended resource such as `example.com/device`, the
plugin adds a toleration with that key, operator `Exists` and effect
`NoSchedule` (see
[`admission.go`](https://github.com/kubernetes/kubernetes/blob/v1.36.1/plugin/pkg/admission/extendedresourcetoleration/admission.go)).
That is quoted from the source: this cluster does not run the plugin, so
the chapter did not watch it work. Whether a given cluster runs it is a
property of that cluster's API server, and it is worth checking before
assuming either way - on this one, the explicit toleration in the previous
section was needed.

Chapter 9's section "Aside: admission-plugin flags only show additions
to a compiled-in default set" is the method: the `--enable-admission-plugins`
flag lists additions, and the default-enabled set is printed in the
binary's own `--help`.

**Example**:

```
docker exec k8s-lab-gpu-fake-control-plane cat /etc/kubernetes/manifests/kube-apiserver.yaml | grep admission-plugins
kubectl exec -n kube-system kube-apiserver-k8s-lab-gpu-fake-control-plane -- kube-apiserver --help 2>&1 | grep -A1 '^[[:space:]]*--enable-admission-plugins' | grep -o 'in addition to default enabled ones ([^)]*)'
kubectl get pod gpu-no-toleration -n gpu-sched -o jsonpath='{.spec.tolerations[*].key}{"\n"}'
```

**Expected output**:

```
$ docker exec k8s-lab-gpu-fake-control-plane cat /etc/kubernetes/manifests/kube-apiserver.yaml | grep admission-plugins
    - --enable-admission-plugins=NodeRestriction

$ kubectl exec -n kube-system kube-apiserver-k8s-lab-gpu-fake-control-plane -- kube-apiserver --help 2>&1 | grep -A1 '^[[:space:]]*--enable-admission-plugins' | grep -o 'in addition to default enabled ones ([^)]*)'
in addition to default enabled ones (NamespaceLifecycle, LimitRanger, ServiceAccount, TaintNodesByCondition, PodSecurity, Priority, DefaultTolerationSeconds, DefaultStorageClass, StorageObjectInUseProtection, PodGroupProtection, PersistentVolumeClaimResize, RuntimeClass, CertificateApproval, CertificateSigning, ClusterTrustBundleAttest, CertificateSubjectRestriction, DefaultIngressClass, PodTopologyLabels, PodGroupWorkloadExists, NodeDeclaredFeatureValidator, JobValidation, PodResizeValidator, MutatingAdmissionPolicy, MutatingAdmissionWebhook, ValidatingAdmissionPolicy, ValidatingAdmissionWebhook, ResourceQuota)

$ kubectl get pod gpu-no-toleration -n gpu-sched -o jsonpath='{.spec.tolerations[*].key}{"\n"}'
node.kubernetes.io/not-ready node.kubernetes.io/unreachable
```

**ExtendedResourceToleration is not enabled on this cluster**: the
manifest adds only `NodeRestriction`, and the default-enabled list does
not contain it. The Pod check agrees: the manifest
`gpu-sched-no-toleration-pod.yaml` has no `tolerations` at all, and the two
keys printed above were added automatically, not by the manifest. Neither
is `nvidia.com/gpu`, and that Pod stayed `Pending` in the previous section. Check the
API server flags of any cluster you run GPU Pods on, rather than assuming.

### Teardown

**Why**: reverse order, and the Pods first: the namespace goes, then the
taint, the labels and the count come off `worker`. (`worker2` was already
cleaned in the CPU-node section.) `make down PROFILE=gpu-fake`
discards all of it at once; the steps are shown because they are the
reverse of this chapter's setup, for a cluster you want to keep.

**Example**:

```
kubectl delete namespace gpu-sched
kubectl taint node k8s-lab-gpu-fake-worker nvidia.com/gpu:NoSchedule-
kubectl label node k8s-lab-gpu-fake-worker nvidia.com/gpu.product- nvidia.com/gpu.count- nvidia.com/gpu.memory-
kubectl patch node k8s-lab-gpu-fake-worker --subresource=status --type=json -p '[{"op":"remove","path":"/status/capacity/nvidia.com~1gpu"}]'
until [ -z "$(kubectl get node k8s-lab-gpu-fake-worker -o jsonpath='{.status.allocatable.nvidia\.com/gpu}')" ]; do sleep 1; done
kubectl get nodes -o custom-columns='NAME:.metadata.name,CAPACITY:.status.capacity.nvidia\.com/gpu,ALLOCATABLE:.status.allocatable.nvidia\.com/gpu'
kubectl get nodes -o custom-columns='NAME:.metadata.name,TAINT:.spec.taints[*].key,EFFECT:.spec.taints[*].effect'
kubectl get nodes -L nvidia.com/gpu.product,nvidia.com/gpu.count,nvidia.com/gpu.memory
```

**Expected output** (`patch` output omitted):

```
$ kubectl delete namespace gpu-sched
namespace "gpu-sched" deleted

$ kubectl taint node k8s-lab-gpu-fake-worker nvidia.com/gpu:NoSchedule-
node/k8s-lab-gpu-fake-worker untainted

$ kubectl label node k8s-lab-gpu-fake-worker nvidia.com/gpu.product- nvidia.com/gpu.count- nvidia.com/gpu.memory-
node/k8s-lab-gpu-fake-worker unlabeled

$ kubectl get nodes -o custom-columns='NAME:.metadata.name,CAPACITY:.status.capacity.nvidia\.com/gpu,ALLOCATABLE:.status.allocatable.nvidia\.com/gpu'
NAME                             CAPACITY   ALLOCATABLE
k8s-lab-gpu-fake-control-plane   <none>     <none>
k8s-lab-gpu-fake-worker          <none>     <none>
k8s-lab-gpu-fake-worker2         <none>     <none>

$ kubectl get nodes -o custom-columns='NAME:.metadata.name,TAINT:.spec.taints[*].key,EFFECT:.spec.taints[*].effect'
NAME                             TAINT                                   EFFECT
k8s-lab-gpu-fake-control-plane   node-role.kubernetes.io/control-plane   NoSchedule
k8s-lab-gpu-fake-worker          <none>                                  <none>
k8s-lab-gpu-fake-worker2         <none>                                  <none>

$ kubectl get nodes -L nvidia.com/gpu.product,nvidia.com/gpu.count,nvidia.com/gpu.memory
NAME                             STATUS   ROLES           VERSION   GPU.PRODUCT   GPU.COUNT   GPU.MEMORY
k8s-lab-gpu-fake-control-plane   Ready    control-plane   v1.36.1
k8s-lab-gpu-fake-worker          Ready    <none>          v1.36.1
k8s-lab-gpu-fake-worker2         Ready    <none>          v1.36.1
```

The cluster is back to chapter 15's baseline: no counts, no GPU labels,
only the control-plane taint.

What this chapter used, and what carries over: the label names
`nvidia.com/gpu.product`, `gpu.count` and `gpu.memory` and their example
values are the ones GFD documents; `nodeSelector`, node affinity, taints
and tolerations are the Kubernetes mechanisms chapter 7 teaches, applied
to those labels and to the `nvidia.com/gpu` key. What does not carry over
is how the labels and the taint got onto the nodes - here, by hand.
