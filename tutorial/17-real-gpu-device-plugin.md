# 17. A real GPU: the device plugin, a first GPU Pod, and what to check when it fails

Chapter 15 made the scheduler count `nvidia.com/gpu` by writing the count
into a node's status with a patch. This chapter runs on a node with one
real NVIDIA GPU, and nothing is patched: a device plugin, installed as a
DaemonSet, registers the GPU with the kubelet and the capacity appears on
its own. Then a CUDA sample Pod uses the GPU, and the rest of the chapter
is what to look at when GPU capacity is missing or a GPU Pod stays
`Pending`.

The lab setup - a kind worker with a real GPU, the one host-wide Docker
change it needs, the session order and how to undo it - is in
[`lab-helpers/gpu-real/README.md`](../lab-helpers/gpu-real/README.md).
The sections below start from that cluster (`k8s-lab-gpu-real`: one
control-plane node and one GPU worker) and use only `kubectl` and `helm`.

**In scope**: installing the NVIDIA device plugin with Helm, a CUDA sample
Pod that requests one GPU, and reading the symptoms of missing capacity
and of a Pending GPU Pod. **Not covered here**: the NVIDIA GPU Operator,
installing NFD or GFD, MIG, Dynamic Resource Allocation (chapter 14),
monitoring, how a device plugin works inside, and sharing GPUs
(time-slicing, per-namespace quota), which is
[chapter 18](18-gpu-sharing-and-quota.md).

Chapter 8 is the reference for Helm, chapter 15 for `nvidia.com/gpu` as a
count and for `Insufficient nvidia.com/gpu`, and chapter 16 for GPU node
labels and for the control-plane taint in scheduling messages. This
chapter uses them without repeating them.

Verified against: a cluster created with
[nvkind](https://github.com/NVIDIA/nvkind) (commit
`c57050497cffee36f10c8b918d2727c4f26d886e`) from `kindest/node:v1.36.1`,
kind v0.33.0, kubectl client v1.37.1, helm v4.3.0, chart
`nvdp/nvidia-device-plugin` 0.20.1 (device plugin v0.20.1),
`nvidia-container-toolkit` 1.20.1-1 (installed in the node by nvkind),
NVIDIA driver 615.78.08 on the host, one NVIDIA GPU, CUDA sample image
`nvcr.io/nvidia/k8s/cuda-sample:vectoradd-cuda12.5.0`.

**How the output is shown.** Tables are shown as printed. The `AGE` and
restart-age values, the suffix of a generated Pod name and the timestamp
at the start of each log line differ on every run. Helm commands are shown
without their output: the `kubectl` command after each one shows the
effect. For events, `-o custom-columns` prints only `REASON` and
`MESSAGE`. A scheduling message starts with a count of nodes and the
reasons they were excluded; the rest of the message is not discussed
here.

### Installing the device plugin

**Why**: the worker has a GPU, but its status advertises nothing yet. The
plugin comes from NVIDIA's Helm chart repository; the release is called
`nvdp`, pinned to chart version 0.20.1, in its own namespace. One
`kubectl wait` form appears for the first time here:
`--for=jsonpath='{.status.observedGeneration}'=1` blocks until that status
field - which the API reference describes as the most recent generation
observed by the daemon set controller - is 1.

**Example**: the node columns first, then the install, then what the
DaemonSet did:

```
kubectl get nodes -o custom-columns='NAME:.metadata.name,CAPACITY:.status.capacity.nvidia\.com/gpu,ALLOCATABLE:.status.allocatable.nvidia\.com/gpu'
helm repo add nvdp https://nvidia.github.io/k8s-device-plugin
helm repo update
helm install nvdp nvdp/nvidia-device-plugin --version 0.20.1 --namespace nvidia-device-plugin --create-namespace
kubectl wait --for=jsonpath='{.status.observedGeneration}'=1 ds/nvdp-nvidia-device-plugin -n nvidia-device-plugin --timeout=60s
kubectl get ds nvdp-nvidia-device-plugin -n nvidia-device-plugin
kubectl get pods -n nvidia-device-plugin
kubectl get ds nvdp-nvidia-device-plugin -n nvidia-device-plugin -o jsonpath='{range .spec.template.spec.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[*]}{.matchExpressions[0].key}={.matchExpressions[0].values[0]}{"\n"}{end}'
```

