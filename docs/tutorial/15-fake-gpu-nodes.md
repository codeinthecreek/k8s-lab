# 15. Fake GPUs: extended resources as a scheduler-accounted counter

This chapter opens the tutorial's GPU section, and it does so without a
GPU. Chapter 14's Dynamic Resource Allocation section showed the newer
way to request hardware - by attribute, through `resource.k8s.io` - using
an example driver (`gpu.example.com`, from `kubernetes-sigs/dra-example-driver`),
not NVIDIA's. This section starts with the older model instead: a node
advertises a *count* under a name like `nvidia.com/gpu`, and a Pod asks
for some of that count by name.

Why start there? Kubernetes' own "Schedule GPUs" task page documents
only that model (device plugins). Checked in November 2026 against the
Kubernetes v1.36 docs: DRA itself is stable (its feature gate went GA in
1.34), but NVIDIA's `k8s-dra-driver-gpu` README says GPU allocation
through that driver is not yet officially supported, and that the
driver's GPU kubelet plugin is switched off unless enabled when its Helm
chart is installed.
That is what those pages say as of that date - not a measurement of how
clusters are actually run - and they will drift, so re-check them before
relying on them.

The core of the older model is smaller than it looks, and this chapter
isolates it. A node's `status.capacity` is just a map from resource name
to quantity, and the scheduler counts whatever is in it. So we can
write a count into it ourselves, with no GPU and no driver, and watch
the scheduler treat it exactly like CPU: placing Pods against it,
refusing to overcommit it, and leaving Pods Pending when it runs out.
That makes the scheduling half of GPU support visible by itself - and
makes obvious, by contrast, what a count alone does *not* do.

**In scope**: advertising `nvidia.com/gpu` through the Node's `status`
subresource, scheduling against it, the rules for requesting it, and
showing that nothing is attached to the container. **Not covered here**:
GPU node labels and taints (chapter 16), and, in later chapters of this
section, device plugins (taken up in the real-GPU chapter),
ResourceQuota for GPUs, queueing systems, GPU sharing, and real GPUs.

Verified against: kind v0.33.0, `kindest/node:v1.36.1` (the `gpu-fake`
profile), kubectl client v1.37.1.

### The `gpu-fake` profile: a cluster with no GPU advertised

**Why**: this section needs somewhere to place Pods across more than one
worker, with nothing else running that could muddy what the scheduler
does. `kind/profiles/gpu-fake/` is one control-plane node and two
workers on the same pinned node image as the other profiles, with no
ingress controller and no metrics-server; `manifests.txt` applies
nothing. The cluster is named `k8s-lab-gpu-fake`, and `kind` points
`kubectl` at the context `kind-k8s-lab-gpu-fake`. Nothing in it
advertises a GPU yet, and the first step is to see that for ourselves.

**Example**:

```
make up PROFILE=gpu-fake
kubectl get nodes
kubectl get nodes -o custom-columns='NAME:.metadata.name,CAPACITY:.status.capacity.nvidia\.com/gpu,ALLOCATABLE:.status.allocatable.nvidia\.com/gpu'
```

The `custom-columns` expression is this chapter's lens on the cluster.
`status.capacity` is a map keyed by resource name, and the name itself
contains a dot, so the dot is escaped with a backslash. A node that has
no such key prints `<none>`.

**Expected output** (the `make up` output is trimmed to its last lines):

```
 • Ready after 15s 💚
Set kubectl context to "kind-k8s-lab-gpu-fake"
...
--- applying manifests from kind/profiles/gpu-fake/manifests.txt ---

$ kubectl get nodes
NAME                             STATUS     ROLES           AGE   VERSION
k8s-lab-gpu-fake-control-plane   Ready      control-plane   34s   v1.36.1
k8s-lab-gpu-fake-worker          NotReady   <none>          15s   v1.36.1
k8s-lab-gpu-fake-worker2         NotReady   <none>          15s   v1.36.1

$ kubectl get nodes -o custom-columns='NAME:.metadata.name,CAPACITY:.status.capacity.nvidia\.com/gpu,ALLOCATABLE:.status.allocatable.nvidia\.com/gpu'
NAME                             CAPACITY   ALLOCATABLE
k8s-lab-gpu-fake-control-plane   <none>     <none>
k8s-lab-gpu-fake-worker          <none>     <none>
k8s-lab-gpu-fake-worker2         <none>     <none>
```

