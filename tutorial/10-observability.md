# 10. Observability and troubleshooting

In chapter 9, very different problems looked alike from the outside: a
forbidden RBAC verb, a Pod rejected by Pod Security, a connection
dropped by a NetworkPolicy. Nothing crashed; a request just never got
where it was going. This chapter is about finding out what's wrong in
general: where to look, and what each tool can and can't see. It builds
on the earlier chapters. A `CrashLoopBackOff`, for example, only makes
sense once you know how restarts work (chapter 3).

### Logs: `kubectl logs` only ever shows stdout/stderr

**Why**: `kubectl logs` doesn't read files inside the container. It
shows what the container runtime captured from the container's
**stdout and stderr**, and nothing else. A program that writes its log
only to a file of its own shows nothing in `kubectl logs`, however much
it logs.

On the node, the captured output lives in
`/var/log/pods/<namespace>_<pod>_<uid>/<container>/0.log`, and
`/var/log/containers/<pod>_<namespace>_<container>-<containerID>.log` is
a symlink to it. That's the same capture `kubectl logs` shows, read
straight from the node.

**Example**: a container that writes only to a file, never to
stdout:

```
kubectl run observability-demo-silent-pod --image=busybox:1.36 --restart=Never -- sh -c "while true; do echo \"internal event \$(date)\" >> /tmp/app.log; sleep 5; done"
kubectl logs observability-demo-silent-pod
kubectl exec observability-demo-silent-pod -- cat /tmp/app.log
```

**Expected output**: `kubectl logs` prints nothing, without an error,
because nothing was written to stdout. The file inside the container
keeps growing:

```
$ kubectl logs observability-demo-silent-pod
(no output)

$ kubectl exec observability-demo-silent-pod -- cat /tmp/app.log
internal event Fri Aug 28 06:27:02 UTC 2026
internal event Fri Aug 28 06:27:07 UTC 2026
internal event Fri Aug 28 06:27:12 UTC 2026
```

On the node, the captured log file is empty too, so it isn't something
`kubectl` missed: the runtime never received anything:

```
$ docker exec <node-container> readlink /var/log/containers/observability-demo-silent-pod_default_app-<id>.log
/var/log/pods/default_observability-demo-silent-pod_<uid>/app/0.log

$ docker exec <node-container> wc -l /var/log/pods/default_observability-demo-silent-pod_<uid>/app/0.log
0 /var/log/pods/default_observability-demo-silent-pod_<uid>/app/0.log
```

### `kubectl debug` and ephemeral containers

**Why**: many images contain no tools at all, on purpose, to keep them
small and reduce what an attacker could use. A **distroless** image, for
example, has the application and its runtime libraries but no shell or
package manager. `kubectl exec ... -- sh` fails on such an image.

An **ephemeral container** solves this. It's a temporary debugging
container that you add to a Pod that's already running. It's listed in
the Pod's `spec.ephemeralContainers`, separately from
`spec.containers`, and can't be added with `kubectl edit`.
`kubectl debug <pod> --image=<image> --target=<container>` adds one.
`--target` makes the debugging container share the target container's
process namespace, so your tools can see and inspect its processes,
without changing or restarting the Pod.

**Example**: the `registry.k8s.io/pause` image has no shell at all:

```
kubectl run observability-demo-shellless-pod --image=registry.k8s.io/pause:3.10 --restart=Never
kubectl exec observability-demo-shellless-pod -- sh -c "echo hi"
kubectl debug -it observability-demo-shellless-pod --image=busybox:1.36 --target=app -- sh -c "ps aux; cat /proc/1/comm"
kubectl get pod observability-demo-shellless-pod -o jsonpath='{.spec.ephemeralContainers[*].name}'
kubectl get pod observability-demo-shellless-pod -o jsonpath='{.spec.containers[*].name}'
```

**Expected output**: `exec` fails, because there's no `sh` to run. The
busybox debugging container can see the target's own process, `/pause`,
as PID 1:

```
$ kubectl exec observability-demo-shellless-pod -- sh -c "echo hi"
error: ... OCI runtime exec failed: exec failed: unable to start container process: exec: "sh": executable file not found in $PATH
```

```
Targeting container "app". If you don't see processes from this container it may be because the container runtime doesn't support this feature.
Defaulting debug container name to debugger-d77f6.

PID   USER     TIME  COMMAND
    1 65535     0:00 /pause
   20 root      0:00 sh -c ps aux; cat /proc/1/comm
   33 root      0:00 ps aux
pause
```

PID 1 is `/pause`, the target container's process, visible from a
separate container because `--target` shared the process namespace. And
the two lists really are separate:

```
debugger-d77f6      # .spec.ephemeralContainers[*].name
app                 # .spec.containers[*].name
```

### `crictl`: the node's CRI-level view, independent of the API server

**Why**: everything so far, even `kubectl get pod`, goes through the
apiserver, which gets its information about Pods from each node's
kubelet. If either of them is in trouble, `kubectl` can't tell you
what's running, although the container runtime on the node keeps
running the containers.

`crictl` talks directly to the container runtime on the node
(containerd, in every profile in this repo), without the apiserver or
the kubelet. It's already installed in each kind node container, so you
reach it with `docker exec <node>`, like anything else on a node
(chapter 1).

**Example**: list the containers running on one node, without
`kubectl`:

```
docker exec k8s-lab-default-worker crictl ps
```

**Expected output**: one line per container, with its Pod and
namespace. These are the same Pods that `kubectl get pods -A
--field-selector spec.nodeName=k8s-lab-default-worker` would list, found
a completely different way:

```
CONTAINER      IMAGE           CREATED         STATE     NAME             ATTEMPT   POD ID         POD                                NAMESPACE
27d79e2ce44c3  b116e15507444   2 minutes ago   Running   writer           0         ec2764618405b  scheduling-demo-quota-storage-pod scheduling-demo-governance
9cae86819c645  d7b01abacd67f   11 minutes ago  Running   metrics-server   0         96c5112863a47  metrics-server-5b58578978-rxddx   kube-system
c80041e4fe698  e44e5463fce88   12 minutes ago  Running   kindnet-cni      0         1a2e23576f423  kindnet-6wnfv                     kube-system
```

`crictl pods` lists Pods (sandboxes) instead of containers. Either way,
this is the runtime's own record of what's running on the node, and it
stays accurate whatever the apiserver or the kubelet are doing.

### `journalctl -u kubelet`: the kubelet's own logs, on the node

**Why**: `kubectl logs` shows a container's output. It says nothing
about the kubelet itself, the program on each node that starts the
containers. On this repo's `kindest/node` image, the kubelet runs as a
systemd service, so its logs are in the systemd journal. You read them
with `journalctl`, again through `docker exec <node>`.

**Example**:

```
docker exec k8s-lab-default-worker journalctl -u kubelet --no-pager -n 15
```

**Expected output**: the kubelet's recent log lines, here about mounting
volumes and how long a Pod took to start:

```
Sep 03 01:01:41 k8s-lab-default-worker kubelet[315]: I0903 01:01:41.025050     315 reconciler_common.go:251] "operationExecutor.VerifyControllerAttachedVolume started for volume ..." pod="scheduling-demo-governance/scheduling-demo-quota-storage-pod"
Sep 03 01:01:49 k8s-lab-default-worker kubelet[315]: I0903 01:01:49.687449     315 pod_startup_latency_tracker.go:148] "Observed pod startup duration" pod="scheduling-demo-governance/scheduling-demo-quota-storage-pod" podStartSLOduration=13.677716157999999 podStartE2EDuration="20.687419379s"
```

This is one level below the Events in `kubectl describe` (later in this
chapter). Events are what the kubelet chose to report to the apiserver
about a Pod. Its journal records everything it did, including details no
Event shows. Look there when a Pod behaves differently from what its
Events say, or when the problem is with the kubelet itself.

### metrics-server: resource metrics, not logs or events

**Why**: `kubectl top` shows how much CPU and memory nodes and Pods are
using right now. It gets the numbers from **metrics-server**, a separate
program registered as an aggregated API (`v1beta1.metrics.k8s.io`,
chapter 11), which regularly collects resource metrics from each node's
kubelet. These are *actual* usage figures, unlike the requests and
limits from chapter 7, which are what a Pod asked for.

This repo's `manifests/metrics/metrics-server.yaml` pins **v0.9.0**, with
one change from upstream: `--kubelet-insecure-tls`. kind's kubelets use
self-signed serving certificates that metrics-server wouldn't otherwise
accept. That flag is a workaround for kind only; don't copy it to a real
cluster (see DESIGN.md's "metrics-server and `--kubelet-insecure-tls`"
section).

**Example**:

```
kubectl get deploy metrics-server -n kube-system -o jsonpath='{.spec.template.spec.containers[0].image}'
kubectl top nodes
kubectl top pods -A
```

**Expected output**: the image version, then current numbers. Once the
API is registered, they're available straight away:

```
registry.k8s.io/metrics-server/metrics-server:v0.9.0

NAME                            CPU(cores)   CPU(%)   MEMORY(bytes)   MEMORY(%)
k8s-lab-default-control-plane   198m         2%       728Mi           4%
k8s-lab-default-worker          32m          0%       179Mi           1%
k8s-lab-default-worker2         58m          0%       206Mi           1%
```

