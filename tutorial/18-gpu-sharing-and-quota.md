# 18. Sharing a GPU: time-slicing and a GPU quota per namespace

Chapter 17 ended with one real GPU advertised as `nvidia.com/gpu: 1`, a
unit the scheduler gives to one container at a time. This chapter changes
that number in two ways. A setting in the device plugin's configuration
makes it advertise each physical GPU as several units, so several Pods
can run on one GPU (time-slicing). A ResourceQuota then caps how many of
those units a namespace may request, so one team cannot take them all.

The sections start from a fresh `k8s-lab-gpu-real` cluster with the device
plugin installed as in chapter 17's first section; the short start-state
snippet is in
[`lab-helpers/gpu-real/README.md`](../../lab-helpers/gpu-real/README.md),
next to the one host-wide Docker change the cluster needs. After that
they use only `kubectl` and `helm`.

**In scope**: time-slicing with the plugin's `replicas` and
`failRequestsGreaterThanOne` settings, Pods that share a GPU, a request
above one unit, and a ResourceQuota on the GPU resource. **Not covered
here**: the GPU topics the last section lists.

Chapter 7 is the reference for ResourceQuota, chapter 8 for Helm, chapter
15 for `nvidia.com/gpu` as a count and for the rules for requesting it,
and chapter 17 for the device plugin and `runtimeClassName: nvidia`. This
chapter uses them without repeating them.

Verified against: a cluster created with
[nvkind](https://github.com/NVIDIA/nvkind) (commit
`c57050497cffee36f10c8b918d2727c4f26d886e`) from `kindest/node:v1.36.1`,
kind v0.33.0, kubectl client v1.37.1, helm v4.3.0, chart
`nvdp/nvidia-device-plugin` 0.20.1 (device plugin v0.20.1),
`nvidia-container-toolkit` 1.20.1 (`nvidia-ctk --version` in the worker
node), NVIDIA driver 615.78.08 on the host, one NVIDIA GPU, CUDA sample
image `nvcr.io/nvidia/k8s/cuda-sample:vectoradd-cuda12.5.0`.

**How the output is shown.** Tables, `describe` output and events are
shown as printed. The `AGE` values, the `IP` column, the suffix of a
generated Pod name, the ReplicaSet hash and a `lastTransitionTime` differ
on every run. Helm commands are shown without their output: the `kubectl`
command after each one shows the effect. Where the **Expected output**
line says lines are omitted, the output of those commands is left out.
The number of `Waiting for ...` lines that `rollout status` prints varies
from run to run. For events, `-o custom-columns` prints only the columns
named. A scheduling message starts with a count of nodes and the reasons
they were excluded; the rest of it is not discussed here.

### Time-slicing: one GPU advertised as four

