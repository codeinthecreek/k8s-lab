# 17. A real GPU: the device plugin, a first GPU Pod, and what to check when it fails

In chapter 15 we made a node advertise `nvidia.com/gpu` by patching a
number into its status. Nothing backed that number. This chapter uses a
node with a real NVIDIA GPU, and nobody patches anything: a program
called a *device plugin* finds the GPU and reports it to Kubernetes.

We'll install the plugin, watch it fail twice and fix each failure, run
a small CUDA program on the GPU, and then look at the two problems you
are most likely to meet on a real cluster: a node that shows no GPUs,
and a GPU Pod that never starts.

To follow along you need the lab's real-GPU cluster, `k8s-lab-gpu-real`
(one control-plane node and one worker that can see the host's GPU).
Setting it up takes a one-time change to the host's Docker
configuration; [`lab-helpers/gpu-real/README.md`](../lab-helpers/gpu-real/README.md)
has the steps. Everything below uses only `kubectl` and `helm`, and
works the same way on a real cluster.

### How a GPU reaches a container

Four pieces have to work together before a container can use a GPU:

```
  host:       NVIDIA driver  (kernel module + libraries such as NVML)
                   |
  node:       container runtime  "nvidia"  (from the NVIDIA Container Toolkit)
                   |   adds the driver's libraries and the GPU device
                   |   to each container that is given a GPU
                   |
  node:       device plugin  (a Pod, one per GPU node)
                   |   1. asks the driver how many GPUs there are
                   |   2. tells the kubelet: "this node has 1 nvidia.com/gpu"
                   |   3. when a Pod gets a GPU, says which device it is
                   |
  cluster:    kubelet updates the node's capacity  ->  scheduler places
              Pods that ask for nvidia.com/gpu  (chapter 15's counting)
```

The driver and the container runtime are set up on the host before
Kubernetes is involved; on this lab, the setup steps in the lab README
take care of them. This chapter is about the last two pieces: the device
plugin and what the kubelet and scheduler do with what it reports.

One detail matters below. A node can have more than one container
runtime. A **RuntimeClass** is a Kubernetes object that gives a runtime
a name, and a Pod picks one with `runtimeClassName` in its spec. On this
cluster, Pods use the ordinary runtime (`runc`) by default, and a
RuntimeClass called `nvidia` selects the NVIDIA one:

```
kubectl get runtimeclass
```

```
NAME     HANDLER   AGE
nvidia   nvidia    94s
```

Some clusters make `nvidia` the default runtime on their GPU nodes, and
then Pods don't need to ask for it. Here they do.

### Installing the device plugin

**Why**: the worker has a GPU, but Kubernetes doesn't know yet. Check
the node's GPU count first. This command prints the worker's GPU
capacity and allocatable count; we'll use it several times:

```
kubectl get node k8s-lab-gpu-real-worker -o custom-columns='CAPACITY:.status.capacity.nvidia\.com/gpu,ALLOCATABLE:.status.allocatable.nvidia\.com/gpu'
```

```
CAPACITY   ALLOCATABLE
<none>     <none>
```

`<none>` means the node doesn't report any `nvidia.com/gpu` at all.

**Example**: NVIDIA publishes the plugin as a Helm chart (chapter 8
covers Helm). Add the chart repository and install a pinned version into
its own namespace:

```
helm repo add nvdp https://nvidia.github.io/k8s-device-plugin
helm repo update
helm install nvdp nvdp/nvidia-device-plugin --version 0.20.1 \
  --namespace nvidia-device-plugin --create-namespace
```

The chart creates a DaemonSet (chapter 3), which should start one plugin
Pod on each GPU node. Look at it:

```
kubectl get daemonset -n nvidia-device-plugin
```

```
NAME                                           DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE   NODE SELECTOR                 AGE
nvdp-nvidia-device-plugin                      0         0         0       0            0           <none>                        0s
nvdp-nvidia-device-plugin-mps-control-daemon   0         0         0       0            0           nvidia.com/mps.capable=true   0s
```

The chart creates two DaemonSets. The second one is for MPS, a way of
sharing a GPU that this tutorial doesn't use; it only runs on nodes
labelled `nvidia.com/mps.capable=true`, so it stays at 0 and you can
ignore it. The first one is the device plugin.

#### First failure: no node qualifies

`DESIRED 0` on the plugin's DaemonSet means it found no node to run on,
so there is no plugin Pod. The chart only runs the plugin on nodes that are labelled as
having an NVIDIA GPU (node affinity, chapter 7). You can see which
labels it accepts:

```
kubectl get daemonset nvdp-nvidia-device-plugin -n nvidia-device-plugin -o yaml | grep -A17 nodeAffinity
```

```
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
            - matchExpressions:
              - key: feature.node.kubernetes.io/pci-10de.present
                operator: In
                values:
                - "true"
            - matchExpressions:
              - key: feature.node.kubernetes.io/cpu-model.vendor_id
                operator: In
                values:
                - NVIDIA
            - matchExpressions:
              - key: nvidia.com/gpu.present
                operator: In
                values:
                - "true"
```

Each `matchExpressions` entry under `nodeSelectorTerms` is an
alternative, so a node with any one of these three labels qualifies. On a real cluster, a tool such as
Node Feature Discovery or GPU Feature Discovery (chapter 16) inspects
each node's hardware and sets these labels for you. This lab runs
neither, so we set one by hand:

```
kubectl label node k8s-lab-gpu-real-worker nvidia.com/gpu.present=true
```

```
node/k8s-lab-gpu-real-worker labeled
```

After a few seconds, the plugin's DaemonSet wants one Pod:

```
kubectl get daemonset -n nvidia-device-plugin
```

```
NAME                                           DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE   NODE SELECTOR                 AGE
nvdp-nvidia-device-plugin                      1         1         0       1            0           <none>                        64s
nvdp-nvidia-device-plugin-mps-control-daemon   0         0         0       0            0           nvidia.com/mps.capable=true   64s
```

#### Second failure: the plugin can't reach the driver

It has created that Pod, but `READY` stays at 0. Give it a minute, then
look at the Pod:

```
kubectl get pods -n nvidia-device-plugin
```

```
NAME                              READY   STATUS             RESTARTS      AGE
nvdp-nvidia-device-plugin-cqpql   0/1     CrashLoopBackOff   1 (15s ago)   52s
```

The plugin starts, fails, and Kubernetes keeps restarting it. Its log
says why:

```
kubectl logs -n nvidia-device-plugin -l app.kubernetes.io/name=nvidia-device-plugin | grep -E 'NVML|runtime'
```

```
E1119 04:02:51.662986       1 factory.go:99] Failed to initialize NVML: ERROR_LIBRARY_NOT_FOUND.
E1119 04:02:51.662988       1 factory.go:100] If this is a GPU node, did you set the docker default runtime to `nvidia`?
E1119 04:02:51.662992       1 factory.go:102] You can learn how to set the runtime at: https://github.com/NVIDIA/k8s-device-plugin#quick-start
```

NVML is the driver library the plugin uses to count GPUs (step 1 in the
picture above). It isn't in the plugin's container because the Pod ran
with the default runtime, `runc`, which doesn't add the driver's
libraries. The log's hint is about Docker, but on this cluster the fix
is the RuntimeClass from the first section: run the plugin with
`runtimeClassName: nvidia`. The chart has a setting for that, so upgrade
the release with it:

```
helm upgrade nvdp nvdp/nvidia-device-plugin --version 0.20.1 \
  --namespace nvidia-device-plugin --set runtimeClassName=nvidia
kubectl rollout status daemonset/nvdp-nvidia-device-plugin -n nvidia-device-plugin
```

```
Waiting for daemon set "nvdp-nvidia-device-plugin" rollout to finish: 0 of 1 updated pods are available...
daemon set "nvdp-nvidia-device-plugin" successfully rolled out
```

This time the plugin stays up, and its log shows it registering with the
kubelet (step 2 in the picture):

```
kubectl logs -n nvidia-device-plugin -l app.kubernetes.io/name=nvidia-device-plugin | grep Registered
```

```
I1119 04:03:07.158000       1 server.go:149] Registered device plugin for 'nvidia.com/gpu' with Kubelet
```

A few seconds later, run the node check again:

```
kubectl get node k8s-lab-gpu-real-worker -o custom-columns='CAPACITY:.status.capacity.nvidia\.com/gpu,ALLOCATABLE:.status.allocatable.nvidia\.com/gpu'
```

```
CAPACITY   ALLOCATABLE
1          1
```

This is the same count chapter 15 patched in by hand, but this time the
kubelet wrote it, from what the plugin reported.

#### When a node shows no GPUs

The two failures above are the usual ones. When a GPU node reports no
`nvidia.com/gpu`, check these in order:

1. **`kubectl get daemonset -n nvidia-device-plugin`**: if `DESIRED` is
   0, no node qualifies for the plugin. Check the node's labels.
2. **`kubectl get pods -n nvidia-device-plugin`**: if the plugin Pod is
   not `Running`, the reason is in its log.
3. **`kubectl logs`** on the plugin Pod: an NVML error means the plugin
   can't reach the driver, which usually means the wrong container
   runtime.
4. **The node's capacity**: it appears shortly after the plugin logs
   `Registered device plugin`.

### A CUDA Pod that uses the GPU

**Why**: so far the GPU is only a number on the node. To see a container
actually use it, we run NVIDIA's `vectorAdd` sample, a tiny CUDA program
that adds two lists of numbers on the GPU and checks the answer.

**Example**: [`gpu-real-cuda-vectoradd-pod.yaml`](examples/gpu/gpu-real-cuda-vectoradd-pod.yaml)
asks for one GPU (`nvidia.com/gpu: 1` under `limits`, as in chapter 15)
and sets `runtimeClassName: nvidia` for the same reason the plugin
needed it. The Pod runs once and exits. All of this chapter's Pods go in
the `gpu-real` namespace:

```
kubectl apply -f tutorial/examples/gpu/gpu-real-namespace.yaml
kubectl apply -f tutorial/examples/gpu/gpu-real-cuda-vectoradd-pod.yaml
```

Pulling the image takes a little while. When the Pod shows `Completed`,
read its log:

```
kubectl get pod cuda-vectoradd -n gpu-real
kubectl logs cuda-vectoradd -n gpu-real
```

```
NAME             READY   STATUS      RESTARTS   AGE
cuda-vectoradd   0/1     Completed   0          50s

[Vector addition of 50000 elements]
Copy input data from the host memory to the CUDA device
CUDA kernel launch with 196 blocks of 256 threads
Copy output data from the CUDA device to the host memory
Test PASSED
Done
ERROR: driverInitFileInfo 599 result=11ERROR: init 685 result=11ERROR: init 250 result=11
```

`Test PASSED` is the program's own check that the GPU computed the right
answer. The `ERROR:` line printed after `Done` doesn't change that: the
program finished and the Pod completed successfully.

**A misleading error to know about.** If you remove the
`runtimeClassName` line from this Pod and run it again, it fails with:

```
Failed to allocate device vector A (error code CUDA driver version is insufficient for CUDA runtime version)!
```

The message suggests the driver is too old, but the driver is fine. As
with the plugin, the container was started by `runc`, so the driver's
libraries were never added to it, and CUDA reports that as a version
problem. If you see this error on a cluster where other GPU Pods work,
check the Pod's `runtimeClassName` before anything else.

### A GPU Pod that stays Pending

**Why**: the other problem you'll meet is a GPU Pod that never starts,
usually because it asks for more GPUs than any node has free.

**Example**: [`gpu-real-two-gpus-pod.yaml`](examples/gpu/gpu-real-two-gpus-pod.yaml)
asks for two GPUs. The cluster has one.

```
kubectl apply -f tutorial/examples/gpu/gpu-real-two-gpus-pod.yaml
kubectl get pod gpu-two -n gpu-real
```

```
NAME      READY   STATUS    RESTARTS   AGE
gpu-two   0/1     Pending   0          0s
```

As with any Pending Pod, the scheduler explains itself in the Pod's
events:

```
kubectl describe pod gpu-two -n gpu-real | grep -A3 Events:
```

```
Events:
  Type     Reason            Age   From               Message
  ----     ------            ----  ----               -------
  Warning  FailedScheduling  1s    default-scheduler  0/2 nodes are available: 1 Insufficient nvidia.com/gpu, 1 node(s) had untolerated taint(s). no new claims to deallocate, preemption: 0/2 nodes are available: 2 Preemption is not helpful for scheduling.
```

Read the start of the message: `0/2 nodes are available`, then the
reasons, with the number of nodes that had each one. The worker has `Insufficient nvidia.com/gpu`, the same
message chapter 15 showed with fake GPUs. The other node is the control
plane, which has a taint that keeps ordinary Pods off it (chapter 16).
The rest of the message says that evicting other Pods wouldn't help
either (preemption, chapter 7), and the part about claims concerns
Dynamic Resource Allocation (chapter 14), which this Pod doesn't use.

Delete the Pod, since it will never run:

```
kubectl delete pod gpu-two -n gpu-real
```

### When the plugin goes away

**Why**: the plugin isn't only needed once at startup. What happens to
the node, and to GPU Pods already running, if it stops?

**Example**: [`gpu-real-sleep-pod.yaml`](examples/gpu/gpu-real-sleep-pod.yaml)
takes the GPU and sleeps for an hour. Start it, then uninstall the
plugin:

```
kubectl apply -f tutorial/examples/gpu/gpu-real-sleep-pod.yaml
kubectl get pod gpu-sleep -n gpu-real
```

```
NAME        READY   STATUS    RESTARTS   AGE
gpu-sleep   1/1     Running   0          3s
```

```
helm uninstall nvdp --namespace nvidia-device-plugin
```

```
release "nvdp" uninstalled
```

After a few seconds, check the node and the Pod:

```
kubectl get node k8s-lab-gpu-real-worker -o custom-columns='CAPACITY:.status.capacity.nvidia\.com/gpu,ALLOCATABLE:.status.allocatable.nvidia\.com/gpu'
kubectl get pod gpu-sleep -n gpu-real
```

```
CAPACITY   ALLOCATABLE
1          0
NAME        READY   STATUS    RESTARTS   AGE
gpu-sleep   1/1     Running   0          13s
```

The running Pod is untouched, and it can still see its GPU.
`nvidia-smi` lists the GPUs a container has; the `nvidia` runtime adds
it to the container along with the driver's libraries:

```
kubectl exec gpu-sleep -n gpu-real -- nvidia-smi -L
```

```
GPU 0: <GPU model> (UUID: GPU-<GPU UUID>)
```

The line shows your GPU's model name and UUID; they are replaced here. What changed is
allocatable, which dropped to 0. The node still lists a GPU in its
capacity, but the scheduler places Pods against allocatable (chapter 7),
so no new GPU Pod will be scheduled here until a plugin registers again.
A node whose capacity and allocatable disagree like this is worth a look
at the plugin.

### Cleaning up

Deleting the cluster removes everything this chapter created, including
the node label. Then undo the host change as the
[lab README](../lab-helpers/gpu-real/README.md) describes.

```
make down PROFILE=gpu-real
```

**Tested with** kind v0.33.0, `kindest/node:v1.36.1` (cluster created
with [nvkind](https://github.com/NVIDIA/nvkind) at commit `c570504`),
kubectl v1.37.1, helm v4.3.0, device plugin chart 0.20.1,
nvidia-container-toolkit 1.20.2 (installed in the node by nvkind), NVIDIA driver 615.78.08, and the image
`nvcr.io/nvidia/k8s/cuda-sample:vectoradd-cuda12.5.0`. Generated names,
ages and log timestamps will differ on your run.

Not covered here: how the plugin talks to the kubelet internally, MIG,
Dynamic Resource Allocation (chapter 14), and monitoring.
[Chapter 18](18-gpu-sharing-and-quota.md) shows how to share one GPU
between several Pods and how to limit GPU use per namespace.
