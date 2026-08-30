# 3. Pods and workloads

Chapter 2 covered the API model in the abstract, using a Namespace as
the simplest possible object. This chapter is the first to cover an
object type you'll actually run application code in: the Pod, and the
controllers built on top of it (ReplicaSet, Deployment, StatefulSet)
that make Pods self-healing and upgradeable rather than one-shot -
including StatefulSet's different reconciliation shape, for workloads
that need stable per-replica identity rather than interchangeable
replicas. It closes with a different class of workload entirely - Job
and CronJob - which exist to run to completion rather than stay up.

### The Pod as the atomic unit

**Why**: Kubernetes never schedules a container directly - it schedules
a Pod, and a Pod is one or more containers that are always placed
together on the same node, share a network namespace (one IP for the
whole Pod, containers inside it reach each other over `localhost`), and
can share volumes. A Pod is the smallest unit the scheduler reasons
about; there's no such thing as independently scheduling two containers
that need to co-locate - if they need to, they belong in one Pod.

**Example**: `tutorial/examples/workloads/pod.yaml` is a single-container
Pod - the common case, but not the only shape a Pod can take:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: workloads-demo-pod
  labels:
    app: workloads-demo
spec:
  containers:
  - name: nginx
    image: nginx:1.27
    ports:
    - containerPort: 80
```

```
kubectl apply -f tutorial/examples/workloads/pod.yaml
kubectl get pod workloads-demo-pod -o wide
```

**Expected output**: one running Pod with its own Pod IP, scheduled onto
whichever worker node had capacity:

```
pod/workloads-demo-pod created

NAME                 READY   STATUS    RESTARTS   AGE   IP            NODE
workloads-demo-pod   1/1     Running   0          40s   10.244.2.3    k8s-lab-default-worker2
```

### Why you almost never create a bare Pod directly

**Why**: a Pod object has no controller behind it, so there's a sharp
line between two kinds of "recovery" that look similar but aren't. The
**kubelet** on the Pod's node watches the containers *inside* that Pod
and restarts one that crashes, because that's within a single Pod's own
`restartPolicy` (default `Always`) - the Pod object itself never goes
away, so this works with no controller involved. But if the **Pod
object** itself is deleted - not a container inside it crashing, the
whole object gone from etcd - nothing recreates it, because there's
nothing watching "does a Pod named `workloads-demo-pod` currently exist"
except whatever created it in the first place, and here that was you,
once, manually. This is the entire reason ReplicaSet/Deployment exist:
they add the missing "a Pod matching this template should always exist"
controller on top.

**Example**: crash the container without touching the Pod object, then
delete the Pod object itself, and compare:

```
kubectl get pod workloads-demo-pod
kubectl exec workloads-demo-pod -- sh -c "kill 1"
# poll: kubectl get pod workloads-demo-pod
kubectl delete pod workloads-demo-pod
kubectl get pod workloads-demo-pod
```

**Expected output**: killing PID 1 inside the container (the nginx
process) increments `RESTARTS` on the *same* Pod - name and continuously
growing `AGE` unchanged, proving kubelet restarted the container in
place rather than anything being recreated:

```
NAME                 READY   STATUS    RESTARTS   AGE
workloads-demo-pod   1/1     Running   0           45s

$ kubectl exec workloads-demo-pod -- sh -c "kill 1"

NAME                 READY   STATUS         RESTARTS      AGE
workloads-demo-pod   1/1     Running        1 (9s ago)    54s
```

Deleting the Pod object itself is a different story - it stays gone:

```
$ kubectl delete pod workloads-demo-pod
pod "workloads-demo-pod" deleted from default namespace

$ kubectl get pod workloads-demo-pod
Error from server (NotFound): pods "workloads-demo-pod" not found
```

### ReplicaSet: maintaining a stable set of replicas

**Why**: a ReplicaSet's job is narrow - given a Pod template and a
desired replica count, make sure that many Pods matching its
`spec.selector` exist, continuously. The detail worth internalizing is
*how* it tracks "its" Pods: purely by label selector, not by any
ownership field on the Pods themselves. `spec.selector` is the
ReplicaSet's actual identity as far as reconciliation goes - which means
a ReplicaSet can be deleted while leaving its Pods alone, and a new
ReplicaSet with a matching selector will adopt whatever Pods it finds
rather than creating duplicates.

**Example**: `tutorial/examples/workloads/replicaset.yaml` runs 3
replicas behind `selector.matchLabels.app: workloads-demo-rs`. Delete it
with `--cascade=orphan` (detach without deleting the Pods), confirm the
Pods survive, then re-apply the same ReplicaSet and check whether it
creates new Pods or adopts the orphans:

```
kubectl apply -f tutorial/examples/workloads/replicaset.yaml
kubectl delete rs workloads-demo-rs --cascade=orphan
kubectl get pods -l app=workloads-demo-rs
kubectl apply -f tutorial/examples/workloads/replicaset.yaml
kubectl get pods -l app=workloads-demo-rs -o custom-columns=NAME:.metadata.name,AGE:.metadata.creationTimestamp
```

**Expected output**: the 3 Pods created by the first apply keep the
exact same names throughout - orphaned, still `Running`, and then
adopted, never recreated:

```
$ kubectl get pods -l app=workloads-demo-rs -o custom-columns=NAME:...,AGE:...
workloads-demo-rs-clsqq   2026-08-28T03:49:54Z
workloads-demo-rs-l8h7v   2026-08-28T03:49:54Z
workloads-demo-rs-zgzbd   2026-08-28T03:49:54Z

