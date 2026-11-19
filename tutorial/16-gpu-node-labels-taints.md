# 16. GPU node labels and taints: steering GPU Pods, keeping other Pods off

Chapter 15 showed the scheduler placing a GPU Pod on *some* node with a
free GPU. Real clusters raise two more questions:

- **Which kind of GPU?** A training job may need a large data-center GPU;
  a small inference service may be fine on a cheaper one. Nodes describe
  their GPUs with **labels**, and Pods pick nodes by label with a
  `nodeSelector` or with node affinity.
- **How do we keep everything else off the GPU nodes?** GPU nodes are
  expensive, and a web server that lands on one wastes it. A **taint** on
  the GPU node keeps ordinary Pods away, and GPU Pods carry a
  **toleration** that lets them in.

None of these mechanisms is new: chapter 7 covers labels, selectors,
node affinity, taints and tolerations. This chapter applies them to GPU
nodes and shows what the results look like.

We stay on chapter 15's fake-GPU cluster, so the GPU counts are patched
in by hand as before.

### GPU labels

On a real cluster, a tool called GPU Feature Discovery (GFD), which
ships with NVIDIA's device plugin, inspects each GPU node and labels it
with the GPU's model, count, memory and more. This lab has no GPUs to
inspect, so we apply the same label names by hand. The names and the
example values come from GFD's
[list of generated labels](https://github.com/NVIDIA/k8s-device-plugin/blob/v0.20.1/docs/gpu-feature-discovery/README.md#generated-labels):

| Label | Meaning | Values used here |
|---|---|---|
| `nvidia.com/gpu.product` | GPU model | `Tesla-T4`, `A100-SXM4-40GB` |
| `nvidia.com/gpu.count` | number of GPUs | `2`, `1` |
| `nvidia.com/gpu.memory` | memory per GPU, in MiB | `15360`, `39538` |

A T4 is a smaller GPU with 16 GB of memory; an A100 is a large
data-center GPU, here the 40 GB version. A real node's values are
whatever its hardware reports.

### Setting up two GPU nodes

**Why**: to steer Pods between kinds of GPU, we need two different GPU
nodes: `worker` will have two T4s and `worker2` one A100.

**Example**: start a fresh cluster:

```
make up PROFILE=gpu-fake
```

Give the workers their GPU counts, as in chapter 15:

```
kubectl patch node k8s-lab-gpu-fake-worker --subresource=status --type=json \
  -p '[{"op":"add","path":"/status/capacity/nvidia.com~1gpu","value":"2"}]'
kubectl patch node k8s-lab-gpu-fake-worker2 --subresource=status --type=json \
  -p '[{"op":"add","path":"/status/capacity/nvidia.com~1gpu","value":"1"}]'
```

A few seconds later:

```
kubectl get nodes -o custom-columns='NAME:.metadata.name,GPUS:.status.allocatable.nvidia\.com/gpu'
```

```
NAME                             GPUS
k8s-lab-gpu-fake-control-plane   <none>
k8s-lab-gpu-fake-worker          2
k8s-lab-gpu-fake-worker2         1
```

Then the labels:

```
kubectl label node k8s-lab-gpu-fake-worker \
  nvidia.com/gpu.product=Tesla-T4 nvidia.com/gpu.count=2 nvidia.com/gpu.memory=15360
kubectl label node k8s-lab-gpu-fake-worker2 \
  nvidia.com/gpu.product=A100-SXM4-40GB nvidia.com/gpu.count=1 nvidia.com/gpu.memory=39538
```

`kubectl get nodes -L` adds a column for each label you name:

```
kubectl get nodes -L nvidia.com/gpu.product,nvidia.com/gpu.count,nvidia.com/gpu.memory
```

```
NAME                             STATUS   ROLES           AGE   VERSION   GPU.PRODUCT      GPU.COUNT   GPU.MEMORY
k8s-lab-gpu-fake-control-plane   Ready    control-plane   63s   v1.36.1                                
k8s-lab-gpu-fake-worker          Ready    <none>          44s   v1.36.1   Tesla-T4         2           15360
k8s-lab-gpu-fake-worker2         Ready    <none>          44s   v1.36.1   A100-SXM4-40GB   1           39538
```

All of this chapter's Pods go in the namespace `gpu-sched`:

```
kubectl apply -f tutorial/examples/gpu/gpu-sched-namespace.yaml
```

### Choosing a GPU model with a nodeSelector

**Why**: a `nodeSelector` is the simplest way to say "only nodes with
this label value". On GPU nodes, that means naming a model.

**Example**: [`gpu-sched-selector-t4-pod.yaml`](examples/gpu/gpu-sched-selector-t4-pod.yaml)
and [`gpu-sched-selector-a100-pod.yaml`](examples/gpu/gpu-sched-selector-a100-pod.yaml)
each ask for one GPU and select a model. The A100 one looks like this:

```
spec:
  nodeSelector:
    nvidia.com/gpu.product: A100-SXM4-40GB
  containers:
  - ...
    resources:
      limits:
        nvidia.com/gpu: 1
```

```
kubectl apply -f tutorial/examples/gpu/gpu-sched-selector-t4-pod.yaml \
  -f tutorial/examples/gpu/gpu-sched-selector-a100-pod.yaml
```

Once they're running:

```
kubectl get pods -n gpu-sched -o wide
```

```
NAME           READY   STATUS    RESTARTS   AGE   IP           NODE                       NOMINATED NODE   READINESS GATES
gpu-sel-a100   1/1     Running   0          13s   10.244.2.2   k8s-lab-gpu-fake-worker2   <none>           <none>
gpu-sel-t4     1/1     Running   0          13s   10.244.1.2   k8s-lab-gpu-fake-worker    <none>           <none>
```

Each Pod is on the node with its model.

What if no node has the model? [`gpu-sched-selector-h100-pod.yaml`](examples/gpu/gpu-sched-selector-h100-pod.yaml)
asks for an H100, which this lab doesn't have:

```
kubectl apply -f tutorial/examples/gpu/gpu-sched-selector-h100-pod.yaml
```

```
pod/gpu-sel-h100 created
```

The Pod stays `Pending`. Its events say why:

```
kubectl describe pod gpu-sel-h100 -n gpu-sched | grep -A3 Events:
```

```
Events:
  Type     Reason            Age   From               Message
  ----     ------            ----  ----               -------
  Warning  FailedScheduling  0s    default-scheduler  0/3 nodes are available: 1 node(s) had untolerated taint(s), 2 node(s) didn't match Pod's node affinity/selector. no new claims to deallocate, preemption: 0/3 nodes are available: 3 Preemption is not helpful for scheduling.
```

The message has a new reason:
`2 node(s) didn't match Pod's node affinity/selector` is the two workers,
neither labelled H100. (The scheduler uses the same wording for a
`nodeSelector` and for node affinity.) The taint is the control-plane
node, as in chapter 15.

```
kubectl delete pod gpu-sel-h100 -n gpu-sched
```

### A label is not capacity

**Why**: a label says what kind of GPU a node has. It says nothing about
how many are free. That is still the count from chapter 15. The A100
node has one GPU, and `gpu-sel-a100` is using it. What happens to a
second Pod that selects the A100?

**Example**: [`gpu-sched-selector-a100-second-pod.yaml`](examples/gpu/gpu-sched-selector-a100-second-pod.yaml)
is the same Pod under another name:

```
kubectl apply -f tutorial/examples/gpu/gpu-sched-selector-a100-second-pod.yaml
```

```
pod/gpu-sel-a100-second created
```

```
kubectl get pods -n gpu-sched -o wide
```

```
NAME                  READY   STATUS    RESTARTS   AGE   IP           NODE                       NOMINATED NODE   READINESS GATES
gpu-sel-a100          1/1     Running   0          14s   10.244.2.2   k8s-lab-gpu-fake-worker2   <none>           <none>
gpu-sel-a100-second   0/1     Pending   0          1s    <none>       <none>                     <none>           <none>
gpu-sel-t4            1/1     Running   0          14s   10.244.1.2   k8s-lab-gpu-fake-worker    <none>           <none>
```

```
kubectl describe pod gpu-sel-a100-second -n gpu-sched | grep -A3 Events:
```

```
Events:
  Type     Reason            Age   From               Message
  ----     ------            ----  ----               -------
  Warning  FailedScheduling  1s    default-scheduler  0/3 nodes are available: 1 Insufficient nvidia.com/gpu, 1 node(s) didn't match Pod's node affinity/selector, 1 node(s) had untolerated taint(s). no new claims to deallocate, preemption: 0/3 nodes are available: 1 No preemption victims found for incoming pod, 2 Preemption is not helpful for scheduling.
```

Now each node fails for a different reason. The A100 node matches the
selector but has `Insufficient nvidia.com/gpu`. The T4 node doesn't match
the selector, even though it has a free GPU. The control-plane node is
tainted.

So the label chose the node, and the count decided whether it had room.
The `nvidia.com/gpu.count=1` label didn't help here: labels only describe
a node, and the scheduler never subtracts from them.

### Node affinity: ranges and preferences

**Why**: a `nodeSelector` can only say "equal to this value". Node
affinity (chapter 7) can say more, and two of its features are useful
with GPU labels:

- **Numeric comparisons.** `gpu.memory` is a number, and "at least 20 GB
  of GPU memory" is often a better request than naming a model. The
  operators `Gt` (greater than) and `Lt` (less than) compare a label's
  value as an integer.
- **Preferences.** `requiredDuringScheduling...` rules exclude nodes,
  like a `nodeSelector`. `preferredDuringScheduling...` rules only rank
  nodes: the scheduler tries the preferred ones first but will use
  another node rather than leave the Pod waiting.

**Example, numeric comparison**: [`gpu-sched-affinity-memory-gt-20000-pod.yaml`](examples/gpu/gpu-sched-affinity-memory-gt-20000-pod.yaml)
requires more than 20000 MiB of GPU memory:

```
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
        - matchExpressions:
          - key: nvidia.com/gpu.memory
            operator: Gt
            values: ["20000"]
```

[`gpu-sched-affinity-memory-gt-50000-pod.yaml`](examples/gpu/gpu-sched-affinity-memory-gt-50000-pod.yaml)
is the same with `"50000"`, more than any node here has. Clear the
namespace so every GPU is free, then apply both:

```
kubectl delete pod --all -n gpu-sched
kubectl apply -f tutorial/examples/gpu/gpu-sched-affinity-memory-gt-20000-pod.yaml \
  -f tutorial/examples/gpu/gpu-sched-affinity-memory-gt-50000-pod.yaml
```

When the first one is running:

```
kubectl get pods -n gpu-sched -o wide
```

```
NAME               READY   STATUS    RESTARTS   AGE   IP           NODE                       NOMINATED NODE   READINESS GATES
gpu-aff-gt-20000   1/1     Running   0          3s    10.244.2.3   k8s-lab-gpu-fake-worker2   <none>           <none>
gpu-aff-gt-50000   0/1     Pending   0          3s    <none>       <none>                     <none>           <none>
```

The T4's 15360 is not
more than 20000, so the first Pod went to the A100 node with 39538. No
node has more than 50000, so the second waits, with the same "didn't
match Pod's node affinity/selector" reason as the H100 Pod:

```
kubectl describe pod gpu-aff-gt-50000 -n gpu-sched | grep -A3 Events:
```

```
Events:
  Type     Reason            Age   From               Message
  ----     ------            ----  ----               -------
  Warning  FailedScheduling  3s    default-scheduler  0/3 nodes are available: 1 node(s) had untolerated taint(s), 2 node(s) didn't match Pod's node affinity/selector. no new claims to deallocate, preemption: 0/3 nodes are available: 3 Preemption is not helpful for scheduling.
```

**Example, preference**: [`gpu-sched-affinity-preferred-a100-first-pod.yaml`](examples/gpu/gpu-sched-affinity-preferred-a100-first-pod.yaml)
and [`...-second-pod.yaml`](examples/gpu/gpu-sched-affinity-preferred-a100-second-pod.yaml)
*prefer* an A100 and require nothing:

```
  affinity:
    nodeAffinity:
      preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 100
        preference:
          matchExpressions:
          - key: nvidia.com/gpu.product
            operator: In
            values: ["A100-SXM4-40GB"]
```

Clear the namespace again and apply the first:

```
kubectl delete pod --all -n gpu-sched
kubectl apply -f tutorial/examples/gpu/gpu-sched-affinity-preferred-a100-first-pod.yaml
```

When it's running, apply the second, and a few seconds later look at
both:

```
kubectl apply -f tutorial/examples/gpu/gpu-sched-affinity-preferred-a100-second-pod.yaml
kubectl get pods -n gpu-sched -o wide
```

```
NAME                  READY   STATUS    RESTARTS   AGE   IP           NODE                       NOMINATED NODE   READINESS GATES
gpu-aff-pref-first    1/1     Running   0          4s    10.244.2.4   k8s-lab-gpu-fake-worker2   <none>           <none>
gpu-aff-pref-second   1/1     Running   0          2s    10.244.1.3   k8s-lab-gpu-fake-worker    <none>           <none>
```

The first Pod got the A100. The second preferred it too, but the A100
node's only GPU was taken, so it ran on the T4 node instead. Compare
`gpu-sel-a100-second` in the previous section: it *required* the A100
through its `nodeSelector`, so it waited.

### Keeping ordinary Pods off a GPU node

**Why**: so far, nothing stops a Pod that needs no GPU from landing on a
GPU node and taking its CPU and memory. A **taint** on the node fixes
that: the scheduler won't place a Pod there unless the Pod has a
matching **toleration** (chapter 7).

To see the effect, we need one GPU node and one ordinary node. `worker2`
becomes the ordinary one: remove its GPU count and its GPU labels.
`worker` stays the only GPU node and gets the taint.

**Example**: clear the namespace and turn `worker2` into an ordinary
node. A label name followed by `-` removes that label:

```
kubectl delete pod --all -n gpu-sched
kubectl patch node k8s-lab-gpu-fake-worker2 --subresource=status --type=json \
  -p '[{"op":"remove","path":"/status/capacity/nvidia.com~1gpu"}]'
kubectl label node k8s-lab-gpu-fake-worker2 \
  nvidia.com/gpu.product- nvidia.com/gpu.count- nvidia.com/gpu.memory-
```

A few seconds later, only `worker` has GPUs:

```
kubectl get nodes -o custom-columns='NAME:.metadata.name,GPUS:.status.allocatable.nvidia\.com/gpu'
```

```
NAME                             GPUS
k8s-lab-gpu-fake-control-plane   <none>
k8s-lab-gpu-fake-worker          2
k8s-lab-gpu-fake-worker2         <none>
```

Before tainting `worker`, start one ordinary Pod there.
[`gpu-sched-pre-taint-pod.yaml`](examples/gpu/gpu-sched-pre-taint-pod.yaml)
asks for no GPU and is pinned to `worker` by its hostname label. It
shows what a taint does to Pods that are already on the node:

```
kubectl apply -f tutorial/examples/gpu/gpu-sched-pre-taint-pod.yaml
```

When it's running, taint `worker`. The taint has the key
`nvidia.com/gpu`, no value, and the effect `NoSchedule`:

```
kubectl taint node k8s-lab-gpu-fake-worker nvidia.com/gpu:NoSchedule
kubectl describe node k8s-lab-gpu-fake-worker | grep Taints:
```

```
node/k8s-lab-gpu-fake-worker tainted
Taints:             nvidia.com/gpu:NoSchedule
```

NVIDIA's own examples and the device plugin's
[Helm chart](https://github.com/NVIDIA/k8s-device-plugin/blob/v0.20.1/deployments/helm/nvidia-device-plugin/values.yaml)
tolerate this same key, so it's the usual choice. Here we apply it by hand; how it
gets onto nodes on a real cluster depends on how the cluster is set up.

Now four ordinary Pods, [`gpu-sched-cpu-deployment.yaml`](examples/gpu/gpu-sched-cpu-deployment.yaml)
(no GPU request, no toleration):

```
kubectl apply -f tutorial/examples/gpu/gpu-sched-cpu-deployment.yaml
```

A few seconds later:

```
kubectl get pods -n gpu-sched -o wide
```

```
NAME                       READY   STATUS    RESTARTS   AGE   IP           NODE                       NOMINATED NODE   READINESS GATES
cpu-demo-9498c4b9f-22pl2   1/1     Running   0          6s    10.244.2.7   k8s-lab-gpu-fake-worker2   <none>           <none>
cpu-demo-9498c4b9f-gddz7   1/1     Running   0          6s    10.244.2.6   k8s-lab-gpu-fake-worker2   <none>           <none>
cpu-demo-9498c4b9f-p4hwp   1/1     Running   0          6s    10.244.2.8   k8s-lab-gpu-fake-worker2   <none>           <none>
cpu-demo-9498c4b9f-sfhb6   1/1     Running   0          6s    10.244.2.5   k8s-lab-gpu-fake-worker2   <none>           <none>
gpu-pre-taint              1/1     Running   0          9s    10.244.1.4   k8s-lab-gpu-fake-worker    <none>           <none>
```

All four new Pods went to `worker2`. `gpu-pre-taint` is still running on
`worker`: `NoSchedule` only affects new placements and doesn't evict
Pods that are already there (chapter 7 covers `NoExecute`, which does).

### GPU Pods and the taint

**Why**: the taint keeps ordinary Pods off `worker`, but it also keeps
GPU Pods off, unless they tolerate it. Three examples show the parts:

- [`gpu-sched-no-toleration-pod.yaml`](examples/gpu/gpu-sched-no-toleration-pod.yaml)
  asks for one GPU and has no toleration.
- [`gpu-sched-toleration-pod.yaml`](examples/gpu/gpu-sched-toleration-pod.yaml)
  asks for one GPU and tolerates the taint:

  ```
  tolerations:
  - key: nvidia.com/gpu
    operator: Exists
    effect: NoSchedule
  ```

- [`gpu-sched-toleration-only-deployment.yaml`](examples/gpu/gpu-sched-toleration-only-deployment.yaml)
  is six Pods with the same toleration and *no* GPU request.

**Example**: remove the previous section's Pods, then apply the two GPU
Pods:

```
kubectl delete deployment cpu-demo -n gpu-sched
kubectl delete pod gpu-pre-taint -n gpu-sched
kubectl apply -f tutorial/examples/gpu/gpu-sched-no-toleration-pod.yaml \
  -f tutorial/examples/gpu/gpu-sched-toleration-pod.yaml
```

A few seconds later:

```
kubectl get pods -n gpu-sched -o wide
```

```
NAME                READY   STATUS    RESTARTS   AGE   IP           NODE                      NOMINATED NODE   READINESS GATES
gpu-no-toleration   0/1     Pending   0          3s    <none>       <none>                    <none>           <none>
gpu-toleration      1/1     Running   0          2s    10.244.1.5   k8s-lab-gpu-fake-worker   <none>           <none>
```

The Pod with the toleration runs on `worker`. It has no `nodeSelector`:
the GPU request alone rules out `worker2`, and the toleration lets it
past the taint. That is the usual pattern for a GPU Pod on a tainted GPU
node: a GPU request plus a toleration, and a selector or affinity on top
if the model matters.

The Pod without a toleration waits:

```
kubectl describe pod gpu-no-toleration -n gpu-sched | grep -A3 Events:
```

```
Events:
  Type     Reason            Age              From               Message
  ----     ------            ----             ----               -------
  Warning  FailedScheduling  2s (x3 over 3s)  default-scheduler  0/3 nodes are available: 1 Insufficient nvidia.com/gpu, 2 node(s) had untolerated taint(s). no new claims to deallocate, preemption: 0/3 nodes are available: 3 Preemption is not helpful for scheduling.
```

Read this one carefully, because it's easy to misread on a real cluster.
`2 node(s) had untolerated taint(s)` is the control-plane node *and*
`worker`, the GPU node, even though `worker` has a free GPU. Only
`worker2`, which has no GPUs, is reported as `Insufficient
nvidia.com/gpu`. So when a GPU Pod is Pending and the message mentions
taints, check the Pod's tolerations before you look for missing GPUs.

Finally, the six Pods that tolerate the taint but ask for no GPU:

```
kubectl apply -f tutorial/examples/gpu/gpu-sched-toleration-only-deployment.yaml
```

When they're running:

```
kubectl get pods -n gpu-sched -l app=toleration-only -o wide
```

```
NAME                              READY   STATUS    RESTARTS   AGE   IP            NODE                       NOMINATED NODE   READINESS GATES
toleration-only-c557cb849-bxlcj   1/1     Running   0          8s    10.244.1.7    k8s-lab-gpu-fake-worker    <none>           <none>
toleration-only-c557cb849-hnn4g   1/1     Running   0          7s    10.244.2.11   k8s-lab-gpu-fake-worker2   <none>           <none>
toleration-only-c557cb849-hsxsz   1/1     Running   0          8s    10.244.2.9    k8s-lab-gpu-fake-worker2   <none>           <none>
toleration-only-c557cb849-m2r7g   1/1     Running   0          7s    10.244.1.6    k8s-lab-gpu-fake-worker    <none>           <none>
toleration-only-c557cb849-ss7ch   1/1     Running   0          8s    10.244.2.10   k8s-lab-gpu-fake-worker2   <none>           <none>
toleration-only-c557cb849-zlpp8   1/1     Running   0          7s    10.244.1.8    k8s-lab-gpu-fake-worker    <none>           <none>
```

They spread across both workers (the split may differ on your run). A
toleration only *allows* a Pod onto a tainted node; it doesn't send it
there. To keep a Pod on the GPU node, you need a GPU request, a selector
or affinity.

### Does the cluster add tolerations for you?

**Why**: Kubernetes has an optional admission plugin,
`ExtendedResourceToleration`. When it's enabled, the API server adds a
toleration to every Pod that requests an extended resource, with the
resource's name as the key. A Pod asking for `nvidia.com/gpu` then
tolerates the `nvidia.com/gpu` taint without writing it
([source comment, v1.36.1](https://github.com/kubernetes/kubernetes/blob/v1.36.1/plugin/pkg/admission/extendedresourcetoleration/admission.go)).
Some clusters enable it and some don't, so it's worth checking before
you rely on either.

**Example**: on kind, the API server's flags are in a static Pod
manifest on the control-plane node:

```
docker exec k8s-lab-gpu-fake-control-plane grep admission-plugins /etc/kubernetes/manifests/kube-apiserver.yaml
```

```
    - --enable-admission-plugins=NodeRestriction
```

That flag lists only the plugins added on top of a built-in default
set, and the default set doesn't include `ExtendedResourceToleration`.
(Chapter 9's "Aside: admission-plugin flags only show additions to a
compiled-in default set" shows how to print that default set.) The Pod confirms it: `gpu-no-toleration` has only the two
tolerations Kubernetes adds to every Pod, and no `nvidia.com/gpu` one:

```
kubectl describe pod gpu-no-toleration -n gpu-sched | grep -A1 Tolerations:
```

```
Tolerations:                 node.kubernetes.io/not-ready:NoExecute op=Exists for 300s
                             node.kubernetes.io/unreachable:NoExecute op=Exists for 300s
```

So on this cluster, GPU Pods need the toleration written out, as
`gpu-toleration` had it.

### Cleaning up

Deleting the cluster removes the Pods, the counts, the labels and the
taint:

```
make down PROFILE=gpu-fake
```

To undo them one by one on a cluster you want to keep, reverse each
step: `kubectl delete namespace gpu-sched`, then
`kubectl taint node k8s-lab-gpu-fake-worker nvidia.com/gpu:NoSchedule-`
(the trailing `-` removes the taint), then the label and count removals
shown for `worker2` above.

**Tested with** kind v0.33.0, `kindest/node:v1.36.1` (the `gpu-fake`
profile) and kubectl v1.37.1. Generated names, IPs and ages will differ
on your run.

What carries over to a real cluster: the label names and the
`nvidia.com/gpu` taint key, and the Kubernetes mechanisms for using
them. What doesn't: here the labels, counts and taint were all added by
hand. [Chapter 17](17-real-gpu-device-plugin.md) moves to a node with a
real GPU, where a device plugin supplies the count.
