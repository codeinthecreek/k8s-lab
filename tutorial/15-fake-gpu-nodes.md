# 15. Fake GPUs: extended resources as a scheduler-accounted counter

This chapter starts the tutorial's GPU section, and it does so without a
GPU.

To run a Pod on a GPU, Kubernetes has to do two separate jobs. First,
**scheduling**: know which nodes have GPUs free and place the Pod on one
of them. Second, **attaching**: when the Pod starts, give its container
access to the actual device. On a real cluster both jobs happen together,
which makes it hard to see where one ends and the other begins.

Here we look at the scheduling job by itself. To the scheduler, a GPU is
just a number on the node, called an *extended resource*, under a name
such as `nvidia.com/gpu`. We'll write that number onto nodes by hand,
then watch the scheduler place Pods against it, run out of it, and use
new capacity as soon as it appears, exactly as it does with CPU and
memory. At the end we'll look inside a container and see that nothing
was attached at all.

This "count on the node" model is the one Kubernetes' own
[Schedule GPUs](https://kubernetes.io/docs/tasks/manage-gpus/scheduling-gpus/)
page documents, and the one NVIDIA's device plugin uses (chapters 17 and
18). Kubernetes also has a newer model for devices, Dynamic Resource
Allocation, in which a Pod asks for a device by its attributes rather
than by count. Chapter 14 covers it; the GPU section doesn't use it.

### A cluster with no GPUs

**Why**: we need a cluster with more than one worker and nothing else
running, so that every scheduling decision is easy to read. The
`gpu-fake` profile is one control-plane node and two workers, with no
add-ons.

**Example**:

```
make up PROFILE=gpu-fake
```

Give the workers a few seconds to join, then:

```
kubectl get nodes
```

```
NAME                             STATUS   ROLES           AGE   VERSION
k8s-lab-gpu-fake-control-plane   Ready    control-plane   58s   v1.36.1
k8s-lab-gpu-fake-worker          Ready    <none>          40s   v1.36.1
k8s-lab-gpu-fake-worker2         Ready    <none>          40s   v1.36.1
```

This command shows how many `nvidia.com/gpu` each node offers. We'll use
it throughout the chapter:

```
kubectl get nodes -o custom-columns='NAME:.metadata.name,GPUS:.status.allocatable.nvidia\.com/gpu'
```

```
NAME                             GPUS
k8s-lab-gpu-fake-control-plane   <none>
k8s-lab-gpu-fake-worker          <none>
k8s-lab-gpu-fake-worker2         <none>
```

`allocatable` is the part of a node's resources that the scheduler may
hand out to Pods. The backslash in `nvidia\.com` is needed because the
resource name contains a dot. `<none>` means the node offers no
`nvidia.com/gpu` at all.

### Advertising a GPU the node doesn't have

**Why**: a node's `status` is the kubelet's report of what the node has,
including a `capacity` map from resource names to amounts. On a real
cluster, the device plugin adds the GPU count to that map. We have no
plugin, so we add the count ourselves.

Two details make the command below look stranger than it is:

- A node's status can only be changed through its *status
  subresource*, so the command needs `--subresource=status`. Without it,
  `kubectl patch` prints `patched (no change)` and changes nothing.
- The patch uses JSON Patch, where a path is written with `/` between
  the parts. The `/` inside `nvidia.com/gpu` therefore has to be escaped,
  and JSON Patch writes it as `~1`.

**Example**: give `k8s-lab-gpu-fake-worker` two GPUs:

```
kubectl patch node k8s-lab-gpu-fake-worker --subresource=status --type=json \
  -p '[{"op":"add","path":"/status/capacity/nvidia.com~1gpu","value":"2"}]'
```

```
node/k8s-lab-gpu-fake-worker patched
```

We only set `capacity`; the kubelet works out `allocatable` from it a
few seconds later. Then:

```
kubectl get nodes -o custom-columns='NAME:.metadata.name,GPUS:.status.allocatable.nvidia\.com/gpu'
```

```
NAME                             GPUS
k8s-lab-gpu-fake-control-plane   <none>
k8s-lab-gpu-fake-worker          2
k8s-lab-gpu-fake-worker2         <none>
```

One worker now has two of something, and the other has none.

### Requesting a GPU