$ kubectl delete rs workloads-demo-rs --cascade=orphan
replicaset.apps "workloads-demo-rs" deleted from default namespace

$ kubectl get pods -l app=workloads-demo-rs
workloads-demo-rs-clsqq   1/1   Running   0   44s
workloads-demo-rs-l8h7v   1/1   Running   0   44s
workloads-demo-rs-zgzbd   1/1   Running   0   44s

$ kubectl apply -f tutorial/examples/workloads/replicaset.yaml
replicaset.apps/workloads-demo-rs created

$ kubectl get pods -l app=workloads-demo-rs -o custom-columns=NAME:...,AGE:...
workloads-demo-rs-clsqq   2026-08-28T03:49:54Z
workloads-demo-rs-l8h7v   2026-08-28T03:49:54Z
workloads-demo-rs-zgzbd   2026-08-28T03:49:54Z
```

Same three names, same creation timestamps, both before and after -
the new ReplicaSet object went straight to `3/3` ready within seconds
because it found and adopted existing Pods matching its selector rather
than creating anything. A ReplicaSet naming a Pod it didn't create isn't
a bug; it's the selector-based model working as designed.

### Deployment: managing ReplicaSets, rolling updates

**Why**: a ReplicaSet alone can't change its own Pod template without
either killing everything at once or requiring you to hand-manage a
second ReplicaSet during a transition. A Deployment adds exactly that
missing layer: it owns one or more ReplicaSets, and changing the
Deployment's Pod template (a new image, for instance) makes it create a
*new* ReplicaSet and gradually shift replica counts from the old one to
the new one - a rolling update - rather than mutating Pods in place.
This is why `kubectl rollout status/history/undo` are Deployment-level
commands: the rollout is a Deployment concept, ReplicaSets are just the
mechanism it uses underneath.

**Example**: `tutorial/examples/workloads/deployment.yaml` runs the same
3-replica nginx workload as a Deployment instead. Set a change-cause
annotation *before* triggering the update (it has to happen first, or it
won't be attached to the new revision), bump the image, and watch the
ReplicaSet churn:

```
kubectl apply -f tutorial/examples/workloads/deployment.yaml
kubectl annotate deployment workloads-demo-deploy kubernetes.io/change-cause="bump nginx to 1.28" --overwrite
kubectl set image deployment/workloads-demo-deploy nginx=nginx:1.28
kubectl rollout status deployment/workloads-demo-deploy
kubectl get rs -l app=workloads-demo-deploy
kubectl rollout history deployment/workloads-demo-deploy
```

**Expected output**: the rollout proceeds one Pod at a time (default
`RollingUpdate` strategy), and once complete there are two ReplicaSets -
the old one scaled to zero, kept around rather than deleted (that's what
makes `kubectl rollout undo` possible):

```
deployment.apps/workloads-demo-deploy created
deployment.apps/workloads-demo-deploy annotated
deployment.apps/workloads-demo-deploy image updated

Waiting for deployment spec update to be observed...
Waiting for deployment "workloads-demo-deploy" rollout to finish: 1 out of 3 new replicas have been updated...
Waiting for deployment "workloads-demo-deploy" rollout to finish: 2 out of 3 new replicas have been updated...
Waiting for deployment "workloads-demo-deploy" rollout to finish: 1 old replicas are pending termination...
deployment "workloads-demo-deploy" successfully rolled out

NAME                                DESIRED   CURRENT   READY   AGE
workloads-demo-deploy-5f48cd94b9   3         3         3       85s
workloads-demo-deploy-75bf95bd74   0         0         0       95s

