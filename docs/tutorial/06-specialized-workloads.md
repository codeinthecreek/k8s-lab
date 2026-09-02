# 6. Specialized workloads: StatefulSet, DaemonSet, Job, and CronJob

Chapter 3 covered the Pod/ReplicaSet/Deployment line, where every
replica is interchangeable - any one of them can be killed and
replaced without anyone needing to track which, and none of them has
an identity beyond a random name suffix, and where the scheduler picks
freely among whichever nodes have room rather than any Pod caring which
node it lands on. This chapter covers four workload shapes that are
deliberate exceptions to that model. First, StatefulSet, for workloads
that need stable per-replica identity and storage instead of
interchangeability - now that chapter 4's PersistentVolumeClaims and
chapter 5's Service model are both in place, the two mechanisms
StatefulSet actually builds on. Then DaemonSet, for workloads that need
exactly one Pod per node rather than some replica count chosen
independently of node count - chapter 5 already ran into one of these
(kindnet) without covering DaemonSet as a general concept. Then Job and
CronJob, for work that's meant to run to completion and stop rather
than stay up - a different reconciliation target ("N successful
completions" instead of "N running replicas"), not a new architectural
idea.

### StatefulSet: stable identity and per-replica storage

**Why**: a Deployment's Pods are interchangeable - any replica can be
killed, replaced, or scaled away and nothing else needs to know which
one, because none of them has an identity beyond a random name suffix.
Some workloads need the opposite: predictable, stable Pod names that
persist across restarts, Pods created and terminated in a defined
order rather than all at once, and each replica getting its *own*
storage rather than sharing (or having none). StatefulSet is that
different reconciliation shape - a `spec.serviceName` naming a headless
Service (`clusterIP: None`) gives each Pod a stable per-Pod DNS name,
and `volumeClaimTemplates` gives each ordinal its own PVC, provisioned
the same dynamic way chapter 4 covered, just once per replica instead
of once total.

**Example**: `tutorial/examples/specialized-workloads/statefulset-headless-service.yaml`
(the governing headless Service) and
`tutorial/examples/specialized-workloads/statefulset.yaml` (2 replicas, each with
its own `data` PVC via `volumeClaimTemplates`):

```
kubectl apply -f tutorial/examples/specialized-workloads/statefulset-headless-service.yaml
kubectl apply -f tutorial/examples/specialized-workloads/statefulset.yaml
kubectl get pods -l app=specialized-workloads-demo-sts -o wide
kubectl get pvc -l app=specialized-workloads-demo-sts
kubectl run specialized-workloads-demo-dnscheck --image=busybox:1.36 --restart=Never -i --rm --command -- \
  nslookup specialized-workloads-demo-sts-0.specialized-workloads-demo-sts.default.svc.cluster.local
```

**Expected output**: predictable ordinal Pod names (not random suffixes
like a ReplicaSet's), created one at a time in order - `-1` doesn't even
start `ContainerCreating` until `-0` is `1/1 Running` - and one PVC per
ordinal:

```
$ kubectl get pods -l app=specialized-workloads-demo-sts -o wide
NAME                   READY   STATUS    RESTARTS   AGE    IP           NODE
specialized-workloads-demo-sts-0   1/1     Running   0          109s   10.244.1.5   k8s-lab-default-worker2
specialized-workloads-demo-sts-1   1/1     Running   0          55s    10.244.2.4   k8s-lab-default-worker

$ kubectl get pvc -l app=specialized-workloads-demo-sts
NAME                        STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS
data-specialized-workloads-demo-sts-0   Bound    pvc-9805175e-a63f-430f-b2bc-20d8a92f5fdf   100Mi      RWO            standard
data-specialized-workloads-demo-sts-1   Bound    pvc-473c729b-a436-4e4b-ba98-c6ee98ec90a6   100Mi      RWO            standard
```

The fully-qualified name resolves straight to that specific Pod's IP,
not a load-balanced VIP - the point that actually matters for "why
StatefulSet": each ordinal gets its own durable address, not a shared
one:

```
$ kubectl run specialized-workloads-demo-dnscheck --image=busybox:1.36 --restart=Never -i --rm --command -- \
  nslookup specialized-workloads-demo-sts-0.specialized-workloads-demo-sts.default.svc.cluster.local
Name:	specialized-workloads-demo-sts-0.specialized-workloads-demo-sts.default.svc.cluster.local
Address: 10.244.1.5
```

`10.244.1.5` is exactly `specialized-workloads-demo-sts-0`'s own Pod IP from the
`get pods -o wide` output above - confirming the headless Service's
per-Pod DNS records point at individual Pods, not a shared Service VIP
the way chapter 5's ClusterIP Services do.

### PersistentVolumeClaims outlive their StatefulSet Pods

**Why**: the whole point of per-replica storage is that a Pod's data
survives that specific Pod being replaced - so deleting or scaling down
a StatefulSet must not simply delete its PVCs along with the Pods, or
the storage would be exactly as ephemeral as `emptyDir` (chapter 4) and
the feature would be pointless. Scaling a StatefulSet down terminates
Pods in strict reverse-ordinal order (highest number first, the mirror
of the ordered creation above), but the freed PVC stays bound and
intact - scaling back up reattaches the *same* volume to the
recreated Pod of that ordinal, not a fresh empty one.

**Example**: write a marker file to the highest-ordinal Pod, scale
down to remove it, scale back up, and check whether the marker
survived:

```
kubectl exec specialized-workloads-demo-sts-1 -- sh -c "echo 'from ordinal 1' > /usr/share/nginx/html/marker.txt"
kubectl scale statefulset specialized-workloads-demo-sts --replicas=1
kubectl get pvc -l app=specialized-workloads-demo-sts
kubectl scale statefulset specialized-workloads-demo-sts --replicas=2
kubectl exec specialized-workloads-demo-sts-1 -- cat /usr/share/nginx/html/marker.txt
```

**Expected output**: scaling down terminates only the highest ordinal
(`-1`), leaving `-0` completely untouched, and its PVC stays `Bound`
rather than being deleted:

```
$ kubectl exec specialized-workloads-demo-sts-1 -- sh -c "echo 'from ordinal 1' > /usr/share/nginx/html/marker.txt"

$ kubectl scale statefulset specialized-workloads-demo-sts --replicas=1
statefulset.apps/specialized-workloads-demo-sts scaled

$ kubectl get pods -l app=specialized-workloads-demo-sts
NAME                   READY   STATUS    RESTARTS   AGE
specialized-workloads-demo-sts-0   1/1     Running   0          2m32s

$ kubectl get pvc -l app=specialized-workloads-demo-sts
NAME                        STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS
data-specialized-workloads-demo-sts-0   Bound    pvc-9805175e-a63f-430f-b2bc-20d8a92f5fdf   100Mi      RWO            standard
data-specialized-workloads-demo-sts-1   Bound    pvc-473c729b-a436-4e4b-ba98-c6ee98ec90a6   100Mi      RWO            standard
```

Scaling back to 2 recreates `specialized-workloads-demo-sts-1` and reattaches that
same, still-`Bound` PVC - the marker file is still there, byte for
byte, because the recreated Pod got the exact same volume back, not a
fresh one:

```
$ kubectl scale statefulset specialized-workloads-demo-sts --replicas=2
statefulset.apps/specialized-workloads-demo-sts scaled

$ kubectl exec specialized-workloads-demo-sts-1 -- cat /usr/share/nginx/html/marker.txt
from ordinal 1
```

Deleting the StatefulSet itself doesn't clean up its PVCs either - they
have to be deleted explicitly:

```
kubectl delete statefulset specialized-workloads-demo-sts
kubectl delete pvc -l app=specialized-workloads-demo-sts
```

Both behaviors are the same underlying design choice: a StatefulSet
controller only ever creates PVCs, never deletes them on its own, on
the assumption that the storage is worth more than the convenience of
automatic cleanup - the exact opposite default from a bare Pod's
`emptyDir` (chapter 4), which vanishes the moment the Pod does.

### DaemonSet: one Pod per node, not a replica count

**Why**: StatefulSet changes what "one replica" means; DaemonSet changes
how many there are, and why. Some workloads aren't about *N*
interchangeable copies at all - they're node-level daemons that need to
run exactly once on every node (or every node matching some criteria):
log collectors, CNI plugins (chapter 5's kindnet is one), monitoring
agents. A Deployment can't express that - `replicas: N` is a number you
choose, unrelated to how many nodes exist, and the scheduler is free to
stack several of those replicas on one node while leaving another idle.
DaemonSet has no `replicas` field at all: its desired Pod count is
derived from the cluster's node count, one Pod per matching node,
growing and shrinking automatically as nodes join or leave - nobody
edits that number by hand. Mechanically, the DaemonSet controller
creates one Pod per matching node and pins each to its specific node
with a generated `nodeAffinity` (`metadata.name In [that-node]`) rather
than leaving node choice to the scheduler's normal fit-scoring - but
that pinned Pod still goes through the scheduler like any other, so
ordinary scheduling constraints, including taints, still apply. That
last point matters concretely: chapter 1's control-plane taint excludes
ordinary Pods from the control-plane node, and a DaemonSet is no
exception unless its Pod template explicitly tolerates that taint -
which is exactly what lets kindnet and kube-proxy run there while an
untolerated DaemonSet would not.

**Example**: `tutorial/examples/specialized-workloads/daemonset.yaml` -
no `replicas` field, and no toleration yet:

```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: specialized-workloads-demo-ds
  labels:
    app: specialized-workloads-demo-ds
spec:
  selector:
    matchLabels:
      app: specialized-workloads-demo-ds
  template:
    metadata:
      labels:
        app: specialized-workloads-demo-ds
    spec:
      containers:
      - name: busybox
        image: busybox:1.36
        command: ["sh", "-c", "sleep 3600"]
```

```
kubectl apply -f tutorial/examples/specialized-workloads/daemonset.yaml
kubectl get daemonset specialized-workloads-demo-ds
kubectl get pods -l app=specialized-workloads-demo-ds -o wide
```

**Expected output**: `DESIRED` is `2`, not the cluster's full node count
of 3 - the control-plane node's taint excluded it automatically, without
any `nodeSelector` naming it, and the two Pods that did get created
landed one on each worker:

```
$ kubectl get daemonset specialized-workloads-demo-ds
NAME                            DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE   NODE SELECTOR   AGE
specialized-workloads-demo-ds   2         2         2       2            2           <none>          8s

$ kubectl get pods -l app=specialized-workloads-demo-ds -o wide
NAME                                  READY   STATUS    RESTARTS   AGE   NODE
specialized-workloads-demo-ds-72hm4   1/1     Running   0          8s    k8s-lab-default-worker2
specialized-workloads-demo-ds-ksmpj   1/1     Running   0          8s    k8s-lab-default-worker
```

Adding the same toleration kindnet and kube-proxy already carry gets the
third Pod onto the control-plane node too, and `DESIRED` updates itself
to match - nobody told it "3" directly, it recomputed from node count
plus toleration:

```
kubectl patch daemonset specialized-workloads-demo-ds --type=json \
  -p '[{"op":"add","path":"/spec/template/spec/tolerations","value":[{"key":"node-role.kubernetes.io/control-plane","operator":"Exists","effect":"NoSchedule"}]}]'
kubectl get daemonset specialized-workloads-demo-ds
kubectl get pods -l app=specialized-workloads-demo-ds -o wide
```

**Expected output**: `DESIRED` is now `3`, and a Pod is running on the
control-plane node - the same exception chapter 1 described for kindnet
and kube-proxy, now reproduced directly rather than just asserted
(patching the template also triggers a rolling replacement of the
existing Pods one node at a time, DaemonSet's default update strategy,
so a `kubectl get pods` run mid-rollout may briefly show a
`Terminating`/`ContainerCreating` pair before it settles):

```
$ kubectl get daemonset specialized-workloads-demo-ds
NAME                            DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE   NODE SELECTOR   AGE
specialized-workloads-demo-ds   3         3         3       3            3           <none>          113s

$ kubectl get pods -l app=specialized-workloads-demo-ds -o wide
NAME                                  READY   STATUS    RESTARTS   AGE   NODE
specialized-workloads-demo-ds-dm6m2   1/1     Running   0          47s   k8s-lab-default-worker2
specialized-workloads-demo-ds-rtm9p   1/1     Running   0          88s   k8s-lab-default-control-plane
specialized-workloads-demo-ds-t9vnt   1/1     Running   0          13s   k8s-lab-default-worker
```

### Workloads that run to completion: Job and CronJob

**Why**: not every workload should stay running. A batch computation, a
migration script, a one-off maintenance task - these are meant to exit
successfully and stop, and a Deployment (which restarts anything that
exits, expecting it to run forever) is the wrong tool for that shape.
Job exists specifically to run a Pod (or several) to completion and stop
- no restart loop, no expectation of staying up. CronJob is a thin layer
on top: it creates Job objects on a schedule rather than you creating
one manually each time. Neither introduces a new architectural idea
beyond "a controller that watches desired state and reconciles toward
it" - they're just reconciling toward "N successful completions" instead
of "N running replicas."

**Example**: `tutorial/examples/specialized-workloads/job.yaml` runs a single
completion:

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: specialized-workloads-demo-job
spec:
  backoffLimit: 2
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: hello
        image: busybox:1.36
        command: ["sh", "-c", "echo Hello from the Job; sleep 5"]
```

```
kubectl apply -f tutorial/examples/specialized-workloads/job.yaml
kubectl get job specialized-workloads-demo-job
kubectl get job specialized-workloads-demo-job -o jsonpath='{range .status.conditions[*]}{.type}{" "}{.status}{" "}{.lastTransitionTime}{"\n"}{end}'
kubectl get pods -l job-name=specialized-workloads-demo-job -o jsonpath='{.items[0].metadata.labels}'
```

**Expected output**: the Job reaches `1/1` completions on its own, no
Deployment-style restart loop involved:

```
job.batch/specialized-workloads-demo-job created

NAME                 STATUS     COMPLETIONS   DURATION   AGE
specialized-workloads-demo-job   Complete   1/1           10s        11s

SuccessCriteriaMet True 2026-08-28T04:19:17Z
Complete True 2026-08-28T04:19:17Z

{"batch.kubernetes.io/controller-uid":"3714e799-...","batch.kubernetes.io/job-name":"specialized-workloads-demo-job","controller-uid":"3714e799-...","job-name":"specialized-workloads-demo-job"}
```

Two things worth checking against, rather than assuming: the
`SuccessCriteriaMet` and `Complete` conditions both landed at the exact
same second here - for a Job this short-lived, there's no meaningfully
observable gap between "criteria met" and "terminal state," even though
the two are formally separate conditions (the gap that can exist between
them is bounded by `terminationGracePeriodSeconds`, default 30s, and
only shows up when a Pod actually takes time to terminate). And the
created Pod carries **both** `job-name` and the newer
`batch.kubernetes.io/job-name` label - the old unprefixed one stuck
around for backward-compatible selectors, it isn't gone.

`tutorial/examples/specialized-workloads/cronjob.yaml` wraps the same idea in a
schedule:

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: specialized-workloads-demo-cronjob
spec:
  schedule: "* * * * *"
  successfulJobsHistoryLimit: 1
  failedJobsHistoryLimit: 1
  jobTemplate:
    spec:
      template:
        spec:
          restartPolicy: OnFailure
          containers:
          - name: hello
            image: busybox:1.36
            command: ["sh", "-c", "date; echo Hello from the CronJob"]
```

```
kubectl apply -f tutorial/examples/specialized-workloads/cronjob.yaml
kubectl get cronjob specialized-workloads-demo-cronjob
kubectl get jobs | grep specialized-workloads-demo-cronjob
```

**Expected output**: applied and then left running against this
cluster for 29 minutes (schedule is every minute, so ~29 scheduled
runs) before being checked again - deliberately longer than a quick
sanity check, to make sure history rotation isn't just "the first couple
of runs happen to look fine":

```
cronjob.batch/specialized-workloads-demo-cronjob created
```

```
NAME                      SCHEDULE    SUSPEND   ACTIVE   LAST SCHEDULE   AGE
specialized-workloads-demo-cronjob    * * * * *   False     0        29s             29m

specialized-workloads-demo-cronjob-29798179   Complete   1/1   5s   29s
```

Only **one** completed Job exists, despite ~29 scheduled runs having
happened over that 29 minutes - `successfulJobsHistoryLimit: 1` isn't
just capping what's *displayed*, the CronJob controller is actively
deleting each older Job as a newer one completes. This is why a Job
that seems to have vanished, or a Job whose duration seems to have
implausibly jumped between two checks, is almost always a *different*
Job in a naming succession, not one Job behaving strangely - which is
directly checkable from the retained Job's name:

```
$ kubectl get cronjob specialized-workloads-demo-cronjob -o jsonpath='{.status.lastScheduleTime}'
2026-08-28T04:19:00Z

$ date -u -d "2026-08-28T04:19:00Z" +%s
1787890740

$ echo $(( 1787890740 / 60 ))
29798179
```

`specialized-workloads-demo-cronjob-29798179` - the numeric suffix is exactly
`lastScheduleTime` as a Unix timestamp divided by 60, confirming the
`<cronjob-name>-<unix-timestamp/60>` naming pattern directly rather than
taking it on faith.

Every workload covered so far - Pod, ReplicaSet, Deployment,
StatefulSet, DaemonSet, Job, CronJob - still depends on the scheduler
having actually picked a node for each Pod it creates, DaemonSet's
generated `nodeAffinity` included. Chapter 7 covers how that placement
decision gets made, and how to constrain it.