**Why**: a Pod asks for an extended resource the same way it asks for
CPU or memory: an amount under `resources`, keyed by the resource name.
The scheduler then only considers nodes that have that much left.

**Example**: [`fake-gpu-deployment.yaml`](examples/gpu/fake-gpu-deployment.yaml)
is a Deployment running plain `busybox`, with one line of interest:

```
        resources:
          limits:
            nvidia.com/gpu: 1
```

Apply it in its own namespace:

```
kubectl apply -f tutorial/examples/gpu/fake-gpu-namespace.yaml
kubectl apply -f tutorial/examples/gpu/fake-gpu-deployment.yaml
```

```
namespace/gpu-demo created
deployment.apps/gpu-demo created
```

Once the image is pulled, the Pod is running:

```
kubectl get pods -n gpu-demo -o wide
```

```
NAME                       READY   STATUS    RESTARTS   AGE   IP           NODE                      NOMINATED NODE   READINESS GATES
gpu-demo-66ff46d76-vmc4w   1/1     Running   0          10s   10.244.2.2   k8s-lab-gpu-fake-worker   <none>           <none>
```

The Pod is on the worker that has GPUs. With two workers that could be
luck; the next section settles it.

The manifest only set a limit, but the stored Pod has a request too:

```
kubectl describe pod -n gpu-demo -l app=gpu-demo | grep -A2 -E '^    (Limits|Requests):'
```

```
    Limits:
      nvidia.com/gpu:  1
    Requests:
      nvidia.com/gpu:  1
    Environment:       <none>
```

Kubernetes filled in the request from the limit. The section on the
rules below explains why.

The node keeps a running total of GPUs in use, just as it does for CPU
and memory:

```
kubectl describe node k8s-lab-gpu-fake-worker | grep nvidia.com/gpu
```

```
  nvidia.com/gpu:     2
  nvidia.com/gpu:     2
  nvidia.com/gpu     1          1
```

The three lines come from the node's `Capacity`, `Allocatable` and
`Allocated resources` sections: it has 2, offers 2, and 1 is taken
(requests 1, limits 1). The same command on `worker2` prints nothing,
because that node has no such resource.

### Running out

**Why**: if the scheduler really counts GPUs, it must run out. The
worker has 2. Ask for 3.

**Example**:

```
kubectl scale deployment/gpu-demo -n gpu-demo --replicas=3
```

```
deployment.apps/gpu-demo scaled
```

A few seconds later:

```
kubectl get pods -n gpu-demo -o wide
```

```
NAME                       READY   STATUS    RESTARTS   AGE   IP           NODE                      NOMINATED NODE   READINESS GATES
gpu-demo-66ff46d76-mppzk   0/1     Pending   0          2s    <none>       <none>                    <none>           <none>
gpu-demo-66ff46d76-vmc4w   1/1     Running   0          13s   10.244.2.2   k8s-lab-gpu-fake-worker   <none>           <none>
gpu-demo-66ff46d76-xt9xh   1/1     Running   0          2s    10.244.2.3   k8s-lab-gpu-fake-worker   <none>           <none>
```

Two Pods share the worker with GPUs, even though `worker2` is idle. The
third has no node and stays `Pending`. The scheduler says why in an
event:

```
kubectl get events -n gpu-demo --field-selector reason=FailedScheduling
```

```
LAST SEEN   TYPE      REASON             OBJECT                         MESSAGE
2s          Warning   FailedScheduling   pod/gpu-demo-66ff46d76-mppzk   0/3 nodes are available: 1 node(s) had untolerated taint(s), 2 Insufficient nvidia.com/gpu. no new claims to deallocate, preemption: 0/3 nodes are available: 1 No preemption victims found for incoming pod, 2 Preemption is not helpful for scheduling.
```

Scheduling messages count nodes rather than naming them. Read the part
before the first full stop:

- `2 Insufficient nvidia.com/gpu`: both workers. One has no free GPU
  left, the other has none at all.
- `1 node(s) had untolerated taint(s)`: the control-plane node, which
  carries a taint that keeps ordinary Pods off it (chapter 1).

The rest is about preemption (chapter 7): evicting other Pods wouldn't
help either. You'll see this same message shape every time a GPU Pod
can't be placed, in this chapter and the next three.

### Adding capacity elsewhere