**Expected output** (the `helm` output is omitted):

```
$ kubectl get nodes -o custom-columns='NAME:.metadata.name,CAPACITY:.status.capacity.nvidia\.com/gpu,ALLOCATABLE:.status.allocatable.nvidia\.com/gpu'
NAME                             CAPACITY   ALLOCATABLE
k8s-lab-gpu-real-control-plane   <none>     <none>
k8s-lab-gpu-real-worker          <none>     <none>

$ kubectl wait --for=jsonpath='{.status.observedGeneration}'=1 ds/nvdp-nvidia-device-plugin -n nvidia-device-plugin --timeout=60s
daemonset.apps/nvdp-nvidia-device-plugin condition met

$ kubectl get ds nvdp-nvidia-device-plugin -n nvidia-device-plugin
NAME                        DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE   NODE SELECTOR   AGE
nvdp-nvidia-device-plugin   0         0         0       0            0           <none>          1s

$ kubectl get pods -n nvidia-device-plugin
No resources found in nvidia-device-plugin namespace.

$ kubectl get ds nvdp-nvidia-device-plugin -n nvidia-device-plugin -o jsonpath='{range .spec.template.spec.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[*]}{.matchExpressions[0].key}={.matchExpressions[0].values[0]}{"\n"}{end}'
feature.node.kubernetes.io/pci-10de.present=true
feature.node.kubernetes.io/cpu-model.vendor_id=NVIDIA
nvidia.com/gpu.present=true
```

`DESIRED 0` means the DaemonSet found no node it is allowed to run on, so
there is no plugin Pod and the worker still has no capacity. The reason is
the chart's node affinity (chapter 7). Its terms, one per line above, are
alternatives: the Pod may run on a node that carries any one of these
labels. On a real cluster, NFD (Node Feature Discovery) or GFD (chapter
16) would set such a label on a GPU node; this cluster has neither, so
labelling the node by hand is the lab's stand-in. Adding only
`nvidia.com/gpu.present=true` was enough (observed, next step).

**Example**: the label, then the plugin Pod's first attempt. Two more
`kubectl wait` forms appear: `--for=create` with a label selector (`-l`)
blocks until a matching Pod exists, and the `jsonpath` form blocks until
the plugin container is waiting in `CrashLoopBackOff`:

```
kubectl label node k8s-lab-gpu-real-worker nvidia.com/gpu.present=true
kubectl wait --for=jsonpath='{.status.desiredNumberScheduled}'=1 ds/nvdp-nvidia-device-plugin -n nvidia-device-plugin --timeout=60s
kubectl wait --for=create pod -l app.kubernetes.io/name=nvidia-device-plugin -n nvidia-device-plugin --timeout=60s
kubectl wait --for=jsonpath='{.status.containerStatuses[0].state.waiting.reason}'=CrashLoopBackOff pod -l app.kubernetes.io/name=nvidia-device-plugin -n nvidia-device-plugin --timeout=240s
kubectl get pods -n nvidia-device-plugin
kubectl logs -n nvidia-device-plugin -l app.kubernetes.io/name=nvidia-device-plugin --tail=-1 | grep -E 'Failed to initialize NVML|docker default runtime'
kubectl get nodes -o custom-columns='NAME:.metadata.name,CAPACITY:.status.capacity.nvidia\.com/gpu,ALLOCATABLE:.status.allocatable.nvidia\.com/gpu'
```

**Expected output**:

```
$ kubectl label node k8s-lab-gpu-real-worker nvidia.com/gpu.present=true
node/k8s-lab-gpu-real-worker labeled

$ kubectl wait --for=jsonpath='{.status.desiredNumberScheduled}'=1 ds/nvdp-nvidia-device-plugin -n nvidia-device-plugin --timeout=60s
daemonset.apps/nvdp-nvidia-device-plugin condition met

$ kubectl wait --for=create pod -l app.kubernetes.io/name=nvidia-device-plugin -n nvidia-device-plugin --timeout=60s
pod/nvdp-nvidia-device-plugin-t5blm condition met

$ kubectl wait --for=jsonpath='{.status.containerStatuses[0].state.waiting.reason}'=CrashLoopBackOff pod -l app.kubernetes.io/name=nvidia-device-plugin -n nvidia-device-plugin --timeout=240s
pod/nvdp-nvidia-device-plugin-t5blm condition met

$ kubectl get pods -n nvidia-device-plugin
NAME                              READY   STATUS             RESTARTS      AGE
nvdp-nvidia-device-plugin-t5blm   0/1     CrashLoopBackOff   1 (15s ago)   51s

$ kubectl logs -n nvidia-device-plugin -l app.kubernetes.io/name=nvidia-device-plugin --tail=-1 | grep -E 'Failed to initialize NVML|docker default runtime'
E1109 07:37:22.763735       1 factory.go:99] Failed to initialize NVML: ERROR_LIBRARY_NOT_FOUND.
E1109 07:37:22.763746       1 factory.go:100] If this is a GPU node, did you set the docker default runtime to `nvidia`?

$ kubectl get nodes -o custom-columns='NAME:.metadata.name,CAPACITY:.status.capacity.nvidia\.com/gpu,ALLOCATABLE:.status.allocatable.nvidia\.com/gpu'
NAME                             CAPACITY   ALLOCATABLE
k8s-lab-gpu-real-control-plane   <none>     <none>
k8s-lab-gpu-real-worker          <none>     <none>
```

The label was enough for `DESIRED` to reach 1 (observed), and the plugin
Pod now exists and crashes. Its log is the diagnosis: the plugin could not
initialize NVML, and its own hint asks whether the default runtime is
`nvidia`. On this cluster the worker's default container runtime is `runc`
and `nvidia` is registered next to it as a runtime handler. A RuntimeClass
maps a name to such a handler, and this cluster has one:

```
$ kubectl get runtimeclass nvidia
NAME     HANDLER   AGE
nvidia   nvidia    94s
```

So the plugin, and later every GPU Pod, selects `nvidia` explicitly with
`runtimeClassName`. For the plugin that is a chart value:

**Example**: upgrade the release with the value and watch the plugin come
up. `kubectl rollout status` blocks until the DaemonSet's new Pod is
available:

```
helm upgrade nvdp nvdp/nvidia-device-plugin --version 0.20.1 --namespace nvidia-device-plugin --set runtimeClassName=nvidia
kubectl rollout status ds/nvdp-nvidia-device-plugin -n nvidia-device-plugin --timeout=180s
kubectl get pods -n nvidia-device-plugin
kubectl logs -n nvidia-device-plugin -l app.kubernetes.io/name=nvidia-device-plugin --tail=-1 | grep Registered
kubectl wait --for=jsonpath='{.status.allocatable.nvidia\.com/gpu}'=1 node/k8s-lab-gpu-real-worker --timeout=60s
kubectl get nodes -o custom-columns='NAME:.metadata.name,CAPACITY:.status.capacity.nvidia\.com/gpu,ALLOCATABLE:.status.allocatable.nvidia\.com/gpu'
```

**Expected output** (the `helm` output is omitted):

```
$ kubectl rollout status ds/nvdp-nvidia-device-plugin -n nvidia-device-plugin --timeout=180s
Waiting for daemon set "nvdp-nvidia-device-plugin" rollout to finish: 0 out of 1 new pods have been updated...
Waiting for daemon set "nvdp-nvidia-device-plugin" rollout to finish: 0 of 1 updated pods are available...
daemon set "nvdp-nvidia-device-plugin" successfully rolled out

$ kubectl get pods -n nvidia-device-plugin
NAME                              READY   STATUS    RESTARTS   AGE
nvdp-nvidia-device-plugin-f48m8   1/1     Running   0          3s

$ kubectl logs -n nvidia-device-plugin -l app.kubernetes.io/name=nvidia-device-plugin --tail=-1 | grep Registered
I1109 07:37:42.046334       1 server.go:149] Registered device plugin for 'nvidia.com/gpu' with Kubelet

$ kubectl wait --for=jsonpath='{.status.allocatable.nvidia\.com/gpu}'=1 node/k8s-lab-gpu-real-worker --timeout=60s
node/k8s-lab-gpu-real-worker condition met

$ kubectl get nodes -o custom-columns='NAME:.metadata.name,CAPACITY:.status.capacity.nvidia\.com/gpu,ALLOCATABLE:.status.allocatable.nvidia\.com/gpu'
NAME                             CAPACITY   ALLOCATABLE
k8s-lab-gpu-real-control-plane   <none>     <none>
k8s-lab-gpu-real-worker          1          1
```