`make up` waits only for the control-plane node, so the workers can
still show `NotReady` for a few seconds; re-run `kubectl get nodes`
until all three are `Ready` before going on. The second table is the
baseline: no node has any `nvidia.com/gpu`, capacity or allocatable.

### Advertising a resource the node doesn't have

**Why**: a Node's `status` is the kubelet's report of what the node has.
We are going to write to it by hand. The obvious command doesn't work,
and the way it fails is worth seeing once: `kubectl patch node` on its
own succeeds and changes nothing. The `status` of a Node is served
through a separate subresource, and `kubectl patch --subresource=status`
is what targets it.

The patch is a JSON patch, so the path is a JSON Pointer, and a `/`
inside a key has to be written `~1` - hence `nvidia.com~1gpu`. This
advertises 2 on one worker and leaves the other bare.

**Example**: first without the subresource, then with it, then the lens
from the previous section (once immediately and once after a short wait):

```
kubectl patch node k8s-lab-gpu-fake-worker --type=json -p '[{"op":"add","path":"/status/capacity/nvidia.com~1gpu","value":"2"}]'
kubectl get nodes -o custom-columns='NAME:.metadata.name,CAPACITY:.status.capacity.nvidia\.com/gpu,ALLOCATABLE:.status.allocatable.nvidia\.com/gpu'
kubectl patch node k8s-lab-gpu-fake-worker --subresource=status --type=json -p '[{"op":"add","path":"/status/capacity/nvidia.com~1gpu","value":"2"}]'
kubectl get nodes -o custom-columns='NAME:.metadata.name,CAPACITY:.status.capacity.nvidia\.com/gpu,ALLOCATABLE:.status.allocatable.nvidia\.com/gpu'
sleep 10
kubectl get nodes -o custom-columns='NAME:.metadata.name,CAPACITY:.status.capacity.nvidia\.com/gpu,ALLOCATABLE:.status.allocatable.nvidia\.com/gpu'
```

**Expected output**:

```
$ kubectl patch node k8s-lab-gpu-fake-worker --type=json -p '[{"op":"add","path":"/status/capacity/nvidia.com~1gpu","value":"2"}]'
node/k8s-lab-gpu-fake-worker patched (no change)

NAME                             CAPACITY   ALLOCATABLE
k8s-lab-gpu-fake-control-plane   <none>     <none>
k8s-lab-gpu-fake-worker          <none>     <none>
k8s-lab-gpu-fake-worker2         <none>     <none>

$ kubectl patch node k8s-lab-gpu-fake-worker --subresource=status --type=json -p '[{"op":"add","path":"/status/capacity/nvidia.com~1gpu","value":"2"}]'
node/k8s-lab-gpu-fake-worker patched

NAME                             CAPACITY   ALLOCATABLE
k8s-lab-gpu-fake-control-plane   <none>     <none>
k8s-lab-gpu-fake-worker          2          <none>
k8s-lab-gpu-fake-worker2         <none>     <none>

$ sleep 10

NAME                             CAPACITY   ALLOCATABLE
k8s-lab-gpu-fake-control-plane   <none>     <none>
k8s-lab-gpu-fake-worker          2          2
k8s-lab-gpu-fake-worker2         <none>     <none>
```

(The `get nodes` blocks above are the same command each time; its
`$ ...` line is dropped after the first appearance to keep the output
readable.) Three things to take from it:

- The un-subresourced patch prints `patched (no change)` - a success
  message, and no effect. A script that checks only the exit status
  would miss it; check the result.
- We wrote only `capacity`. `allocatable` stayed empty for a moment and
  then filled in with the same value without any action from us. The
  gap varied between runs in this lab, from a couple of seconds to about
  ten; that is what was measured here, not a guarantee.
- `worker2` is untouched. One worker now has 2 of something, the other
  has none, and the next steps depend on that asymmetry.

### How long the value lasts

**Why**: the number is stored on the Node object, written by us, not
detected by the kubelet from any hardware. That raises an obvious
question: what erases it? Two things to try on the worker that has it -
restart its kubelet, then delete the Node object entirely and restart the
kubelet again so the node registers itself anew.