**Why**: the Pending Pod isn't stuck for good. It is waiting for a node
with room. What happens if one appears?

**Example**: give `worker2` one GPU:

```
kubectl patch node k8s-lab-gpu-fake-worker2 --subresource=status --type=json \
  -p '[{"op":"add","path":"/status/capacity/nvidia.com~1gpu","value":"1"}]'
```

A few seconds later:

```
kubectl get nodes -o custom-columns='NAME:.metadata.name,GPUS:.status.allocatable.nvidia\.com/gpu'
kubectl get pods -n gpu-demo -o wide
```

```
NAME                             GPUS
k8s-lab-gpu-fake-control-plane   <none>
k8s-lab-gpu-fake-worker          2
k8s-lab-gpu-fake-worker2         1
NAME                       READY   STATUS    RESTARTS   AGE   IP           NODE                       NOMINATED NODE   READINESS GATES
gpu-demo-66ff46d76-mppzk   1/1     Running   0          19s   10.244.1.2   k8s-lab-gpu-fake-worker2   <none>           <none>
gpu-demo-66ff46d76-vmc4w   1/1     Running   0          30s   10.244.2.2   k8s-lab-gpu-fake-worker    <none>           <none>
gpu-demo-66ff46d76-xt9xh   1/1     Running   0          19s   10.244.2.3   k8s-lab-gpu-fake-worker    <none>           <none>
```

The same Pod (`...-mppzk`) is now running on `worker2`. Nobody touched
the Pod or the Deployment: the scheduler kept retrying, and placed it as
soon as a node had room.

That is the whole scheduling side of GPUs: a count on each node, a count
in each Pod's spec, and a scheduler that matches the two.

### The rules for requesting a GPU

**Why**: a GPU is a whole device, and Kubernetes treats extended
resources as whole numbers that can't be overcommitted. Several requests
that look reasonable are refused, and one that can never be met is
accepted. It's worth seeing each one.

**Example**: free the GPUs first by scaling the Deployment to zero:

```
kubectl scale deployment/gpu-demo -n gpu-demo --replicas=0
```

Each file below is a single Pod that asks for GPUs in a different way:

| File | Asks for |
|---|---|
| [`fake-gpu-limits-only-pod.yaml`](examples/gpu/fake-gpu-limits-only-pod.yaml) | limit 1, no request |
| [`fake-gpu-requests-only-pod.yaml`](examples/gpu/fake-gpu-requests-only-pod.yaml) | request 1, no limit |
| [`fake-gpu-request-ne-limit-pod.yaml`](examples/gpu/fake-gpu-request-ne-limit-pod.yaml) | request 1, limit 2 |
| [`fake-gpu-fractional-pod.yaml`](examples/gpu/fake-gpu-fractional-pod.yaml) | `500m` (half a GPU) |
| [`fake-gpu-limit-3-pod.yaml`](examples/gpu/fake-gpu-limit-3-pod.yaml) | limit 3, more than any node has |
| [`fake-gpu-limit-0-pod.yaml`](examples/gpu/fake-gpu-limit-0-pod.yaml) | limit 0 |

Apply them one at a time:

```
kubectl apply -f tutorial/examples/gpu/fake-gpu-limits-only-pod.yaml
kubectl apply -f tutorial/examples/gpu/fake-gpu-requests-only-pod.yaml
kubectl apply -f tutorial/examples/gpu/fake-gpu-request-ne-limit-pod.yaml
kubectl apply -f tutorial/examples/gpu/fake-gpu-fractional-pod.yaml
kubectl apply -f tutorial/examples/gpu/fake-gpu-limit-3-pod.yaml
kubectl apply -f tutorial/examples/gpu/fake-gpu-limit-0-pod.yaml
```

```
pod/gpu-limits-only created
The Pod "gpu-requests-only" is invalid: spec.containers[0].resources.limits: Required value: Limit must be set for non overcommitable resources
The Pod "gpu-request-ne-limit" is invalid: spec.containers[0].resources.requests: Invalid value: "1": must be equal to nvidia.com/gpu limit of 2
The Pod "gpu-fractional" is invalid: 
* spec.containers[0].resources.limits[nvidia.com/gpu]: Invalid value: "500m": must be an integer
* spec.containers[0].resources.requests[nvidia.com/gpu]: Invalid value: "500m": must be an integer
pod/gpu-limit-3 created
pod/gpu-limit-0 created
```