The worker now has capacity 1 and allocatable 1, and no `kubectl patch`
was run: this is chapter 15's count, written by the plugin's registration
with the kubelet instead of by hand.

**When capacity is missing, check in this order**, each step narrowing the
one before:

1. `kubectl get ds -n nvidia-device-plugin` - `DESIRED 0` means there is
   no node the DaemonSet may run on (here: the affinity above).
2. `kubectl get pods -n nvidia-device-plugin` - a Pod that is not
   `Running` (here `CrashLoopBackOff`) has a reason in the next step.
3. `kubectl logs -n nvidia-device-plugin -l app.kubernetes.io/name=nvidia-device-plugin --tail=-1`
   - the plugin says what failed (here the NVML line).
4. The node columns (`CAPACITY`, `ALLOCATABLE`) - they show whether the
   registration reached the node; here they went from `<none>` to `1`
   after the `Registered` log line.

### A CUDA Pod that requests one GPU

**Why**: capacity is only a number until a container uses the device. The
Pod runs NVIDIA's `vectorAdd` CUDA sample, asks for one GPU with
`nvidia.com/gpu: 1` under `limits` (chapter 15's rules), and sets
`runtimeClassName: nvidia`, for the reason in the previous section. It
runs once and exits, so the check is its phase: `Succeeded`.
`gpu-real-namespace.yaml` creates the namespace `gpu-real`, which holds
every Pod this chapter creates.

**Example**:

```
kubectl apply -f tutorial/examples/gpu/gpu-real-namespace.yaml
kubectl apply -f tutorial/examples/gpu/gpu-real-cuda-vectoradd-pod.yaml
kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/cuda-vectoradd -n gpu-real --timeout=240s
kubectl get pod cuda-vectoradd -n gpu-real
kubectl logs cuda-vectoradd -n gpu-real
```

**Expected output**:

```
$ kubectl apply -f tutorial/examples/gpu/gpu-real-namespace.yaml
namespace/gpu-real created

$ kubectl apply -f tutorial/examples/gpu/gpu-real-cuda-vectoradd-pod.yaml
pod/cuda-vectoradd created

$ kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/cuda-vectoradd -n gpu-real --timeout=240s
pod/cuda-vectoradd condition met

$ kubectl get pod cuda-vectoradd -n gpu-real
NAME             READY   STATUS      RESTARTS   AGE
cuda-vectoradd   0/1     Completed   0          48s

$ kubectl logs cuda-vectoradd -n gpu-real
[Vector addition of 50000 elements]
Copy input data from the host memory to the CUDA device
CUDA kernel launch with 196 blocks of 256 threads
Copy output data from the CUDA device to the host memory
Test PASSED
Done
ERROR: driverInitFileInfo 599 result=11ERROR: init 685 result=11ERROR: init 250 result=11
```

`Test PASSED` is the sample's own check of the result. The Pod's phase is
`Succeeded` (`Completed` in the table); the `ERROR:` text after `Done` is
printed by the container and was not investigated.

The same Pod without the `runtimeClassName` line fails (observed) with
`Failed to allocate device vector A (error code CUDA driver version is
insufficient for CUDA runtime version)!`. The message points at a driver
version, but adding `runtimeClassName: nvidia` was the only change that
made that Pod pass.

### A GPU Pod that stays Pending

**Why**: the other symptom an administrator meets is a GPU Pod that never
starts. This Pod asks for two GPUs on a node that has one. The scheduler's
event says why; this chapter adds no new explanation of its parts. The
`1 Insufficient nvidia.com/gpu` clause is the one explained in chapter
15's [Running out](15-fake-gpu-nodes.md#running-out), and the
`1 node(s) had untolerated taint(s)` clause is the control-plane node, as
in chapter 16's
[Steering with a nodeSelector](16-gpu-node-labels-taints.md#steering-with-a-nodeselector).

**Example**:

```
kubectl apply -f tutorial/examples/gpu/gpu-real-two-gpus-pod.yaml
kubectl wait --for=condition=PodScheduled=false pod/gpu-two -n gpu-real --timeout=60s
kubectl get pod gpu-two -n gpu-real
kubectl get events -n gpu-real --field-selector involvedObject.name=gpu-two,reason=FailedScheduling -o custom-columns='REASON:.reason,MESSAGE:.message'
```

**Expected output**:

```
$ kubectl apply -f tutorial/examples/gpu/gpu-real-two-gpus-pod.yaml
pod/gpu-two created

$ kubectl wait --for=condition=PodScheduled=false pod/gpu-two -n gpu-real --timeout=60s
pod/gpu-two condition met

$ kubectl get pod gpu-two -n gpu-real
NAME      READY   STATUS    RESTARTS   AGE
gpu-two   0/1     Pending   0          0s

$ kubectl get events -n gpu-real --field-selector involvedObject.name=gpu-two,reason=FailedScheduling -o custom-columns='REASON:.reason,MESSAGE:.message'
REASON             MESSAGE
FailedScheduling   0/2 nodes are available: 1 Insufficient nvidia.com/gpu, 1 node(s) had untolerated taint(s). no new claims to deallocate, preemption: 0/2 nodes are available: 2 Preemption is not helpful for scheduling.
```

### When the plugin goes away

**Why**: to see what removing the plugin does to the node's numbers and to
a GPU Pod that is already running, start a Pod that holds the GPU and
sleeps, remove the plugin with `helm uninstall`, and look at the node and
the Pod.

**Example**:

```
kubectl apply -f tutorial/examples/gpu/gpu-real-sleep-pod.yaml
kubectl wait --for=condition=Ready pod/gpu-sleep -n gpu-real --timeout=120s
kubectl get nodes -o custom-columns='NAME:.metadata.name,CAPACITY:.status.capacity.nvidia\.com/gpu,ALLOCATABLE:.status.allocatable.nvidia\.com/gpu'
helm uninstall nvdp --namespace nvidia-device-plugin
kubectl wait --for=jsonpath='{.status.allocatable.nvidia\.com/gpu}'=0 node/k8s-lab-gpu-real-worker --timeout=60s
kubectl get nodes -o custom-columns='NAME:.metadata.name,CAPACITY:.status.capacity.nvidia\.com/gpu,ALLOCATABLE:.status.allocatable.nvidia\.com/gpu'
kubectl get pod gpu-sleep -n gpu-real
```

**Expected output** (the `helm` output is omitted):

```
$ kubectl apply -f tutorial/examples/gpu/gpu-real-sleep-pod.yaml
pod/gpu-sleep created

$ kubectl wait --for=condition=Ready pod/gpu-sleep -n gpu-real --timeout=120s
pod/gpu-sleep condition met

$ kubectl get nodes -o custom-columns='NAME:.metadata.name,CAPACITY:.status.capacity.nvidia\.com/gpu,ALLOCATABLE:.status.allocatable.nvidia\.com/gpu'
NAME                             CAPACITY   ALLOCATABLE
k8s-lab-gpu-real-control-plane   <none>     <none>
k8s-lab-gpu-real-worker          1          1

$ kubectl wait --for=jsonpath='{.status.allocatable.nvidia\.com/gpu}'=0 node/k8s-lab-gpu-real-worker --timeout=60s
node/k8s-lab-gpu-real-worker condition met

$ kubectl get nodes -o custom-columns='NAME:.metadata.name,CAPACITY:.status.capacity.nvidia\.com/gpu,ALLOCATABLE:.status.allocatable.nvidia\.com/gpu'
NAME                             CAPACITY   ALLOCATABLE
k8s-lab-gpu-real-control-plane   <none>     <none>
k8s-lab-gpu-real-worker          1          0

$ kubectl get pod gpu-sleep -n gpu-real
NAME        READY   STATUS    RESTARTS   AGE
gpu-sleep   1/1     Running   0          8s
```

After the plugin is gone, `CAPACITY` stays 1 and `ALLOCATABLE` goes to 0
(observed), and `gpu-sleep` is still `Running` (observed). The running Pod
was not touched; what changed is the number a new GPU Pod would be placed
against. Chapter 7 covers the rule that a node needs that much allocatable
capacity free.

Teardown: the plugin is already uninstalled, and deleting the cluster
removes the Pods and the node label with it. Then undo the host change as
the [lab README](../lab-helpers/gpu-real/README.md) describes.

```
make down PROFILE=gpu-real
```

Next, [chapter 18](18-gpu-sharing-and-quota.md) covers sharing GPUs (time-slicing, per-namespace quota).