**Example**:

```
docker exec k8s-lab-gpu-fake-worker systemctl restart kubelet
sleep 15
kubectl get nodes -o custom-columns='NAME:.metadata.name,CAPACITY:.status.capacity.nvidia\.com/gpu,ALLOCATABLE:.status.allocatable.nvidia\.com/gpu'
kubectl delete node k8s-lab-gpu-fake-worker
docker exec k8s-lab-gpu-fake-worker systemctl restart kubelet
sleep 15
kubectl get nodes
kubectl get nodes -o custom-columns='NAME:.metadata.name,CAPACITY:.status.capacity.nvidia\.com/gpu,ALLOCATABLE:.status.allocatable.nvidia\.com/gpu'
```

**Expected output**: after the first restart, nothing changed. After
the delete and second restart the node is back but brand new (note its
`AGE`), and the value is gone:

```
$ sleep 15

NAME                             CAPACITY   ALLOCATABLE
k8s-lab-gpu-fake-control-plane   <none>     <none>
k8s-lab-gpu-fake-worker          2          2
k8s-lab-gpu-fake-worker2         <none>     <none>

$ kubectl delete node k8s-lab-gpu-fake-worker
node "k8s-lab-gpu-fake-worker" deleted

$ kubectl get nodes
NAME                             STATUS   ROLES           AGE   VERSION
k8s-lab-gpu-fake-control-plane   Ready    control-plane   76s   v1.36.1
k8s-lab-gpu-fake-worker          Ready    <none>          15s   v1.36.1
k8s-lab-gpu-fake-worker2         Ready    <none>          57s   v1.36.1

NAME                             CAPACITY   ALLOCATABLE
k8s-lab-gpu-fake-control-plane   <none>     <none>
k8s-lab-gpu-fake-worker          <none>     <none>
k8s-lab-gpu-fake-worker2         <none>     <none>
```

Other checks in this lab, not repeated here: the value also survived
`docker restart` of the worker's container and a full periodic status
report from the kubelet (one arrived about six minutes after the
previous one in a timed run). In a separate check, after the Node object
was deleted, no replacement appeared on its own during the 60 seconds
watched; it took the kubelet restart. So, for everything tried in this
lab, the value stays as long as the Node object does - restarts didn't
remove it, deleting the Node did, and so did recreating the cluster.

Put the 2 back on the worker so the rest of the chapter has something to
schedule against:

```
kubectl patch node k8s-lab-gpu-fake-worker --subresource=status --type=json -p '[{"op":"add","path":"/status/capacity/nvidia.com~1gpu","value":"2"}]'
sleep 10
kubectl get nodes -o custom-columns='NAME:.metadata.name,CAPACITY:.status.capacity.nvidia\.com/gpu,ALLOCATABLE:.status.allocatable.nvidia\.com/gpu'
```

```
$ kubectl patch node k8s-lab-gpu-fake-worker --subresource=status --type=json -p '[{"op":"add","path":"/status/capacity/nvidia.com~1gpu","value":"2"}]'
node/k8s-lab-gpu-fake-worker patched

$ sleep 10

NAME                             CAPACITY   ALLOCATABLE
k8s-lab-gpu-fake-control-plane   <none>     <none>
k8s-lab-gpu-fake-worker          2          2
k8s-lab-gpu-fake-worker2         <none>     <none>
```

So far: a node can carry a made-up resource count, it appears in
`allocatable` a few seconds after we write `capacity`, and it lasts as
long as the Node object. Nothing has asked for it yet.

### Requesting one GPU

**Why**: a Pod asks for an extended resource the same way it asks for
CPU or memory - a quantity under `resources`, keyed by the resource's
name. The scheduler then only considers nodes that have that much left.
`tutorial/examples/gpu/fake-gpu-deployment.yaml` is a Deployment whose
Pod is plain `busybox` running `sleep`, with a single line of interest:
`limits: nvidia.com/gpu: 1`. Only a limit is written; the rules section
below returns to what that means for the request.

**Example**:

```
kubectl apply -f tutorial/examples/gpu/fake-gpu-namespace.yaml
kubectl apply -f tutorial/examples/gpu/fake-gpu-deployment.yaml
kubectl rollout status deployment/gpu-demo -n gpu-demo --timeout=120s
kubectl get pods -n gpu-demo -o wide
kubectl get pods -n gpu-demo -l app=gpu-demo -o jsonpath='{.items[0].spec.containers[0].resources}{"\n"}'
kubectl describe node k8s-lab-gpu-fake-worker | sed -n '/^Allocated resources:/,/^Events:/{/^Events:/!p}'
```

**Expected output** (the `rollout status` lines and the middle rows of
the node table are trimmed):

```
$ kubectl apply -f tutorial/examples/gpu/fake-gpu-namespace.yaml
namespace/gpu-demo created

$ kubectl apply -f tutorial/examples/gpu/fake-gpu-deployment.yaml
deployment.apps/gpu-demo created

$ kubectl rollout status deployment/gpu-demo -n gpu-demo --timeout=120s
...
deployment "gpu-demo" successfully rolled out

$ kubectl get pods -n gpu-demo -o wide
NAME                       READY   STATUS    RESTARTS   AGE   IP           NODE                      NOMINATED NODE   READINESS GATES
gpu-demo-66ff46d76-f7k65   1/1     Running   0          9s    10.244.3.2   k8s-lab-gpu-fake-worker   <none>           <none>

$ kubectl get pods -n gpu-demo -l app=gpu-demo -o jsonpath='{.items[0].spec.containers[0].resources}{"\n"}'
{"limits":{"nvidia.com/gpu":"1"},"requests":{"nvidia.com/gpu":"1"}}

$ kubectl describe node k8s-lab-gpu-fake-worker | sed -n '/^Allocated resources:/,/^Events:/{/^Events:/!p}'
Allocated resources:
  (Total limits may be over 100 percent, i.e., overcommitted.)
  Resource           Requests   Limits
  --------           --------   ------
  ...
  nvidia.com/gpu     1          1
```

The Pod is on the worker that advertises the GPU. With two workers that
alone could be luck; the next section removes the doubt. Two details
here are worth noticing. The node's `Allocated resources` table keeps a
running total for `nvidia.com/gpu` right alongside CPU and memory - the
count is accounted like any other resource. (A node that advertises no
GPU has no such row; that was checked on the other nodes in this lab.)
And the Pod's stored spec has a request even though the manifest only
wrote a limit - the rules section comes back to that.

### Running out

**Why**: if the count is real to the scheduler, it must run out. The
worker advertises 2. Scale the Deployment to 2 and both Pods fit; scale
to 3 and there is nowhere left - the other worker has no GPU count at
all, and the control-plane node has none either.

**Example**:

```
kubectl scale deployment/gpu-demo -n gpu-demo --replicas=2
kubectl rollout status deployment/gpu-demo -n gpu-demo --timeout=120s
kubectl scale deployment/gpu-demo -n gpu-demo --replicas=3
sleep 5
kubectl get pods -n gpu-demo -o wide
kubectl get events -n gpu-demo --field-selector reason=FailedScheduling
kubectl get nodes -o custom-columns='NAME:.metadata.name,TAINTS:.spec.taints[*].key'
```

**Expected output** (`scale` and `rollout status` output trimmed): the
first two Pods share the advertised worker; the third is `Pending` with
no node:

```
$ kubectl get pods -n gpu-demo -o wide
NAME                       READY   STATUS    RESTARTS   AGE   IP           NODE                      NOMINATED NODE   READINESS GATES
gpu-demo-66ff46d76-5dkht   1/1     Running   0          7s    10.244.3.3   k8s-lab-gpu-fake-worker   <none>           <none>
gpu-demo-66ff46d76-6tk9h   0/1     Pending   0          5s    <none>       <none>                    <none>           <none>
gpu-demo-66ff46d76-f7k65   1/1     Running   0          17s   10.244.3.2   k8s-lab-gpu-fake-worker   <none>           <none>

$ kubectl get events -n gpu-demo --field-selector reason=FailedScheduling
LAST SEEN   TYPE      REASON             OBJECT                         MESSAGE
5s          Warning   FailedScheduling   pod/gpu-demo-66ff46d76-6tk9h   0/3 nodes are available: 1 node(s) had untolerated taint(s), 2 Insufficient nvidia.com/gpu. no new claims to deallocate, preemption: 0/3 nodes are available: 1 No preemption victims found for incoming pod, 2 Preemption is not helpful for scheduling.
```