If `kubectl top` says `error: Metrics API not available`, check
`kubectl get apiservice v1beta1.metrics.k8s.io` first. `AVAILABLE: False`
with the reason `MissingEndpoints` means the metrics-server Pod isn't
running (or is crash-looping): a problem with the Pod, not with the
metrics API. That happened while this chapter was being written:
metrics-server was stuck in `ImagePullBackOff` because of a DNS problem
on the host (the same cause as `docs/findings.md`'s 2026-08-24 entry).
As soon as the Pod pulled its image and started, the API became
available and `kubectl top` worked.

### Common failure-mode diagnosis

**Why**: a few habits cover most troubleshooting:

- Read the Events section of `kubectl describe` first. It lists, in
  order, what the scheduler and the kubelet did to get the Pod where it
  is.
- Know that `kubectl describe` shows different things depending on how
  you call it (see the end of this section).
- Don't take "deprecated" or "planned for removal" as proof that
  something is gone. Check on a live cluster.

**Example**: a container that exits straight away, and a deprecation
claim to check:

```
kubectl run observability-demo-crashloop-pod --image=busybox:1.36 --restart=Never -- sh -c "echo 'about to fail'; exit 1"
kubectl get pod observability-demo-crashloop-pod
kubectl describe pod observability-demo-crashloop-pod | grep -A5 Events:
kubectl logs observability-demo-crashloop-pod
kubectl get pod observability-demo-crashloop-pod -o jsonpath='{.status.containerStatuses[0].lastState.terminated.exitCode}'

kubectl get node <any-node> -o jsonpath='{.metadata.labels}' | tr ',' '\n' | grep beta.kubernetes.io
```

**Expected output**: the Events section shows what happened, in order:
scheduled, image pulled, started, then `BackOff` as the container kept
exiting. `kubectl logs` and the exit code show why:

```
NAME                                READY   STATUS   RESTARTS      AGE
observability-demo-crashloop-pod   0/1     Error    2 (17s ago)   20s

Events:
  Type     Reason     Age               From               Message
  ----     ------     ----              ----               -------
  Normal   Scheduled  20s               default-scheduler  Successfully assigned default/observability-demo-crashloop-pod to k8s-lab-default-worker2
  Normal   Pulled     2s (x3 over 19s)  kubelet            Container image "busybox:1.36" already present on machine and can be accessed by the pod
  Normal   Created    2s (x3 over 19s)  kubelet            Container created
  Normal   Started    2s (x3 over 18s)  kubelet            Container started
  Warning  BackOff    1s (x2 over 16s)  kubelet            Back-off restarting failed container app in pod observability-demo-crashloop-pod_default(...)

about to fail
1
```

Now the deprecation check. The `beta.kubernetes.io/arch` and
`beta.kubernetes.io/os` node labels were marked for removal back in
**1.18**, and some material says or implies they're gone. On this
cluster, running **v1.36.1**:

```
beta.kubernetes.io/arch:amd64
beta.kubernetes.io/os:linux
```

They're still there, 18 minor versions later. "Deprecated" is an
announced plan, not a record of what happened. To know whether a
removal actually happened, check a live cluster.

One more surprise. `kubectl describe` with an exact Pod name and
`kubectl describe` with a `-l` selector that matches one Pod look the
same. But when a selector matches *more* than one Pod, the Events
sections disappear from the output completely. They aren't merged or
shortened; they're just not there:

```
kubectl run observability-demo-selector-a --image=busybox:1.36 --restart=Never --labels="app=observability-demo-selector" -- sh -c "sleep 3600"
kubectl run observability-demo-selector-b --image=busybox:1.36 --restart=Never --labels="app=observability-demo-selector" -- sh -c "sleep 3600"

kubectl describe pod observability-demo-selector-a | grep -A5 "^Events:"
kubectl describe pod -l app=observability-demo-selector | grep -c "^Events:"
```

**Expected output**: `describe` by name shows a normal Events section.
`describe` by selector, for the same two Pods, contains no `Events:`
header at all:

```
Events:
  Type    Reason     Age   From               Message
  ----    ------     ----  ----               -------
  Normal  Scheduled  6s    default-scheduler  Successfully assigned default/observability-demo-selector-a to k8s-lab-default-worker2
  Normal  Pulling    4s    kubelet            spec.containers{observability-demo-selector-a}: Pulling image "busybox:1.36"
```

```
0
```

Both Pods do have events, so this isn't a case of nothing having
happened yet. Only `describe` with a selector matching several Pods
drops them. When you need a Pod's Events, describe it by name.