REVISION  CHANGE-CAUSE
1         bump nginx to 1.28
2         bump nginx to 1.28
```

Two things worth noticing in that last block. First, both revisions show
the *same* change-cause text - because the annotate command ran while
revision 1 was still the Deployment's only/current ReplicaSet, the
annotation landed there too, not just on the revision created
afterward. Annotating "before the change" scopes the *timing* correctly
relative to triggering the rollout, but doesn't cleanly scope which
revision(s) end up carrying it - a real, mildly surprising interaction
worth expecting rather than being confused by. Second: `--record` isn't
used here because it's been removed entirely (fails with `unknown flag:
--record`) - `kubectl annotate ... kubernetes.io/change-cause=... `
beforehand is the current replacement.

The other easy assumption to check: does re-running the exact same
`set image` command create another revision?

```
kubectl set image deployment/workloads-demo-deploy nginx=nginx:1.28
kubectl rollout history deployment/workloads-demo-deploy
```

```
(no output - exit 0)

REVISION  CHANGE-CAUSE
1         bump nginx to 1.28
2         bump nginx to 1.28
```

No new revision, and no confirmation message either - `kubectl set
image` diffs the target value against what's already there and does
nothing at all if it matches, silently. If you're scripting a rollout
and expecting every invocation to produce a new revision, this is the
failure mode: rerunning with an unchanged target is a true no-op, not an
error you'd notice.

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

**Example**: `tutorial/examples/workloads/statefulset-headless-service.yaml`
(the governing headless Service) and
`tutorial/examples/workloads/statefulset.yaml` (2 replicas, each with
its own `data` PVC via `volumeClaimTemplates`):

```
kubectl apply -f tutorial/examples/workloads/statefulset-headless-service.yaml
kubectl apply -f tutorial/examples/workloads/statefulset.yaml
kubectl get pods -l app=workloads-demo-sts -o wide
kubectl get pvc -l app=workloads-demo-sts
kubectl run workloads-demo-dnscheck --image=busybox:1.36 --restart=Never -i --rm --command -- \
  nslookup workloads-demo-sts-0.workloads-demo-sts.default.svc.cluster.local
```

**Expected output**: predictable ordinal Pod names (not random suffixes
like a ReplicaSet's), created one at a time in order - `-1` doesn't even
start `ContainerCreating` until `-0` is `1/1 Running` - and one PVC per
ordinal:

```
$ kubectl get pods -l app=workloads-demo-sts -o wide
NAME                   READY   STATUS    RESTARTS   AGE    IP           NODE
workloads-demo-sts-0   1/1     Running   0          109s   10.244.1.5   k8s-lab-default-worker2
workloads-demo-sts-1   1/1     Running   0          55s    10.244.2.4   k8s-lab-default-worker

$ kubectl get pvc -l app=workloads-demo-sts
NAME                        STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS
data-workloads-demo-sts-0   Bound    pvc-9805175e-a63f-430f-b2bc-20d8a92f5fdf   100Mi      RWO            standard
data-workloads-demo-sts-1   Bound    pvc-473c729b-a436-4e4b-ba98-c6ee98ec90a6   100Mi      RWO            standard
```

The DNS check needed the fully-qualified name above, not the shorter
`workloads-demo-sts-0.workloads-demo-sts` the search-domain mechanism
(chapter 5) should in principle resolve on its own - worth checking
directly rather than assuming, since it didn't work as expected:

```
$ kubectl run workloads-demo-dnscheck --image=busybox:1.36 --restart=Never -i --rm --command -- \
  nslookup workloads-demo-sts-0.workloads-demo-sts
Server:		10.96.0.10
Address:	10.96.0.10:53

** server can't find workloads-demo-sts-0.workloads-demo-sts: NXDOMAIN
```

The Pod's own `/etc/resolv.conf` does list the expected search domains
(`search default.svc.cluster.local svc.cluster.local cluster.local`,
`options ndots:5`, meaning a name with fewer than 5 dots should get
those suffixes tried automatically) - so the search list itself is
correctly configured. The failure is specific to BusyBox's `nslookup`
applet, which issues a single literal query rather than walking
`resolv.conf`'s search list the way a normal application's resolver
call (`getaddrinfo`, which most real clients use) would. Supplying the
FQDN directly - `workloads-demo-sts-0.workloads-demo-sts.default.svc.cluster.local`
- resolves correctly, straight to that specific Pod's IP, not a
load-balanced VIP:

```
$ kubectl run workloads-demo-dnscheck --image=busybox:1.36 --restart=Never -i --rm --command -- \
  nslookup workloads-demo-sts-0.workloads-demo-sts.default.svc.cluster.local
