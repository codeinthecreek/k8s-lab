# 10. Observability and troubleshooting

Chapter 9's denials - a forbidden RBAC verb, a rejected `restricted`
Pod, a dropped NetworkPolicy connection - all looked the same from the
outside: no crash, no bad config, just a request that never got where
it was going. This chapter covers the general version of that problem:
how to look inside a running cluster and diagnose what's wrong, using
vocabulary chapters 1-9 have already built up - a `CrashLoopBackOff`
means nothing without chapter 3's restart semantics; a blank `kubectl
logs` means nothing without knowing what the runtime actually captures.

### Logs: `kubectl logs` only ever shows stdout/stderr

**Why**: `kubectl logs` doesn't read a container's filesystem - it reads
whatever the container runtime captured from the container's **stdout
and stderr streams**, full stop. A process that writes only to its own
internal log file, never to stdout, produces nothing for `kubectl logs`
to show, no matter how much it's actually logging. On disk, the chain is
`/var/log/containers/<pod>_<namespace>_<container>-<containerID>.log`
(a symlink) pointing at
`/var/log/pods/<namespace>_<pod>_<uid>/<container>/0.log` - the exact
same stdout/stderr capture `kubectl logs` reads, just from the node's
filesystem directly.

**Example**: a container that only writes to an internal file, never
stdout:

```
kubectl run observability-demo-silent-pod --image=busybox:1.36 --restart=Never -- sh -c "while true; do echo \"internal event \$(date)\" >> /tmp/app.log; sleep 5; done"
kubectl logs observability-demo-silent-pod
kubectl exec observability-demo-silent-pod -- cat /tmp/app.log
```

**Expected output**: `kubectl logs` genuinely empty - not an error, just
nothing, because nothing was ever written to stdout - while the file
inside the container has real content the entire time:

```
$ kubectl logs observability-demo-silent-pod
(no output)