`Insufficient nvidia.com/gpu` is the whole diagnosis. The message counts
nodes rather than naming them. The full worker and the bare worker both land in `2 Insufficient
nvidia.com/gpu`, and the `1 node(s) had untolerated taint(s)` is the
control-plane node. The trailing preemption clauses are the scheduler's
check for whether evicting other Pods would help; the order of those two
clauses varied from run to run in this lab. The taint command above
shows which node the taint count refers to:

```
$ kubectl get nodes -o custom-columns='NAME:.metadata.name,TAINTS:.spec.taints[*].key'
NAME                             TAINTS
k8s-lab-gpu-fake-control-plane   node-role.kubernetes.io/control-plane
k8s-lab-gpu-fake-worker          <none>
k8s-lab-gpu-fake-worker2         <none>
```

Only the control-plane node carries a taint, so that is the "1 node(s)
had untolerated taint(s)".

That settles the earlier doubt about luck: two Pods sitting together on
the advertised worker, with an idle second worker available, is what the
GPU requirement predicts, and the third Pod finding no home confirms it.

### Adding capacity elsewhere

**Why**: the third Pod is not stuck forever - it is waiting for a node
that has the room. Give the other worker one GPU, and see whether
anything has to be done to the Pod.

**Example**:

```
kubectl patch node k8s-lab-gpu-fake-worker2 --subresource=status --type=json -p '[{"op":"add","path":"/status/capacity/nvidia.com~1gpu","value":"1"}]'
kubectl get nodes -o custom-columns='NAME:.metadata.name,CAPACITY:.status.capacity.nvidia\.com/gpu,ALLOCATABLE:.status.allocatable.nvidia\.com/gpu'
sleep 10
kubectl get nodes -o custom-columns='NAME:.metadata.name,CAPACITY:.status.capacity.nvidia\.com/gpu,ALLOCATABLE:.status.allocatable.nvidia\.com/gpu'
kubectl get pods -n gpu-demo -o wide
kubectl get events -n gpu-demo --field-selector reason=Scheduled
```

**Expected output**: the same Pod - `gpu-demo-66ff46d76-6tk9h`, the one
that was `Pending` - is now assigned to `worker2`, with no change made
to the Pod or the Deployment:

```
$ kubectl patch node k8s-lab-gpu-fake-worker2 --subresource=status --type=json -p '[{"op":"add","path":"/status/capacity/nvidia.com~1gpu","value":"1"}]'
node/k8s-lab-gpu-fake-worker2 patched

NAME                             CAPACITY   ALLOCATABLE
k8s-lab-gpu-fake-control-plane   <none>     <none>
k8s-lab-gpu-fake-worker          2          2
k8s-lab-gpu-fake-worker2         1          <none>

$ sleep 10

NAME                             CAPACITY   ALLOCATABLE
k8s-lab-gpu-fake-control-plane   <none>     <none>
k8s-lab-gpu-fake-worker          2          2
k8s-lab-gpu-fake-worker2         1          1

$ kubectl get pods -n gpu-demo -o wide
NAME                       READY   STATUS              RESTARTS   AGE   IP           NODE                       NOMINATED NODE   READINESS GATES
gpu-demo-66ff46d76-5dkht   1/1     Running             0          18s   10.244.3.3   k8s-lab-gpu-fake-worker    <none>           <none>
gpu-demo-66ff46d76-6tk9h   0/1     ContainerCreating   0          16s   <none>       k8s-lab-gpu-fake-worker2   <none>           <none>
gpu-demo-66ff46d76-f7k65   1/1     Running             0          28s   10.244.3.2   k8s-lab-gpu-fake-worker    <none>           <none>

$ kubectl get events -n gpu-demo --field-selector reason=Scheduled
LAST SEEN   TYPE     REASON      OBJECT                         MESSAGE
18s         Normal   Scheduled   pod/gpu-demo-66ff46d76-5dkht   Successfully assigned gpu-demo/gpu-demo-66ff46d76-5dkht to k8s-lab-gpu-fake-worker
4s          Normal   Scheduled   pod/gpu-demo-66ff46d76-6tk9h   Successfully assigned gpu-demo/gpu-demo-66ff46d76-6tk9h to k8s-lab-gpu-fake-worker2
28s         Normal   Scheduled   pod/gpu-demo-66ff46d76-f7k65   Successfully assigned gpu-demo/gpu-demo-66ff46d76-f7k65 to k8s-lab-gpu-fake-worker
```