**Why**: until now the plugin advertised one unit per GPU. Its
configuration file can name a resource and a number of `replicas`; the
plugin then advertises that many units for each physical GPU, under the
same name (the plugin can also rename them with `renameByDefault`, which
is not used here). The format is in the plugin's
[README](https://github.com/NVIDIA/k8s-device-plugin/blob/v0.20.1/README.md#with-cuda-time-slicing) (tag v0.20.1). The chart builds
that file from its `config.map` value. In
[`gpu-share-values.yaml`](../../tutorial/examples/gpu/gpu-share-values.yaml)
the two keys that matter are `sharing.timeSlicing.resources[].name`
(`nvidia.com/gpu`) and `replicas: 4`. Four is this chapter's choice, small
enough to fill in the next section.

`runtimeClassName` is not in the values file. With Helm 4.3.0 a default
`helm upgrade` does not carry over values from the previous release (observed:
after an upgrade without it, the DaemonSet's `runtimeClassName` was empty;
`--reuse-values` was not tested), so every `helm` command in this chapter
repeats `--set runtimeClassName=nvidia`.

**Example**:

```
kubectl get nodes -o custom-columns='NAME:.metadata.name,CAPACITY:.status.capacity.nvidia\.com/gpu,ALLOCATABLE:.status.allocatable.nvidia\.com/gpu'
helm upgrade nvdp nvdp/nvidia-device-plugin --version 0.20.1 --namespace nvidia-device-plugin -f tutorial/examples/gpu/gpu-share-values.yaml --set runtimeClassName=nvidia
kubectl rollout status ds/nvdp-nvidia-device-plugin -n nvidia-device-plugin --timeout=180s
kubectl wait --for=jsonpath='{.status.allocatable.nvidia\.com/gpu}'=4 node/k8s-lab-gpu-real-worker --timeout=120s
kubectl get nodes -o custom-columns='NAME:.metadata.name,CAPACITY:.status.capacity.nvidia\.com/gpu,ALLOCATABLE:.status.allocatable.nvidia\.com/gpu'
kubectl get pods -n nvidia-device-plugin
kubectl get pods -n nvidia-device-plugin -l app.kubernetes.io/name=nvidia-device-plugin -o jsonpath='{.items[0].spec.containers[?(@.name=="nvidia-device-plugin-sidecar")].securityContext.capabilities}{"\n"}'
```

**Expected output** (the `helm` output is omitted):

```
$ kubectl get nodes -o custom-columns='NAME:.metadata.name,CAPACITY:.status.capacity.nvidia\.com/gpu,ALLOCATABLE:.status.allocatable.nvidia\.com/gpu'
NAME                             CAPACITY   ALLOCATABLE
k8s-lab-gpu-real-control-plane   <none>     <none>
k8s-lab-gpu-real-worker          1          1

$ kubectl rollout status ds/nvdp-nvidia-device-plugin -n nvidia-device-plugin --timeout=180s
Waiting for daemon set "nvdp-nvidia-device-plugin" rollout to finish: 0 out of 1 new pods have been updated...
Waiting for daemon set "nvdp-nvidia-device-plugin" rollout to finish: 0 out of 1 new pods have been updated...
Waiting for daemon set "nvdp-nvidia-device-plugin" rollout to finish: 0 of 1 updated pods are available...
daemon set "nvdp-nvidia-device-plugin" successfully rolled out

$ kubectl wait --for=jsonpath='{.status.allocatable.nvidia\.com/gpu}'=4 node/k8s-lab-gpu-real-worker --timeout=120s
node/k8s-lab-gpu-real-worker condition met

$ kubectl get nodes -o custom-columns='NAME:.metadata.name,CAPACITY:.status.capacity.nvidia\.com/gpu,ALLOCATABLE:.status.allocatable.nvidia\.com/gpu'
NAME                             CAPACITY   ALLOCATABLE
k8s-lab-gpu-real-control-plane   <none>     <none>
k8s-lab-gpu-real-worker          4          4

$ kubectl get pods -n nvidia-device-plugin
NAME                              READY   STATUS    RESTARTS   AGE
nvdp-nvidia-device-plugin-wgrw8   2/2     Running   0          7s

$ kubectl get pods -n nvidia-device-plugin -l app.kubernetes.io/name=nvidia-device-plugin -o jsonpath='{.items[0].spec.containers[?(@.name=="nvidia-device-plugin-sidecar")].securityContext.capabilities}{"\n"}'
{"add":["SYS_ADMIN"]}
```

One physical GPU now shows capacity 4 and allocatable 4 (observed), with no
change to the node. The plugin Pod shows `READY 2/2`: a config map adds an
init container and a sidecar container next to the plugin container
(observed, chart 0.20.1), and the sidecar's `securityContext` adds the
`SYS_ADMIN` capability, as the last command prints. Chapter 17's plugin
Pod, installed without a config map, showed `1/1`.

### Pods sharing one GPU

**Why**: four Pods, in `gpu-share-sleepers.yaml`, each ask for
`nvidia.com/gpu: 1` under `limits` (chapter 15's rules) with
`runtimeClassName: nvidia`, and sleep so they keep their unit. That is all
four units. `gpu-share-sleeper-5.yaml` is a fifth Pod with the same
request. `gpu-real-namespace.yaml` is chapter 17's namespace file, so the
Pods are in `gpu-real` again.

**Example**:

```
kubectl apply -f tutorial/examples/gpu/gpu-real-namespace.yaml
kubectl apply -f tutorial/examples/gpu/gpu-share-sleepers.yaml
kubectl wait --for=condition=Ready pod --all -n gpu-real --timeout=240s
kubectl get pods -n gpu-real -o wide
kubectl apply -f tutorial/examples/gpu/gpu-share-sleeper-5.yaml
kubectl wait --for=condition=PodScheduled=false pod/gpu-share-5 -n gpu-real --timeout=60s
kubectl get pods -n gpu-real
kubectl get events -n gpu-real --field-selector involvedObject.name=gpu-share-5,reason=FailedScheduling -o custom-columns='REASON:.reason,MESSAGE:.message'
```

**Expected output** (`apply` and `wait` lines omitted):

```
$ kubectl get pods -n gpu-real -o wide
NAME          READY   STATUS    RESTARTS   AGE   IP           NODE                      NOMINATED NODE   READINESS GATES
gpu-share-1   1/1     Running   0          51s   10.244.1.4   k8s-lab-gpu-real-worker   <none>           <none>
gpu-share-2   1/1     Running   0          51s   10.244.1.5   k8s-lab-gpu-real-worker   <none>           <none>
gpu-share-3   1/1     Running   0          51s   10.244.1.6   k8s-lab-gpu-real-worker   <none>           <none>
gpu-share-4   1/1     Running   0          51s   10.244.1.7   k8s-lab-gpu-real-worker   <none>           <none>

$ kubectl get pods -n gpu-real
NAME          READY   STATUS    RESTARTS   AGE
gpu-share-1   1/1     Running   0          51s
gpu-share-2   1/1     Running   0          51s
gpu-share-3   1/1     Running   0          51s
gpu-share-4   1/1     Running   0          51s
gpu-share-5   0/1     Pending   0          0s

$ kubectl get events -n gpu-real --field-selector involvedObject.name=gpu-share-5,reason=FailedScheduling -o custom-columns='REASON:.reason,MESSAGE:.message'
REASON             MESSAGE
FailedScheduling   0/2 nodes are available: 1 Insufficient nvidia.com/gpu, 1 node(s) had untolerated taint(s). no new claims to deallocate, preemption: 0/2 nodes are available: 1 No preemption victims found for incoming pod, 1 Preemption is not helpful for scheduling.
```

All four Pods run on the worker, the one node that advertises the
resource (observed). The fifth stays `Pending` with chapter 15's
`Insufficient nvidia.com/gpu` clause and chapter 16's control-plane taint
clause: the scheduler counts these units the way it counted chapter 15's
fake GPUs.

Four Pods on one GPU are not isolated from each other. From the plugin's
docs, not observed here: nothing special is done to isolate workloads
granted replicas of the same GPU, each can reach the GPU's memory, and if
one crashes they all do
([README, v0.20.1, lines 367-371](https://github.com/NVIDIA/k8s-device-plugin/blob/v0.20.1/README.md#L367-L371)).

### Requests above one

**Why**: with `replicas: 4` a Pod can ask for 2 units, and the scheduler
counts 2 (observed below, in the node's `Allocated resources`);
`gpu-share-two-pod.yaml` is that Pod. The plugin's README notes that
requesting more than one shared GPU does not guarantee a proportional
amount of compute, only access to a GPU shared with other clients, and
recommends `failRequestsGreaterThanOne: true`; the default is `false`
for backwards compatibility
([README, lines 473-483](https://github.com/NVIDIA/k8s-device-plugin/blob/v0.20.1/README.md#L473-L483)). With it set, the plugin
refuses a request above one
([lines 405-408](https://github.com/NVIDIA/k8s-device-plugin/blob/v0.20.1/README.md#L405-L408)).
`gpu-share-values-fail-gt1.yaml` is the same configuration plus that
setting, and it stays on for the rest of the chapter. Then
`gpu-share-two-strict-pod.yaml` makes the same request under a new name.

**Example**:

```
kubectl delete pod --all -n gpu-real
kubectl apply -f tutorial/examples/gpu/gpu-share-two-pod.yaml
kubectl wait --for=condition=Ready pod/gpu-share-two -n gpu-real --timeout=120s
kubectl describe node k8s-lab-gpu-real-worker | sed -n '/^Allocated resources:/,/^Events:/{/^Events:/!p}'
kubectl delete pod gpu-share-two -n gpu-real
helm upgrade nvdp nvdp/nvidia-device-plugin --version 0.20.1 --namespace nvidia-device-plugin -f tutorial/examples/gpu/gpu-share-values-fail-gt1.yaml --set runtimeClassName=nvidia
kubectl rollout status ds/nvdp-nvidia-device-plugin -n nvidia-device-plugin --timeout=180s
kubectl wait --for=jsonpath='{.status.allocatable.nvidia\.com/gpu}'=4 node/k8s-lab-gpu-real-worker --timeout=120s
kubectl apply -f tutorial/examples/gpu/gpu-share-two-strict-pod.yaml
kubectl wait --for=jsonpath='{.status.phase}'=Failed pod/gpu-share-two-strict -n gpu-real --timeout=90s
kubectl get pod gpu-share-two-strict -n gpu-real -o wide
kubectl get pod gpu-share-two-strict -n gpu-real -o jsonpath='{.status.reason}{"\n"}{.status.message}{"\n"}'
```

**Expected output** (the `helm` output, the `delete`, `apply` and
`rollout status` lines and the first two `wait` lines are omitted):

```
$ kubectl describe node k8s-lab-gpu-real-worker | sed -n '/^Allocated resources:/,/^Events:/{/^Events:/!p}'
Allocated resources:
  (Total limits may be over 100 percent, i.e., overcommitted.)
  Resource           Requests   Limits
  --------           --------   ------
  cpu                100m (1%)  100m (1%)
  memory             50Mi (0%)  50Mi (0%)
  ephemeral-storage  0 (0%)     0 (0%)
  hugepages-1Gi      0 (0%)     0 (0%)
  hugepages-2Mi      0 (0%)     0 (0%)
  nvidia.com/gpu     2          2

$ kubectl wait --for=jsonpath='{.status.phase}'=Failed pod/gpu-share-two-strict -n gpu-real --timeout=90s
pod/gpu-share-two-strict condition met

$ kubectl get pod gpu-share-two-strict -n gpu-real -o wide
NAME                   READY   STATUS                     RESTARTS   AGE   IP       NODE                      NOMINATED NODE   READINESS GATES
gpu-share-two-strict   0/1     UnexpectedAdmissionError   0          1s    <none>   k8s-lab-gpu-real-worker   <none>           <none>

$ kubectl get pod gpu-share-two-strict -n gpu-real -o jsonpath='{.status.reason}{"\n"}{.status.message}{"\n"}'
UnexpectedAdmissionError
Pod was rejected: Allocate failed due to rpc error: code = Unknown desc = invalid allocation request for "nvidia.com/gpu": invalid request: maximum request size for shared resources is 1; found 2, which is unexpected
```

The first Pod took 2 of the 4 units (observed). The second was refused,
and the order matters: `NODE` is set, so the scheduler placed it, and then
the plugin rejected the allocation on that node, so the Pod ended
`Failed` with `UnexpectedAdmissionError`. That is a failure on the
kubelet's side after scheduling (the README's sample event comes from the
`kubelet`, [line 469](https://github.com/NVIDIA/k8s-device-plugin/blob/v0.20.1/README.md#L469)), not a `Pending` Pod with a scheduling
event, and a bare Pod is not retried: per the README it must be deleted,
changed and applied again (lines 405-408, linked above).

### A GPU quota per namespace

**Why**: with four units per GPU, units are cheap to ask for, so cap them
per namespace with a ResourceQuota (chapter 7). For an extended resource
the Kubernetes docs say only quota items with the `requests.` prefix are
allowed ([Quota for extended resources](https://kubernetes.io/docs/concepts/policy/resource-quotas/#quota-for-extended-resources)).
The API accepts the other spellings anyway (observed below).
`gpu-quota-wrong-keys.yaml`
has two quotas with a hard value of 2: `limits.nvidia.com/gpu` and the
bare `nvidia.com/gpu`. Then three Pods ask for one unit each
(`gpu-quota-pods.yaml` has `a` and `b`, `gpu-quota-pod-c.yaml` has `c`);
all three should be refused if either quota counted anything.
`gpu-quota-namespace.yaml` creates the namespace `gpu-quota`.

**Example**:

```
kubectl apply -f tutorial/examples/gpu/gpu-quota-namespace.yaml
kubectl apply -f tutorial/examples/gpu/gpu-quota-wrong-keys.yaml
kubectl apply -f tutorial/examples/gpu/gpu-quota-pods.yaml -f tutorial/examples/gpu/gpu-quota-pod-c.yaml
kubectl wait --for=condition=Ready pod --all -n gpu-quota --timeout=180s
kubectl describe resourcequota -n gpu-quota
kubectl delete -f tutorial/examples/gpu/gpu-quota-wrong-keys.yaml -f tutorial/examples/gpu/gpu-quota-pods.yaml -f tutorial/examples/gpu/gpu-quota-pod-c.yaml
```

**Expected output** (the namespace and Pod `apply` lines and the `delete`
lines are omitted):

```
$ kubectl apply -f tutorial/examples/gpu/gpu-quota-wrong-keys.yaml
resourcequota/gpu-quota-limits-key created
resourcequota/gpu-quota-bare-key created

$ kubectl wait --for=condition=Ready pod --all -n gpu-quota --timeout=180s
pod/gpu-quota-a condition met
pod/gpu-quota-b condition met
pod/gpu-quota-c condition met

$ kubectl describe resourcequota -n gpu-quota
Name:           gpu-quota-bare-key
Namespace:      gpu-quota
Resource        Used  Hard
--------        ----  ----
nvidia.com/gpu  0     2


Name:                  gpu-quota-limits-key
Namespace:             gpu-quota
Resource               Used  Hard
--------               ----  ----
limits.nvidia.com/gpu  0     2
```

Both quotas were accepted, all three Pods ran, and `Used` stayed 0
(observed): the `limits.` and bare keys are accepted and never count, so
only `requests.` keys enforce.
The right key is in `gpu-quota.yaml`: `requests.nvidia.com/gpu: "2"`. A Pod
that sets only `limits` gets a request equal to it (chapter 15), so it
counts. Pods `a` and `b` fill the quota and `c` should be refused when it
is created. Then one Pod is deleted and `gpu-quota-vectoradd-pod.yaml`,
the CUDA sample from chapter 17 with one unit, runs to completion.

**Example**:

```
kubectl apply -f tutorial/examples/gpu/gpu-quota.yaml
kubectl apply -f tutorial/examples/gpu/gpu-quota-pods.yaml
kubectl wait --for=condition=Ready pod --all -n gpu-quota --timeout=180s
kubectl describe resourcequota gpu-quota -n gpu-quota
kubectl apply -f tutorial/examples/gpu/gpu-quota-pod-c.yaml
kubectl delete pod gpu-quota-a -n gpu-quota
kubectl apply -f tutorial/examples/gpu/gpu-quota-vectoradd-pod.yaml
kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/gpu-quota-vectoradd -n gpu-quota --timeout=180s
kubectl describe resourcequota gpu-quota -n gpu-quota
```

**Expected output** (the `apply` lines of the quota and of the Pods that
are admitted, the first `wait` and the `delete` line are omitted):

```
$ kubectl describe resourcequota gpu-quota -n gpu-quota
Name:                    gpu-quota
Namespace:               gpu-quota
Resource                 Used  Hard
--------                 ----  ----
requests.nvidia.com/gpu  2     2

$ kubectl apply -f tutorial/examples/gpu/gpu-quota-pod-c.yaml
Error from server (Forbidden): error when creating "tutorial/examples/gpu/gpu-quota-pod-c.yaml": pods "gpu-quota-c" is forbidden: exceeded quota: gpu-quota, requested: requests.nvidia.com/gpu=1, used: requests.nvidia.com/gpu=2, limited: requests.nvidia.com/gpu=2

$ kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/gpu-quota-vectoradd -n gpu-quota --timeout=180s
pod/gpu-quota-vectoradd condition met

$ kubectl describe resourcequota gpu-quota -n gpu-quota
Name:                    gpu-quota
Namespace:               gpu-quota
Resource                 Used  Hard
--------                 ----  ----
requests.nvidia.com/gpu  1     2
```

`c` was refused by the API server with `403 Forbidden` when it was
created (observed). Once `vectoradd` had succeeded, `Used`
was 1 (observed): the finished Pod no longer counts, so a quota limits
Pods that are still using units, not every Pod ever created.

A Deployment shows the same refusal differently. Its ReplicaSet creates
the Pods, so `gpu-quota-deployment.yaml`, three replicas against a quota
of 2, gets two Pods and a failure condition on the ReplicaSet instead of
a refused `apply`:

**Example**:

```
kubectl delete pod --all -n gpu-quota
kubectl apply -f tutorial/examples/gpu/gpu-quota-deployment.yaml
kubectl wait --for=jsonpath='{.status.readyReplicas}'=2 deployment/gpu-quota-deploy -n gpu-quota --timeout=180s
kubectl wait --for=jsonpath='{.status.conditions[?(@.type=="ReplicaFailure")].status}'=True rs -l app=gpu-quota-deploy -n gpu-quota --timeout=120s
kubectl get deploy,rs -n gpu-quota
kubectl get rs -l app=gpu-quota-deploy -n gpu-quota -o jsonpath='{.items[0].status.conditions}{"\n"}'
```

**Expected output** (the `delete` and `apply` lines are omitted):

```
$ kubectl wait --for=jsonpath='{.status.readyReplicas}'=2 deployment/gpu-quota-deploy -n gpu-quota --timeout=180s
deployment.apps/gpu-quota-deploy condition met

$ kubectl wait --for=jsonpath='{.status.conditions[?(@.type=="ReplicaFailure")].status}'=True rs -l app=gpu-quota-deploy -n gpu-quota --timeout=120s
replicaset.apps/gpu-quota-deploy-97fcd84bc condition met

$ kubectl get deploy,rs -n gpu-quota
NAME                               READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/gpu-quota-deploy   2/3     2            2           5s

NAME                                         DESIRED   CURRENT   READY   AGE
replicaset.apps/gpu-quota-deploy-97fcd84bc   3         2         2       5s

$ kubectl get rs -l app=gpu-quota-deploy -n gpu-quota -o jsonpath='{.items[0].status.conditions}{"\n"}'
[{"lastTransitionTime":"2026-11-09T11:09:11Z","message":"pods \"gpu-quota-deploy-97fcd84bc-h26sw\" is forbidden: exceeded quota: gpu-quota, requested: requests.nvidia.com/gpu=1, used: requests.nvidia.com/gpu=2, limited: requests.nvidia.com/gpu=2","reason":"FailedCreate","status":"True","type":"ReplicaFailure"}]
```

The Deployment is `2/3`, and the ReplicaSet reports `ReplicaFailure` with
reason `FailedCreate` and the same quota message (observed). The refusal
is reported on the ReplicaSet, so that is where to look.

### Teardown, and what this chapter did not cover

**Why**: deleting the namespaces removes the Pods, the Deployment and the
quotas; the plugin goes with `helm uninstall`; `make down` removes the
cluster, and the lab README describes undoing the host change.

**Example**:

```
kubectl delete namespace gpu-quota gpu-real
helm uninstall nvdp --namespace nvidia-device-plugin
make down PROFILE=gpu-real
```

**Expected output** (the `helm` and `make` output is omitted):

```
$ kubectl delete namespace gpu-quota gpu-real
namespace "gpu-quota" deleted
namespace "gpu-real" deleted
```

Left out on purpose, each a larger topic of its own: the
[NVIDIA GPU Operator](https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/index.html),
[MIG](https://docs.nvidia.com/datacenter/tesla/mig-user-guide/index.html)
(Multi-Instance GPU, NVIDIA's user guide), Dynamic Resource Allocation
([chapter 14](14-advanced-topics.md)), MPS (the plugin's other sharing
mode; it partitions memory and compute per workload and cannot be combined
with time-slicing, per the
[README, lines 365-376](https://github.com/NVIDIA/k8s-device-plugin/blob/v0.20.1/README.md#L365-L376)),
[Kueue](https://kueue.sigs.k8s.io/)
(a job queueing system for Kubernetes) and GPU monitoring, for example
with [DCGM-Exporter](https://github.com/NVIDIA/dcgm-exporter) (hardware
telemetry for Prometheus).