$ kubectl exec observability-demo-silent-pod -- cat /tmp/app.log
internal event Fri Aug 28 06:27:02 UTC 2026
internal event Fri Aug 28 06:27:07 UTC 2026
internal event Fri Aug 28 06:27:12 UTC 2026
```

And the node-side file `kubectl logs` and `/var/log/containers/*.log`
both ultimately read from is confirmed genuinely empty too - not a
`kubectl`-specific gap, the runtime itself never captured anything:

```
$ docker exec <node-container> readlink /var/log/containers/observability-demo-silent-pod_default_app-<id>.log
/var/log/pods/default_observability-demo-silent-pod_<uid>/app/0.log

$ docker exec <node-container> wc -l /var/log/pods/default_observability-demo-silent-pod_<uid>/app/0.log
0 /var/log/pods/default_observability-demo-silent-pod_<uid>/app/0.log
```

### `kubectl debug` and ephemeral containers

**Why**: plenty of real-world images (**distroless** - an image built
from just an application binary and its runtime dependencies, with no
shell, package manager, or OS userland at all - plus `pause`-style,
minimal scratch-based builds) ship with no debugging tools at all - by
design, for a smaller attack surface. `kubectl exec ... -- sh` simply
fails against them. An **ephemeral container** solves this: a
temporary, purpose-built debug container injected into an *already-
running* Pod's `spec.ephemeralContainers[]` - a genuinely separate list
from `spec.containers[]`, not editable via `kubectl edit` (it's its own
subresource). `kubectl debug -it <pod> --image=<img> --target=<container>
-- sh` is the practical entry point, and `--target` matters specifically:
it shares the *target* container's process namespace with the debug
container, so tools that don't exist in the minimal image become
available without modifying or restarting anything.

**Example**: `registry.k8s.io/pause` ships no shell whatsoever:

```
kubectl run observability-demo-shellless-pod --image=registry.k8s.io/pause:3.10 --restart=Never
kubectl exec observability-demo-shellless-pod -- sh -c "echo hi"
kubectl debug -it observability-demo-shellless-pod --image=busybox:1.36 --target=app -- sh -c "ps aux; cat /proc/1/comm"
kubectl get pod observability-demo-shellless-pod -o jsonpath='{.spec.ephemeralContainers[*].name}'
kubectl get pod observability-demo-shellless-pod -o jsonpath='{.spec.containers[*].name}'
```

**Expected output**: `exec` fails outright - there's no `sh` to run.
`kubectl debug` attaches a busybox debug container that can see the
*target's* real process (PID 1, `/pause`) despite having none of its own
processes to speak of:

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

`PID 1` is `/pause` - the target container's own process, visible from
inside a completely separate debug container because `--target` shared
the process namespace between them. And the two fields really are
distinct:

```
debugger-d77f6      # .spec.ephemeralContainers[*].name
app                 # .spec.containers[*].name
```

### `crictl`: the node's CRI-level view, independent of the API server

**Why**: everything so far - `kubectl logs`, `kubectl debug`, even
`kubectl get pod` - is mediated by the apiserver and, transitively, by
the kubelet reporting into it. That chain is exactly what's unavailable
if either one is unhealthy: a wedged kubelet or an unreachable apiserver
still leaves the container runtime itself running real workloads on the
node, with no `kubectl` command able to see them. `crictl` talks
directly to the CRI socket on the node - containerd here, same as every
profile in this repo - bypassing the apiserver and kubelet entirely.
It's not a `kubectl` plugin or anything installed cluster-wide; it's a
binary already present inside each kind node's container, reached the
same way chapter 1's node-as-container model reaches anything else on a
node: `docker exec <node>`.

**Example**: list every container the CRI knows about, on one node,
with no `kubectl` involved at all:

```
docker exec k8s-lab-default-worker crictl ps
```

**Expected output**: real containers, keyed by CRI container ID and
Pod, for every workload the runtime is actually running on that node -
the same Pods `kubectl get pods -A --field-selector spec.nodeName=k8s-lab-default-worker`
would show, arrived at through a completely different path:

```
CONTAINER      IMAGE           CREATED         STATE     NAME             ATTEMPT   POD ID         POD                                NAMESPACE
27d79e2ce44c3  b116e15507444   2 minutes ago   Running   writer           0         ec2764618405b  scheduling-demo-quota-storage-pod scheduling-demo-governance
9cae86819c645  d7b01abacd67f   11 minutes ago  Running   metrics-server   0         96c5112863a47  metrics-server-5b58578978-rxddx   kube-system
c80041e4fe698  e44e5463fce88   12 minutes ago  Running   kindnet-cni      0         1a2e23576f423  kindnet-6wnfv                     kube-system
```

`crictl pods` shows the same information one level up, at Pod-sandbox
granularity rather than per-container - useful when the question is
"what Pods does this node's runtime think are running" rather than "what
containers." Either way, this is the runtime's own bookkeeping, current
and accurate on this node regardless of what the apiserver or kubelet on
that node are doing right now.

### `journalctl -u kubelet`: the kubelet's own logs, on the node

**Why**: `kubectl logs` (this chapter's first section) only ever shows a
*container's* stdout/stderr - it has nothing to say about the kubelet
itself, the process on each node responsible for actually starting
those containers in the first place. On a systemd-based node image
(this repo's `kindest/node` build included), the kubelet runs as a
systemd unit and its logs go to the journal, reached with the same
`docker exec <node>` pattern already used for `crictl` above and for
inspecting `containerd`'s config in `docs/findings.md`.

**Example**:

```
docker exec k8s-lab-default-worker journalctl -u kubelet --no-pager -n 15
```

**Expected output**: real, current kubelet log lines - volume
mount/unmount bookkeeping, pod startup latency tracking, and anything
the kubelet itself is doing on that node right now, independent of
whether any particular container's own logs say anything at all:

```
Sep 03 01:01:41 k8s-lab-default-worker kubelet[315]: I0903 01:01:41.025050     315 reconciler_common.go:251] "operationExecutor.VerifyControllerAttachedVolume started for volume ..." pod="scheduling-demo-governance/scheduling-demo-quota-storage-pod"
Sep 03 01:01:49 k8s-lab-default-worker kubelet[315]: I0903 01:01:49.687449     315 pod_startup_latency_tracker.go:148] "Observed pod startup duration" pod="scheduling-demo-governance/scheduling-demo-quota-storage-pod" podStartSLOduration=13.677716157999999 podStartE2EDuration="20.687419379s"
```

This is the layer below `kubectl describe`'s Events section (later in
this chapter): Events are what the kubelet chose to report back to the
apiserver about a Pod; the kubelet's own journal is everything it
actually did, including internal bookkeeping no Event ever surfaces.
Reach for it when a Pod's behavior doesn't match what its Events say, or
when the question is about the node's kubelet itself rather than any
one Pod on it.

### metrics-server: resource metrics, not logs or events

**Why**: `kubectl top` depends on metrics-server, a separate aggregated
API (`v1beta1.metrics.k8s.io`) that scrapes each kubelet's `/stats`
endpoint on an interval and exposes current CPU/memory usage - distinct
from both logs (this chapter's first section) and from the
requests/limits chapter 7 covered (metrics-server reports *actual*
usage; requests/limits are declared intent, checked independently).
This repo's `manifests/metrics/metrics-server.yaml` (currently pinned at
**v0.9.0**) carries one deliberate deviation from upstream:
`--kubelet-insecure-tls`, because kind's kubelet serving certificates
are self-signed without a SAN metrics-server will accept otherwise - a
kind-specific workaround, not something to carry into a real cluster's
config (see DESIGN.md's "metrics-server and `--kubelet-insecure-tls`"
section).

**Example**:

```
kubectl get deploy metrics-server -n kube-system -o jsonpath='{.spec.template.spec.containers[0].image}'
kubectl top nodes
kubectl top pods -A
```

**Expected output**: a real version string, and real numbers back
immediately - no "metrics not yet available" delay once the apiservice
is actually registered:

```
registry.k8s.io/metrics-server/metrics-server:v0.9.0

NAME                            CPU(cores)   CPU(%)   MEMORY(bytes)   MEMORY(%)
k8s-lab-default-control-plane   198m         2%       728Mi           4%
k8s-lab-default-worker          32m          0%       179Mi           1%
k8s-lab-default-worker2         58m          0%       206Mi           1%
```

If `kubectl top` instead returns `error: Metrics API not available`,
check `kubectl get apiservice v1beta1.metrics.k8s.io` before assuming
metrics-server itself is broken - `AVAILABLE: False` with reason
`MissingEndpoints` means the metrics-server Pod isn't actually up yet
(or crash-looping), which is a Pod-health problem, not a metrics-API
problem. Hit exactly this while writing this chapter: metrics-server sat
in `ImagePullBackOff` from an unrelated host DNS resolver flake (see
`docs/findings.md`'s 2026-08-24 entry) - once the underlying Pod
actually pulled its image and started, the apiservice registered and
`kubectl top` worked immediately.

### Common failure-mode diagnosis

**Why**: a few habits cover most real troubleshooting: read `kubectl
describe`'s Events section before anything else (it's populated by the
exact controllers/kubelet actions that got a Pod to its current state,
in order); know that `describe`'s output shape changes depending on how
you invoke it, not just what it's describing; and don't trust a
"deprecated" or "planned for removal" claim as evidence something was
actually removed on schedule - verify against the live cluster, the
same principle this entire tutorial has followed throughout.

**Example**: a container that exits immediately, and a claim worth
checking rather than assuming:

```
kubectl run observability-demo-crashloop-pod --image=busybox:1.36 --restart=Never -- sh -c "echo 'about to fail'; exit 1"
kubectl get pod observability-demo-crashloop-pod
kubectl describe pod observability-demo-crashloop-pod | grep -A5 Events:
kubectl logs observability-demo-crashloop-pod
kubectl get pod observability-demo-crashloop-pod -o jsonpath='{.status.containerStatuses[0].lastState.terminated.exitCode}'

kubectl get node <any-node> -o jsonpath='{.metadata.labels}' | tr ',' '\n' | grep beta.kubernetes.io
```

**Expected output**: the Events section shows exactly what happened, in
order - scheduled, pulled, started, then `BackOff` once it kept exiting
- and `kubectl logs` plus the real exit code confirm why, no guessing
required:

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

And the "deprecated" check: `beta.kubernetes.io/arch` and
`beta.kubernetes.io/os` node labels were proposed for removal back in
**1.18**, and current material sometimes states or implies they're gone.
Live on this cluster, right now, on **v1.36.1**:

```
beta.kubernetes.io/arch:amd64
beta.kubernetes.io/os:linux
```

Still there, eight years of Kubernetes minor versions after the
deprecation notice. "Deprecated" is a schedule someone announced, not a
guarantee of what actually happened - the only way to know which is
true for a given claim is to check a live cluster, exactly as this
tutorial has done for every chapter before this one.

One more habit worth checking rather than assuming: `kubectl describe`
against an exact Pod name and `kubectl describe` against a `-l` selector
that happens to match exactly one Pod look identical, which makes it
easy to assume selector-based `describe` always works the same way. It
doesn't - the moment a selector matches more than one Pod, the Events
section is silently dropped from the output entirely, not merged,
truncated, or labeled per-Pod:

```
kubectl run observability-demo-selector-a --image=busybox:1.36 --restart=Never --labels="app=observability-demo-selector" -- sh -c "sleep 3600"
kubectl run observability-demo-selector-b --image=busybox:1.36 --restart=Never --labels="app=observability-demo-selector" -- sh -c "sleep 3600"

kubectl describe pod observability-demo-selector-a | grep -A5 "^Events:"
kubectl describe pod -l app=observability-demo-selector | grep -c "^Events:"
```

**Expected output**: the exact-name `describe` shows a normal Events
section; the selector-based `describe`, run against the same two Pods,
contains zero occurrences of the `Events:` header at all - not an empty
section, the header itself is absent:

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

Both Pods have real events - this isn't a case of nothing having
happened yet. It's specifically the multi-Pod selector path through
`kubectl describe` that drops them. Reach for an exact Pod name, not a
label selector, whenever the Events section itself is what you actually
need to see.