The sequence to read off it: `capacity` changed at once; `allocatable`
followed a few seconds later; and the Pending Pod was assigned right
after that. The assignment followed the
`allocatable` update, so the delay from the patch to the assignment
tracked that same gap - from a couple of seconds to about ten across
runs in this lab; again, a measurement from this lab and not a promise. The Pod needed nothing - no delete, no
re-create, no annotation.

Taken together, the last three sections are the scheduling half of the
whole GPU story: a count on nodes, a count in Pod specs, and a
scheduler that matches them.

### The rules for requesting it

**Why**: an extended resource is a count of whole things, and the API
treats it that way. A handful of requests that look reasonable are
refused outright, and one that looks like it should work is quietly
accepted and then never runs. All of these are worth seeing verbatim.
The cluster is now full (3 advertised, 3 in use), so first remove the
Deployment's Pods to free the count. Each case below is a standalone
Pod under `tutorial/examples/gpu/`:

- `fake-gpu-limits-only-pod.yaml` - a limit of 1, no request.
- `fake-gpu-requests-only-pod.yaml` - a request of 1, no limit.
- `fake-gpu-request-ne-limit-pod.yaml` - request 1, limit 2.
- `fake-gpu-fractional-pod.yaml` - request and limit `500m`.
- `fake-gpu-limit-3-pod.yaml` - a limit of 3, more than any single node advertises.
- `fake-gpu-limit-0-pod.yaml` - a limit of 0.

**Example**:

```
kubectl scale deployment/gpu-demo -n gpu-demo --replicas=0
kubectl wait --for=delete pod -l app=gpu-demo -n gpu-demo --timeout=120s
kubectl apply -f tutorial/examples/gpu/fake-gpu-limits-only-pod.yaml
kubectl get pod gpu-limits-only -n gpu-demo -o jsonpath='{.spec.containers[0].resources}{"\n"}'
kubectl apply -f tutorial/examples/gpu/fake-gpu-requests-only-pod.yaml
kubectl apply -f tutorial/examples/gpu/fake-gpu-request-ne-limit-pod.yaml
kubectl apply -f tutorial/examples/gpu/fake-gpu-fractional-pod.yaml
kubectl apply -f tutorial/examples/gpu/fake-gpu-limit-3-pod.yaml
sleep 5
kubectl get pod gpu-limit-3 -n gpu-demo
kubectl get events -n gpu-demo --field-selector involvedObject.name=gpu-limit-3
kubectl apply -f tutorial/examples/gpu/fake-gpu-limit-0-pod.yaml
kubectl wait --for=condition=Ready pod/gpu-limit-0 -n gpu-demo --timeout=120s
kubectl get pods -n gpu-demo
kubectl delete pod gpu-limits-only gpu-limit-3 gpu-limit-0 -n gpu-demo
```

**Expected output** (the `scale` and `wait` lines are omitted):