Three were refused by the API server, so those Pods were never created.
The other three exist:

```
kubectl get pods -n gpu-demo
```

```
NAME              READY   STATUS    RESTARTS   AGE
gpu-limit-0       1/1     Running   0          4s
gpu-limit-3       0/1     Pending   0          4s
gpu-limits-only   1/1     Running   0          5s
```

Put together:

| Asks for | Result |
|---|---|
| limit 1, no request | Accepted. The request is filled in from the limit, as we saw above. |
| request 1, no limit | Refused: a limit is required. |
| request 1, limit 2 | Refused: request and limit must be equal. |
| `500m` | Refused: must be a whole number. |
| limit 3 | Accepted, then `Pending` forever: no node has 3. |
| limit 0 | Accepted and running, as if it hadn't asked. |

So for a GPU, request and limit are always the same number, and you only
need to write the limit. And the API server doesn't check whether any
node could ever satisfy a request. `gpu-limit-3` is a valid Pod, so it
is stored, and it waits. Its event is the same shape as before:

```
kubectl describe pod gpu-limit-3 -n gpu-demo | grep -A3 Events:
```

```
Events:
  Type     Reason            Age   From               Message
  ----     ------            ----  ----               -------
  Warning  FailedScheduling  4s    default-scheduler  0/3 nodes are available: 1 node(s) had untolerated taint(s), 2 Insufficient nvidia.com/gpu. no new claims to deallocate, preemption: 0/3 nodes are available: 3 Preemption is not helpful for scheduling.
```

Clean up the test Pods and bring the Deployment back to one replica:

```
kubectl delete pod --all -n gpu-demo
kubectl scale deployment/gpu-demo -n gpu-demo --replicas=1
```

### Counted, not attached

**Why**: everything so far has been bookkeeping. A Pod "got a GPU" in
the sense that a number on a node went down by one. Is there anything
GPU-related inside the container?

**Example**: on Linux, a GPU appears inside a container as device files
under `/dev` (for NVIDIA, names starting with `nvidia`). Look:

```
kubectl exec -n gpu-demo deploy/gpu-demo -- ls /dev
```

```
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
```

```
kubectl exec -n gpu-demo deploy/gpu-demo -- sh -c 'ls /dev/nvidia*'
```

```
ls: /dev/nvidia*: No such file or directory
command terminated with exit code 1
```

No GPU device. No GPU-related environment variables either (`grep`
finds nothing and exits with 1):

```
kubectl exec -n gpu-demo deploy/gpu-demo -- sh -c 'env | grep -i -E "nvidia|cuda"'
```

```
command terminated with exit code 1
```

The Pod asked for a GPU and was placed on a node that "has" one, but its
container got nothing. That's the attaching job from the start of the
chapter, and nothing here does it.

On a real cluster, a **device plugin** does both jobs. It *advertises*
the node's GPUs by putting the count into the node's status, which we
did by hand with `kubectl patch`. And it *allocates*: when a Pod that
asked for a GPU starts, it tells the kubelet which device to give the
container. [Chapter 17](17-real-gpu-device-plugin.md) installs NVIDIA's
device plugin on a node with a real GPU. Chapter 16, next, stays on this
cluster and looks at steering GPU Pods to the right kind of node.

### Cleaning up

Deleting the namespace removes the Deployment and its Pods:

```
kubectl delete namespace gpu-demo
```

```
namespace "gpu-demo" deleted
```

The fake GPU counts stay on the nodes until you remove them. To keep the
cluster but remove a count, use the same patch with `remove`:

```
kubectl patch node k8s-lab-gpu-fake-worker --subresource=status --type=json \
  -p '[{"op":"remove","path":"/status/capacity/nvidia.com~1gpu"}]'
```

```
node/k8s-lab-gpu-fake-worker patched
```

Deleting the cluster removes everything, counts included:

```
make down PROFILE=gpu-fake
```

Chapter 16 starts from a fresh `gpu-fake` cluster and adds the counts
back itself.

**Tested with** kind v0.33.0, `kindest/node:v1.36.1` (the `gpu-fake`
profile) and kubectl v1.37.1. Generated names, IPs and ages will differ
on your run.
