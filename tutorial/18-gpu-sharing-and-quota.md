# 18. Sharing a GPU: time-slicing and a GPU quota per namespace

At the end of chapter 17, the node had one GPU and advertised one
`nvidia.com/gpu`, so only one container at a time could have it. GPUs
are expensive, and many workloads (a notebook, a small inference
service, a test job) use only a fraction of one. This chapter covers two
tools for that situation:

- **Time-slicing** lets several Pods share one GPU. The device plugin
  advertises each physical GPU as several units, and the GPU takes turns
  running work from each container that has one.
- **A ResourceQuota** on the GPU resource caps how many units a
  namespace can use, so one team can't take every unit on the cluster.

To follow along, start from a fresh `k8s-lab-gpu-real` cluster with the
device plugin installed as in chapter 17. The commands for that start
state are in [`lab-helpers/gpu-real/README.md`](../lab-helpers/gpu-real/README.md).

### Time-slicing: one GPU advertised as four

**Why**: the device plugin reads an optional configuration file. In it
you can say "advertise each GPU as N units of `nvidia.com/gpu`". The
scheduler then sees N units and places up to N Pods on that GPU, each
asking for one. Nothing else changes: Pods ask for `nvidia.com/gpu: 1`
exactly as before.

What sharing doesn't give you is isolation. NVIDIA's
[documentation for time-slicing](https://github.com/NVIDIA/k8s-device-plugin/blob/v0.20.1/README.md#with-cuda-time-slicing)
says the Pods sharing a GPU are not isolated from each other: they share
the GPU's memory, and if one crashes, they all do. Time-slicing suits
workloads you trust to share, such as a team's own notebooks, not
strangers' jobs.

**Example**: [`gpu-share-values.yaml`](examples/gpu/gpu-share-values.yaml)
holds the Helm values for the chart. The part that matters is:

```
runtimeClassName: nvidia
config:
  map:
    default: |-
      version: v1
      sharing:
        timeSlicing:
          resources:
          - name: nvidia.com/gpu
            replicas: 4
```

Everything under `default: |-` is the plugin's configuration file:
advertise each GPU as 4 units of `nvidia.com/gpu`. Four is small enough
to fill in a moment. `runtimeClassName: nvidia` is there because chapter
17 set it with `--set`, and an upgrade that passes a values file
replaces values set earlier with `--set`. Keeping it in the file means
the upgrade can't drop it.

Before the upgrade, the worker has one unit:

```
kubectl get node k8s-lab-gpu-real-worker -o custom-columns='CAPACITY:.status.capacity.nvidia\.com/gpu,ALLOCATABLE:.status.allocatable.nvidia\.com/gpu'
```

```
CAPACITY   ALLOCATABLE
1          1
```

Upgrade the release with the values file and wait for the new plugin Pod:

```
helm upgrade nvdp nvdp/nvidia-device-plugin --version 0.20.1 \
  --namespace nvidia-device-plugin -f tutorial/examples/gpu/gpu-share-values.yaml
kubectl rollout status daemonset/nvdp-nvidia-device-plugin -n nvidia-device-plugin
```

```
Waiting for daemon set "nvdp-nvidia-device-plugin" rollout to finish: 0 out of 1 new pods have been updated...
Waiting for daemon set "nvdp-nvidia-device-plugin" rollout to finish: 0 of 1 updated pods are available...
daemon set "nvdp-nvidia-device-plugin" successfully rolled out
```

A few seconds later the node check shows the new count:

```
kubectl get node k8s-lab-gpu-real-worker -o custom-columns='CAPACITY:.status.capacity.nvidia\.com/gpu,ALLOCATABLE:.status.allocatable.nvidia\.com/gpu'
```

```
CAPACITY   ALLOCATABLE
4          4
```

The node didn't change; the plugin now reports its one GPU as four
units. The plugin Pod has also changed shape:

```
kubectl get pods -n nvidia-device-plugin
```

```
NAME                              READY   STATUS    RESTARTS   AGE
nvdp-nvidia-device-plugin-hpn2s   2/2     Running   0          6s
```

`2/2` means two containers. When you give the chart a configuration, it
runs a second container, `nvidia-device-plugin-sidecar`, next to the
plugin. It runs a tool called `config-manager` that hands the plugin its
configuration file.

### Pods sharing one GPU

**Why**: four units should mean four Pods running on one GPU, and a
fifth waiting.

**Example**: [`gpu-share-sleepers.yaml`](examples/gpu/gpu-share-sleepers.yaml)
defines four Pods, `gpu-share-1` to `gpu-share-4`. Each asks for one GPU
the way chapter 17's Pods did, and sleeps so it keeps its unit.

```
kubectl apply -f tutorial/examples/gpu/gpu-real-namespace.yaml
kubectl apply -f tutorial/examples/gpu/gpu-share-sleepers.yaml
```

When the image has been pulled, all four are running on the worker:

```
kubectl get pods -n gpu-real -o wide
```

```
NAME          READY   STATUS    RESTARTS   AGE   IP           NODE                      NOMINATED NODE   READINESS GATES
gpu-share-1   1/1     Running   0          54s   10.244.1.4   k8s-lab-gpu-real-worker   <none>           <none>
gpu-share-2   1/1     Running   0          53s   10.244.1.6   k8s-lab-gpu-real-worker   <none>           <none>
gpu-share-3   1/1     Running   0          53s   10.244.1.5   k8s-lab-gpu-real-worker   <none>           <none>
gpu-share-4   1/1     Running   0          53s   10.244.1.7   k8s-lab-gpu-real-worker   <none>           <none>
```

They really do share one GPU. Ask two of them which GPU they have:

```
kubectl exec gpu-share-1 -n gpu-real -- nvidia-smi -L
kubectl exec gpu-share-4 -n gpu-real -- nvidia-smi -L
```

```
GPU 0: <GPU model> (UUID: GPU-<GPU UUID>)
GPU 0: <GPU model> (UUID: GPU-<GPU UUID>)
```

Both print the same GPU, with the same UUID (the real model and UUID are
replaced here).

Now a fifth Pod, [`gpu-share-sleeper-5.yaml`](examples/gpu/gpu-share-sleeper-5.yaml),
with the same request:

```
kubectl apply -f tutorial/examples/gpu/gpu-share-sleeper-5.yaml
kubectl get pods -n gpu-real
```

```
NAME          READY   STATUS    RESTARTS   AGE
gpu-share-1   1/1     Running   0          55s
gpu-share-2   1/1     Running   0          54s
gpu-share-3   1/1     Running   0          54s
gpu-share-4   1/1     Running   0          54s
gpu-share-5   0/1     Pending   0          0s
```

```
kubectl describe pod gpu-share-5 -n gpu-real | grep -A3 Events:
```

```
Events:
  Type     Reason            Age   From               Message
  ----     ------            ----  ----               -------
  Warning  FailedScheduling  1s    default-scheduler  0/2 nodes are available: 1 Insufficient nvidia.com/gpu, 1 node(s) had untolerated taint(s). no new claims to deallocate, preemption: 0/2 nodes are available: 1 No preemption victims found for incoming pod, 1 Preemption is not helpful for scheduling.
```

This is the same message as chapter 17's two-GPU Pod: the worker has no
free unit, and the control-plane node is tainted. The scheduler counts
shared units exactly as it counted whole GPUs; it doesn't know they are
shared.

Clean up before the next section:

```
kubectl delete pod --all -n gpu-real
```

### Asking for more than one unit

**Why**: with four units on one GPU, a Pod can ask for two. That looks
like "half the GPU", but it isn't: NVIDIA's documentation says that
asking for more than one shared unit doesn't guarantee a matching share
of the GPU's compute, only access to a GPU that others share too. Because such a request promises something it can't deliver,
the plugin has a setting to refuse it.

**Example**: first without the setting.
[`gpu-share-two-pod.yaml`](examples/gpu/gpu-share-two-pod.yaml) asks for
`nvidia.com/gpu: 2`:

```
kubectl apply -f tutorial/examples/gpu/gpu-share-two-pod.yaml
```

A few seconds later:

```
kubectl get pod gpu-share-two -n gpu-real
```

```
NAME            READY   STATUS    RESTARTS   AGE
gpu-share-two   1/1     Running   0          2s
```

It runs, and the node's description shows it holding two of the four
units:

```
kubectl describe node k8s-lab-gpu-real-worker | grep nvidia.com/gpu
```

```
                    nvidia.com/gpu.present=true
  nvidia.com/gpu:     4
  nvidia.com/gpu:     4
  nvidia.com/gpu     2          2
```

The first line is the node label from chapter 17. The next two are
capacity and allocatable. The last one comes from the node's
`Allocated resources` table: requests 2, limits 2.

Now turn on the setting. [`gpu-share-values-fail-gt1.yaml`](examples/gpu/gpu-share-values-fail-gt1.yaml)
is the same values file with one more line under `timeSlicing`:
`failRequestsGreaterThanOne: true`. NVIDIA recommends turning it on; it
is off by default only so that existing setups keep working. It stays on
for the rest of this chapter.

```
kubectl delete pod gpu-share-two -n gpu-real
helm upgrade nvdp nvdp/nvidia-device-plugin --version 0.20.1 \
  --namespace nvidia-device-plugin -f tutorial/examples/gpu/gpu-share-values-fail-gt1.yaml
kubectl rollout status daemonset/nvdp-nvidia-device-plugin -n nvidia-device-plugin
```

Then make the same two-unit request again, under a new name
([`gpu-share-two-strict-pod.yaml`](examples/gpu/gpu-share-two-strict-pod.yaml)):

```
kubectl apply -f tutorial/examples/gpu/gpu-share-two-strict-pod.yaml
kubectl get pod gpu-share-two-strict -n gpu-real
```

```
NAME                   READY   STATUS                     RESTARTS   AGE
gpu-share-two-strict   0/1     UnexpectedAdmissionError   0          0s
```

This isn't `Pending`. The Pod's events show what happened, in order:

```
kubectl describe pod gpu-share-two-strict -n gpu-real | grep -A6 Events:
```

```
Events:
  Type     Reason                    Age   From               Message
  ----     ------                    ----  ----               -------
  Normal   Scheduled                 0s    default-scheduler  Successfully assigned gpu-real/gpu-share-two-strict to k8s-lab-gpu-real-worker
  Warning  UnexpectedAdmissionError  0s    kubelet            Allocate failed due to rpc error: code = Unknown desc = invalid allocation request for "nvidia.com/gpu": invalid request: maximum request size for shared resources is 1; found 2, which is unexpected
```

The scheduler saw four free units and placed the Pod. Then the kubelet
asked the plugin for two units, the plugin refused, and the kubelet
rejected the Pod. The Pod is now `Failed` and stays that way: a bare Pod
isn't retried. To run it, delete it, change the request to 1 and apply
it again.

So the two GPU failures look different. Too few free units: the Pod is
`Pending`, and the scheduler's event explains why. A request the plugin
refuses: the Pod is scheduled, then rejected by the kubelet with
`UnexpectedAdmissionError`.

```
kubectl delete pod gpu-share-two-strict -n gpu-real
```

### A GPU quota per namespace

**Why**: when units are this easy to hand out, one namespace can take
them all. A ResourceQuota (chapter 7) caps the total a namespace may
request. For an extended resource like `nvidia.com/gpu`, the quota key
must start with `requests.`, as the
[Kubernetes documentation](https://kubernetes.io/docs/concepts/policy/resource-quotas/#quota-for-extended-resources)
says. That rule is easy to get wrong, and getting it wrong fails
silently, so we start with the wrong keys.

**Example, the wrong keys**:
[`gpu-quota-wrong-keys.yaml`](examples/gpu/gpu-quota-wrong-keys.yaml)
creates two quotas with a limit of 2, one keyed `limits.nvidia.com/gpu`
and one keyed `nvidia.com/gpu`. Then three Pods ask for one unit each.
If either quota worked, the third Pod would be refused.

```
kubectl apply -f tutorial/examples/gpu/gpu-quota-namespace.yaml
kubectl apply -f tutorial/examples/gpu/gpu-quota-wrong-keys.yaml
kubectl apply -f tutorial/examples/gpu/gpu-quota-pods.yaml -f tutorial/examples/gpu/gpu-quota-pod-c.yaml
```

```
namespace/gpu-quota created
resourcequota/gpu-quota-limits-key created
resourcequota/gpu-quota-bare-key created
pod/gpu-quota-a created
pod/gpu-quota-b created
pod/gpu-quota-c created
```

All three Pods were created, and once running, the quotas show nothing
used:

```
kubectl get resourcequota -n gpu-quota
```

```
NAME                   REQUEST               LIMIT                        AGE
gpu-quota-bare-key     nvidia.com/gpu: 0/2                                5s
gpu-quota-limits-key                         limits.nvidia.com/gpu: 0/2   5s
```

Kubernetes accepted both quotas without complaint, and neither counts
anything: `0/2` with three GPU Pods running. Remove them:

```
kubectl delete -f tutorial/examples/gpu/gpu-quota-wrong-keys.yaml -f tutorial/examples/gpu/gpu-quota-pods.yaml -f tutorial/examples/gpu/gpu-quota-pod-c.yaml
```

**Example, the right key**:
[`gpu-quota.yaml`](examples/gpu/gpu-quota.yaml) sets
`requests.nvidia.com/gpu: "2"`. Our Pods only set `limits`, but a Pod
that sets only a limit for a resource gets a request equal to it
(chapter 15), so they count. Apply the quota and two Pods:

```
kubectl apply -f tutorial/examples/gpu/gpu-quota.yaml
kubectl apply -f tutorial/examples/gpu/gpu-quota-pods.yaml
kubectl get resourcequota -n gpu-quota
```

```
NAME        REQUEST                        LIMIT   AGE
gpu-quota   requests.nvidia.com/gpu: 2/2           4s
```

The quota is full. A third Pod is refused when you create it:

```
kubectl apply -f tutorial/examples/gpu/gpu-quota-pod-c.yaml
```

```
Error from server (Forbidden): error when creating "tutorial/examples/gpu/gpu-quota-pod-c.yaml": pods "gpu-quota-c" is forbidden: exceeded quota: gpu-quota, requested: requests.nvidia.com/gpu=1, used: requests.nvidia.com/gpu=2, limited: requests.nvidia.com/gpu=2
```

This refusal comes from the API server, before the Pod exists. Compare
the previous section, where the Pod was created and scheduled and only
then rejected on the node.

The quota counts Pods that are still holding units, not every Pod ever
created. Delete one Pod and run chapter 17's CUDA sample in its place
([`gpu-quota-vectoradd-pod.yaml`](examples/gpu/gpu-quota-vectoradd-pod.yaml)):

```
kubectl delete pod gpu-quota-a -n gpu-quota
kubectl apply -f tutorial/examples/gpu/gpu-quota-vectoradd-pod.yaml
```

Once it has finished:

```
kubectl get pods -n gpu-quota
kubectl get resourcequota -n gpu-quota
```

```
NAME                  READY   STATUS      RESTARTS   AGE
gpu-quota-b           1/1     Running     0          39s
gpu-quota-vectoradd   0/1     Completed   0          4s

NAME        REQUEST                        LIMIT   AGE
gpu-quota   requests.nvidia.com/gpu: 1/2           40s
```

The completed Pod no longer counts, so only `gpu-quota-b` uses the
quota.

**Example, a Deployment against the quota**: most workloads aren't bare
Pods. [`gpu-quota-deployment.yaml`](examples/gpu/gpu-quota-deployment.yaml)
is a Deployment with three replicas of one unit each, against the quota
of 2:

```
kubectl delete pod --all -n gpu-quota
kubectl apply -f tutorial/examples/gpu/gpu-quota-deployment.yaml
```

When its Pods are running:

```
kubectl get deployment,replicaset -n gpu-quota
```

```
NAME                               READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/gpu-quota-deploy   2/3     2            2           4s

NAME                                         DESIRED   CURRENT   READY   AGE
replicaset.apps/gpu-quota-deploy-97fcd84bc   3         2         2       4s
```

`apply` succeeded, because the Deployment itself uses no GPU. The
ReplicaSet creates the Pods, so the quota refuses the third Pod there,
and the only sign of it is `2/3`. The reason is in the ReplicaSet's
events:

```
kubectl describe replicaset -n gpu-quota -l app=gpu-quota-deploy | grep -A5 Events:
```

```
Events:
  Type     Reason            Age              From                   Message
  ----     ------            ----             ----                   -------
  Normal   SuccessfulCreate  4s               replicaset-controller  Created pod: gpu-quota-deploy-97fcd84bc-7tb9v
  Warning  FailedCreate      4s               replicaset-controller  Error creating: pods "gpu-quota-deploy-97fcd84bc-mhh9g" is forbidden: exceeded quota: gpu-quota, requested: requests.nvidia.com/gpu=1, used: requests.nvidia.com/gpu=2, limited: requests.nvidia.com/gpu=2
  Normal   SuccessfulCreate  4s               replicaset-controller  Created pod: gpu-quota-deploy-97fcd84bc-sxpxh
```

When a GPU Deployment has fewer Pods than it asks for, look at its
ReplicaSet's events, not at the Deployment or its Pods.

### Cleaning up, and where to go next

Deleting the cluster removes everything this chapter created. Then undo
the host change as the [lab README](../lab-helpers/gpu-real/README.md)
describes.

```
make down PROFILE=gpu-real
```

**Tested with** the same versions as chapter 17: kind v0.33.0,
`kindest/node:v1.36.1` (cluster created with
[nvkind](https://github.com/NVIDIA/nvkind) at commit `c570504`), kubectl
v1.37.1, helm v4.3.0, device plugin chart 0.20.1,
nvidia-container-toolkit 1.20.2 (installed in the node by nvkind),
NVIDIA driver 615.78.08, and the image
`nvcr.io/nvidia/k8s/cuda-sample:vectoradd-cuda12.5.0`. Generated names,
IPs, ages and event timings will differ on your run.

This is the end of the GPU section. These topics were left out because
each is large enough for a chapter of its own:

- The [NVIDIA GPU Operator](https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/index.html),
  which installs the driver, the container toolkit, the device plugin
  and monitoring on GPU nodes for you.
- [MIG](https://docs.nvidia.com/datacenter/tesla/mig-user-guide/index.html)
  (Multi-Instance GPU), which splits some data-center GPUs into isolated
  parts in hardware.
- MPS, the plugin's other way of sharing a GPU, which gives each Pod a
  fixed share of memory and compute. It can't be combined with
  time-slicing.
- Dynamic Resource Allocation, the newer Kubernetes API for devices
  ([chapter 14](14-advanced-topics.md)).
- [Kueue](https://kueue.sigs.k8s.io/), a job queueing system for
  Kubernetes.
- GPU monitoring, for example with
  [DCGM-Exporter](https://github.com/NVIDIA/dcgm-exporter), which exports
  GPU metrics to Prometheus.