```
$ kubectl apply -f tutorial/examples/gpu/fake-gpu-limits-only-pod.yaml
pod/gpu-limits-only created

$ kubectl get pod gpu-limits-only -n gpu-demo -o jsonpath='{.spec.containers[0].resources}{"\n"}'
{"limits":{"nvidia.com/gpu":"1"},"requests":{"nvidia.com/gpu":"1"}}

$ kubectl apply -f tutorial/examples/gpu/fake-gpu-requests-only-pod.yaml
The Pod "gpu-requests-only" is invalid: spec.containers[0].resources.limits: Required value: Limit must be set for non overcommitable resources

$ kubectl apply -f tutorial/examples/gpu/fake-gpu-request-ne-limit-pod.yaml
The Pod "gpu-request-ne-limit" is invalid: spec.containers[0].resources.requests: Invalid value: "1": must be equal to nvidia.com/gpu limit of 2

$ kubectl apply -f tutorial/examples/gpu/fake-gpu-fractional-pod.yaml
The Pod "gpu-fractional" is invalid: 
* spec.containers[0].resources.limits[nvidia.com/gpu]: Invalid value: "500m": must be an integer
* spec.containers[0].resources.requests[nvidia.com/gpu]: Invalid value: "500m": must be an integer

$ kubectl apply -f tutorial/examples/gpu/fake-gpu-limit-3-pod.yaml
pod/gpu-limit-3 created

$ kubectl get pod gpu-limit-3 -n gpu-demo
NAME          READY   STATUS    RESTARTS   AGE
gpu-limit-3   0/1     Pending   0          5s

$ kubectl get events -n gpu-demo --field-selector involvedObject.name=gpu-limit-3
LAST SEEN   TYPE      REASON             OBJECT            MESSAGE
6s          Warning   FailedScheduling   pod/gpu-limit-3   0/3 nodes are available: 1 node(s) had untolerated taint(s), 2 Insufficient nvidia.com/gpu. no new claims to deallocate, preemption: 0/3 nodes are available: 3 Preemption is not helpful for scheduling.

$ kubectl apply -f tutorial/examples/gpu/fake-gpu-limit-0-pod.yaml
pod/gpu-limit-0 created

$ kubectl get pods -n gpu-demo
NAME              READY   STATUS    RESTARTS   AGE
gpu-limit-0       1/1     Running   0          2s
gpu-limit-3       0/1     Pending   0          8s
gpu-limits-only   1/1     Running   0          9s

$ kubectl delete pod gpu-limits-only gpu-limit-3 gpu-limit-0 -n gpu-demo
pod "gpu-limits-only" deleted from gpu-demo namespace
pod "gpu-limit-3" deleted from gpu-demo namespace
pod "gpu-limit-0" deleted from gpu-demo namespace
```

What each result says:

| Case | Result |
|---|---|
| Limit only | Accepted. The stored Pod has a request equal to the limit - it was filled in. |
| Request only | Rejected: a limit is required. |
| Request 1, limit 2 | Rejected: the request must equal the limit. |
| `500m` | Rejected on both fields: must be an integer. |
| Limit 3 | Accepted, then `Pending`: no node advertises 3. The event has the same shape as before. |
| Limit 0 | Accepted and `Running`. |

The lesson is in the middle rows. For this kind of resource the request
and the limit are the same number, so a limit alone is enough and a
request alone is not. And admission accepted a limit that no node
can meet - the limit-3 Pod was valid, so it was stored, and it waits.

### Counted, not attached

**Why**: so far everything has been bookkeeping: a Pod got a count
deducted from a node, and nothing else was observed. The exec checks
below look inside a running container for anything a GPU workload would
look for - device files, environment variables, a driver tool. The
rule-test Pods are already deleted, so bring the Deployment back to one
replica first.

**Example**:

```
kubectl scale deployment/gpu-demo -n gpu-demo --replicas=1
kubectl rollout status deployment/gpu-demo -n gpu-demo --timeout=120s
kubectl exec -n gpu-demo deploy/gpu-demo -- ls /dev
kubectl exec -n gpu-demo deploy/gpu-demo -- sh -c 'ls /dev/nvidia*'
kubectl exec -n gpu-demo deploy/gpu-demo -- sh -c 'env | grep -i -E "nvidia|cuda"'
kubectl exec -n gpu-demo deploy/gpu-demo -- which nvidia-smi
```

**Expected output** (the `scale` and `rollout status` lines are
omitted). The last three commands print nothing useful and exit with a
non-zero status, which `kubectl exec` reports:

```
$ kubectl exec -n gpu-demo deploy/gpu-demo -- ls /dev
core
fd
full
mqueue
null
ptmx
pts
random
shm
stderr
stdin
stdout
termination-log
tty
urandom
zero

$ kubectl exec -n gpu-demo deploy/gpu-demo -- sh -c 'ls /dev/nvidia*'
ls: /dev/nvidia*: No such file or directory
command terminated with exit code 1

$ kubectl exec -n gpu-demo deploy/gpu-demo -- sh -c 'env | grep -i -E "nvidia|cuda"'
command terminated with exit code 1

$ kubectl exec -n gpu-demo deploy/gpu-demo -- which nvidia-smi
command terminated with exit code 1
```

