# 6. Specialized workloads: StatefulSet, Job, and CronJob

Chapter 3 covered the Pod/ReplicaSet/Deployment line, where every
replica is interchangeable - any one of them can be killed and
replaced without anyone needing to track which, and none of them has
an identity beyond a random name suffix. This chapter covers three
workload shapes that are deliberate exceptions to that model. First,
StatefulSet, for workloads that need stable per-replica identity and
storage instead of interchangeability - now that chapter 4's
PersistentVolumeClaims and chapter 5's Service model are both in
place, the two mechanisms StatefulSet actually builds on. Then Job and
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
StatefulSet, Job, CronJob - still depends on the scheduler having
actually picked a node for each Pod it creates. Chapter 7 covers how
that placement decision gets made, and how to constrain it.