Name:	workloads-demo-sts-0.workloads-demo-sts.default.svc.cluster.local
Address: 10.244.1.5
```

`10.244.1.5` is exactly `workloads-demo-sts-0`'s own Pod IP from the
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
kubectl exec workloads-demo-sts-1 -- sh -c "echo 'from ordinal 1' > /usr/share/nginx/html/marker.txt"
kubectl scale statefulset workloads-demo-sts --replicas=1
kubectl get pvc -l app=workloads-demo-sts
kubectl scale statefulset workloads-demo-sts --replicas=2
kubectl exec workloads-demo-sts-1 -- cat /usr/share/nginx/html/marker.txt
```

**Expected output**: scaling down terminates only the highest ordinal
(`-1`), leaving `-0` completely untouched, and its PVC stays `Bound`
rather than being deleted:

```
$ kubectl exec workloads-demo-sts-1 -- sh -c "echo 'from ordinal 1' > /usr/share/nginx/html/marker.txt"

$ kubectl scale statefulset workloads-demo-sts --replicas=1
statefulset.apps/workloads-demo-sts scaled

$ kubectl get pods -l app=workloads-demo-sts
NAME                   READY   STATUS    RESTARTS   AGE
workloads-demo-sts-0   1/1     Running   0          2m32s

$ kubectl get pvc -l app=workloads-demo-sts
NAME                        STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS
data-workloads-demo-sts-0   Bound    pvc-9805175e-a63f-430f-b2bc-20d8a92f5fdf   100Mi      RWO            standard
data-workloads-demo-sts-1   Bound    pvc-473c729b-a436-4e4b-ba98-c6ee98ec90a6   100Mi      RWO            standard
```

Scaling back to 2 recreates `workloads-demo-sts-1` and reattaches that
same, still-`Bound` PVC - the marker file is still there, byte for
byte, because the recreated Pod got the exact same volume back, not a
fresh one:

```
$ kubectl scale statefulset workloads-demo-sts --replicas=2
statefulset.apps/workloads-demo-sts scaled

$ kubectl exec workloads-demo-sts-1 -- cat /usr/share/nginx/html/marker.txt
from ordinal 1
```

Deleting the StatefulSet itself doesn't clean up its PVCs either - they
have to be deleted explicitly:

```
kubectl delete statefulset workloads-demo-sts
kubectl delete pvc -l app=workloads-demo-sts
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

**Example**: `tutorial/examples/workloads/job.yaml` runs a single
completion:

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: workloads-demo-job
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
kubectl apply -f tutorial/examples/workloads/job.yaml
kubectl get job workloads-demo-job
kubectl get job workloads-demo-job -o jsonpath='{range .status.conditions[*]}{.type}{" "}{.status}{" "}{.lastTransitionTime}{"\n"}{end}'
kubectl get pods -l job-name=workloads-demo-job -o jsonpath='{.items[0].metadata.labels}'
```

**Expected output**: the Job reaches `1/1` completions on its own, no
Deployment-style restart loop involved:

```
job.batch/workloads-demo-job created

NAME                 STATUS     COMPLETIONS   DURATION   AGE
workloads-demo-job   Complete   1/1           10s        11s

SuccessCriteriaMet True 2026-08-28T04:19:17Z
Complete True 2026-08-28T04:19:17Z

{"batch.kubernetes.io/controller-uid":"3714e799-...","batch.kubernetes.io/job-name":"workloads-demo-job","controller-uid":"3714e799-...","job-name":"workloads-demo-job"}
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

`tutorial/examples/workloads/cronjob.yaml` wraps the same idea in a
schedule:

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: workloads-demo-cronjob
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
kubectl apply -f tutorial/examples/workloads/cronjob.yaml
kubectl get cronjob workloads-demo-cronjob
kubectl get jobs | grep workloads-demo-cronjob
```

**Expected output**: applied and then left running against this
cluster for 29 minutes (schedule is every minute, so ~29 scheduled
runs) before being checked again - deliberately longer than a quick
sanity check, to make sure history rotation isn't just "the first couple
of runs happen to look fine":

```
cronjob.batch/workloads-demo-cronjob created
```

```
NAME                      SCHEDULE    SUSPEND   ACTIVE   LAST SCHEDULE   AGE
workloads-demo-cronjob    * * * * *   False     0        29s             29m

workloads-demo-cronjob-29798179   Complete   1/1   5s   29s
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
$ kubectl get cronjob workloads-demo-cronjob -o jsonpath='{.status.lastScheduleTime}'
2026-08-28T04:19:00Z

$ date -u -d "2026-08-28T04:19:00Z" +%s
1787890740

$ echo $(( 1787890740 / 60 ))
29798179
```

`workloads-demo-cronjob-29798179` - the numeric suffix is exactly
`lastScheduleTime` as a Unix timestamp divided by 60, confirming the
`<cronjob-name>-<unix-timestamp/60>` naming pattern directly rather than
taking it on faith.