A Pod that asked for `nvidia.com/gpu: 1` and was scheduled onto a node
with a "GPU" has no GPU device file, no GPU environment variable, and no
GPU tool. (A plain `busybox` image would not ship `nvidia-smi` anyway, so
that last check says little by itself; the device-file and environment
checks are the informative ones.) Nothing was attached in any of the
places checked: the count lives in the Node's status, the scheduler
subtracts from it, and nothing in this setup does anything more. A real
count is one part of a working GPU setup; the other part is a mechanism
that, when the Pod starts, puts the device into the container.

Kubernetes' "Schedule GPUs" page describes device plugins as the
mechanism that lets Pods access specialized hardware such as GPUs. In
terms of this chapter, that mechanism has two jobs: *advertise* - put an
honest count into the Node's status, which we did by hand with a patch -
and *allocate* - when a Pod that requested the resource starts, hand the
container what it needs to use the device, which nothing did here. Device
plugins are taken up in the real-GPU chapter later in this section;
chapter 16, next, stays with scheduling against the fake counts.

### Teardown

**Why**: the namespace holds every Pod and the Deployment from this
chapter, so deleting it cleans up in one step. The advertised counts live
on the Node objects, so they are removed with the same subresource patch,
using `remove` instead of `add`. Do that after the Pods are gone, not
before: in a separate check in this lab, with three GPU Pods running and
a fourth Pending, removing the key from both nodes left the three
running (no restarts, no events) and the fourth Pending - the count
disappearing from the Node does not evict anything, and it strands
whatever was waiting on it.

Deleting the cluster would discard the counts too, so the removal is
optional if you are about to run `make down`; it is shown because it is
the reverse of the advertise step, and what to do if you want to keep
the cluster for a different experiment.

**Example**:

```
kubectl delete namespace gpu-demo
kubectl patch node k8s-lab-gpu-fake-worker --subresource=status --type=json -p '[{"op":"remove","path":"/status/capacity/nvidia.com~1gpu"}]'
kubectl patch node k8s-lab-gpu-fake-worker2 --subresource=status --type=json -p '[{"op":"remove","path":"/status/capacity/nvidia.com~1gpu"}]'
sleep 10
kubectl get nodes -o custom-columns='NAME:.metadata.name,CAPACITY:.status.capacity.nvidia\.com/gpu,ALLOCATABLE:.status.allocatable.nvidia\.com/gpu'
make down PROFILE=gpu-fake
kind get clusters
```

**Expected output**:

```
$ kubectl delete namespace gpu-demo
namespace "gpu-demo" deleted

$ kubectl patch node k8s-lab-gpu-fake-worker --subresource=status --type=json -p '[{"op":"remove","path":"/status/capacity/nvidia.com~1gpu"}]'
node/k8s-lab-gpu-fake-worker patched

$ kubectl patch node k8s-lab-gpu-fake-worker2 --subresource=status --type=json -p '[{"op":"remove","path":"/status/capacity/nvidia.com~1gpu"}]'
node/k8s-lab-gpu-fake-worker2 patched

$ sleep 10

NAME                             CAPACITY   ALLOCATABLE
k8s-lab-gpu-fake-control-plane   <none>     <none>
k8s-lab-gpu-fake-worker          <none>     <none>
k8s-lab-gpu-fake-worker2         <none>     <none>

$ make down PROFILE=gpu-fake
kind delete cluster --name k8s-lab-gpu-fake
Deleting cluster "k8s-lab-gpu-fake" ...
Deleted nodes: ["k8s-lab-gpu-fake-worker" "k8s-lab-gpu-fake-control-plane" "k8s-lab-gpu-fake-worker2"]

$ kind get clusters
No kind clusters found.
```

A fresh `make up PROFILE=gpu-fake` starts with nothing advertised again,
so repeating the chapter means repeating the `add` patches from the
advertise section and the capacity section. The fake GPUs exist only
as the counts patched onto those Node objects.
