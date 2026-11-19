# 6. Specialized workloads: StatefulSet, DaemonSet, Job, and CronJob

A Deployment (chapter 3) treats its replicas as interchangeable. Any
one of them can be deleted and replaced, they have random name
suffixes, and the scheduler puts them wherever there's room. That suits
many applications, but not all. This chapter covers four workload types
for the cases it doesn't suit:

- **StatefulSet**: each replica has a stable name and its own storage.
  It builds on PersistentVolumeClaims (chapter 4) and Services
  (chapter 5).
- **DaemonSet**: exactly one Pod on every node. kindnet, the network
  plugin from chapter 5, runs this way.
- **Job** and **CronJob**: work that runs until it's finished, then
  stops, once or on a schedule.

### StatefulSet: stable identity and per-replica storage

**Why**: some applications, such as databases, need each replica to
keep its identity: the same name after a restart, its own storage, and
a fixed order for starting and stopping. A **StatefulSet** provides
that:

- Pods are named `<statefulset>-0`, `<statefulset>-1` and so on, and
  are created in that order, one at a time.
- `spec.serviceName` names a **headless Service** (`clusterIP: None`),
  which gives each Pod its own DNS name.
- `volumeClaimTemplates` creates a separate PVC for each Pod, provisioned
  as in chapter 4.

**Example**: [`statefulset-headless-service.yaml`](examples/specialized-workloads/statefulset-headless-service.yaml)
is the headless Service, and
[`statefulset.yaml`](examples/specialized-workloads/statefulset.yaml) a
StatefulSet with 2 replicas, each with its own PVC called `data`:

```
kubectl apply -f tutorial/examples/specialized-workloads/statefulset-headless-service.yaml
kubectl apply -f tutorial/examples/specialized-workloads/statefulset.yaml
```

```
service/specialized-workloads-demo-sts created
statefulset.apps/specialized-workloads-demo-sts created
```

After 20 seconds or so, list the Pods and their PVCs:

```
kubectl get pods -l app=specialized-workloads-demo-sts -o wide
kubectl get pvc -l app=specialized-workloads-demo-sts
```

**Expected output**: Pods named `-0` and `-1`, not random suffixes.
`-1` is younger: it was only created once `-0` was running. Each has
its own PVC:

```
NAME                               READY   STATUS    RESTARTS   AGE   IP            NODE                      NOMINATED NODE   READINESS GATES
specialized-workloads-demo-sts-0   1/1     Running   0          20s   10.244.1.24   k8s-lab-default-worker2   <none>           <none>
specialized-workloads-demo-sts-1   1/1     Running   0          11s   10.244.2.46   k8s-lab-default-worker    <none>           <none>
NAME                                    STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS   VOLUMEATTRIBUTESCLASS   AGE
data-specialized-workloads-demo-sts-0   Bound    pvc-4a285c9f-6fa9-4b30-bb9a-56fbd8a154e4   100Mi      RWO            standard       <unset>                 20s
data-specialized-workloads-demo-sts-1   Bound    pvc-8f9ad37e-77d5-479c-ba65-f1a8b03c7cad   100Mi      RWO            standard       <unset>                 12s
```

Each Pod's DNS name resolves to that Pod's own IP address. A ClusterIP
Service's name resolves to one shared address that spreads requests
over all its Pods (chapter 5); here, each replica can be reached
individually, at a name that doesn't change.

To look the name up, start a busybox Pod that just sleeps, as a client
inside the cluster:

```
kubectl run specialized-workloads-demo-client --image=busybox:1.36 --command -- sleep 3600
```

When it's running, run `nslookup` in it:

```
kubectl exec specialized-workloads-demo-client -- nslookup specialized-workloads-demo-sts-0.specialized-workloads-demo-sts.default.svc.cluster.local
```

**Expected output**:

```
Server:		10.96.0.10
Address:	10.96.0.10:53


Name:	specialized-workloads-demo-sts-0.specialized-workloads-demo-sts.default.svc.cluster.local
Address: 10.244.1.24
```

`10.244.1.24` is the IP of `specialized-workloads-demo-sts-0` in the
`get pods -o wide` output above. Delete the client Pod:

```
kubectl delete pod specialized-workloads-demo-client
```

### PersistentVolumeClaims outlive their StatefulSet Pods

**Why**: per-replica storage is only useful if the data survives the Pod
being replaced. So when a StatefulSet's Pods are deleted, their PVCs
stay. Scaling down removes Pods from the highest number down, the
reverse of creation, and leaves their PVCs bound. Scaling back up gives
each recreated Pod the PVC it had before, data included.

**Example**: write a file in the Pod with the highest number, then
scale down so that Pod is removed:

```
kubectl exec specialized-workloads-demo-sts-1 -- sh -c "echo 'from ordinal 1' > /usr/share/nginx/html/marker.txt"
kubectl scale statefulset specialized-workloads-demo-sts --replicas=1
```

```
statefulset.apps/specialized-workloads-demo-sts scaled
```

A few seconds later, look at the Pods and the PVCs:

```
kubectl get pods -l app=specialized-workloads-demo-sts
kubectl get pvc -l app=specialized-workloads-demo-sts
```

**Expected output**: scaling down removed only `-1`; `-0` wasn't
touched. `-1`'s PVC is still `Bound`:

```
NAME                               READY   STATUS    RESTARTS   AGE
specialized-workloads-demo-sts-0   1/1     Running   0          70s
NAME                                    STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS   VOLUMEATTRIBUTESCLASS   AGE
data-specialized-workloads-demo-sts-0   Bound    pvc-4a285c9f-6fa9-4b30-bb9a-56fbd8a154e4   100Mi      RWO            standard       <unset>                 70s
data-specialized-workloads-demo-sts-1   Bound    pvc-8f9ad37e-77d5-479c-ba65-f1a8b03c7cad   100Mi      RWO            standard       <unset>                 62s
```

Scale back to 2. `specialized-workloads-demo-sts-1` is recreated with
the same PVC, so once it's running, the file is still there:

```
kubectl scale statefulset specialized-workloads-demo-sts --replicas=2
kubectl exec specialized-workloads-demo-sts-1 -- cat /usr/share/nginx/html/marker.txt
```

```
statefulset.apps/specialized-workloads-demo-sts scaled
from ordinal 1
```

(If the `exec` says the Pod isn't running yet, try again a few seconds
later.)

Deleting the StatefulSet doesn't delete its PVCs either. You delete
them yourself, along with the headless Service:

```
kubectl delete statefulset specialized-workloads-demo-sts
kubectl delete pvc -l app=specialized-workloads-demo-sts
kubectl delete -f tutorial/examples/specialized-workloads/statefulset-headless-service.yaml
```

```
statefulset.apps "specialized-workloads-demo-sts" deleted from default namespace
persistentvolumeclaim "data-specialized-workloads-demo-sts-0" deleted from default namespace
persistentvolumeclaim "data-specialized-workloads-demo-sts-1" deleted from default namespace
service "specialized-workloads-demo-sts" deleted from default namespace
```

A StatefulSet creates PVCs but never deletes them, on the assumption
that the data matters more than tidying up automatically. An `emptyDir`
volume (chapter 4) is the opposite: it disappears with its Pod.

### DaemonSet: one Pod per node, not a replica count

**Why**: some programs need to run once on every node: log collectors,
monitoring agents, network plugins like kindnet. A Deployment can't
express that. Its `replicas` is a number you choose, unrelated to how
many nodes there are, and the scheduler may put several replicas on
one node and none on another.

A **DaemonSet** has no `replicas` field. It runs one Pod on each node,
and adds or removes Pods as nodes join or leave the cluster. It does
this by giving each Pod a node affinity rule for one specific node.
The Pods still go through the scheduler, so taints still apply: the
control-plane node's taint (chapter 1) keeps a DaemonSet's Pods off it,
unless the Pod template tolerates the taint. That's how kindnet and
kube-proxy run on the control-plane node.

**Example**: [`daemonset.yaml`](examples/specialized-workloads/daemonset.yaml)
has no `replicas` field, and no toleration yet:

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

**Expected output**: `DESIRED` is `2`, not 3. The control-plane node's
taint kept the DaemonSet off it, and there's one Pod on each worker.
(Here one Pod was still pulling its image.)

```
daemonset.apps/specialized-workloads-demo-ds created
NAME                            DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE   NODE SELECTOR   AGE
specialized-workloads-demo-ds   2         2         1       2            1           <none>          8s
NAME                                  READY   STATUS              RESTARTS   AGE   IP            NODE                      NOMINATED NODE   READINESS GATES
specialized-workloads-demo-ds-6gd4r   0/1     ContainerCreating   0          8s    <none>        k8s-lab-default-worker2   <none>           <none>
specialized-workloads-demo-ds-qdxq4   1/1     Running             0          8s    10.244.2.28   k8s-lab-default-worker    <none>           <none>
```

Now add the toleration that kindnet and kube-proxy have (chapter 7
covers taints and tolerations in general). `DESIRED` changes by itself,
because the control-plane node now qualifies too:

```
kubectl patch daemonset specialized-workloads-demo-ds --type=json \
  -p '[{"op":"add","path":"/spec/template/spec/tolerations","value":[{"key":"node-role.kubernetes.io/control-plane","operator":"Exists","effect":"NoSchedule"}]}]'
```

```
daemonset.apps/specialized-workloads-demo-ds patched
```

Changing the Pod template also replaces the existing Pods, one node at
a time. Each old Pod takes about 30 seconds to stop: busybox's `sleep`
ignores the request to stop, as in chapter 4. `kubectl rollout status`
waits until the replacement is finished:

```
kubectl rollout status daemonset/specialized-workloads-demo-ds
kubectl get daemonset specialized-workloads-demo-ds
kubectl get pods -l app=specialized-workloads-demo-ds -o wide
```

**Expected output**: `DESIRED` is `3`, and there's a Pod on the
control-plane node:

```
Waiting for daemon set "specialized-workloads-demo-ds" rollout to finish: 2 out of 3 new pods have been updated...
Waiting for daemon set "specialized-workloads-demo-ds" rollout to finish: 2 of 3 updated pods are available...
daemon set "specialized-workloads-demo-ds" successfully rolled out
NAME                            DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE   NODE SELECTOR   AGE
specialized-workloads-demo-ds   3         3         3       3            3           <none>          76s
NAME                                  READY   STATUS    RESTARTS   AGE   IP            NODE                            NOMINATED NODE   READINESS GATES
specialized-workloads-demo-ds-gq5nl   1/1     Running   0          2s    10.244.2.29   k8s-lab-default-worker          <none>           <none>
specialized-workloads-demo-ds-qjvq7   1/1     Running   0          34s   10.244.1.12   k8s-lab-default-worker2         <none>           <none>
specialized-workloads-demo-ds-tlr9v   1/1     Running   0          68s   10.244.0.6    k8s-lab-default-control-plane   <none>           <none>
```

### DaemonSet's other update strategy: OnDelete

**Why**: the replacement you just saw is a DaemonSet's default
`updateStrategy`, `RollingUpdate`: when the Pod template changes, the
existing Pods are replaced automatically. The other strategy is
`OnDelete`. The template change is still saved, as a new revision, but
no running Pod changes until it's deleted, by you, by draining a node,
or for any other reason. Use `OnDelete` when you want to decide when
each node gets the new version, for example one node at a time on your
own schedule.

**Example**: start again from the two-Pod DaemonSet without the
toleration, which keeps the output short. Switch it to `OnDelete`, then
change its Pod template:

```
kubectl delete daemonset specialized-workloads-demo-ds
kubectl apply -f tutorial/examples/specialized-workloads/daemonset.yaml
kubectl patch daemonset specialized-workloads-demo-ds --type=json \
  -p '[{"op":"replace","path":"/spec/updateStrategy","value":{"type":"OnDelete"}}]'
kubectl patch daemonset specialized-workloads-demo-ds --type=json \
  -p '[{"op":"replace","path":"/spec/template/spec/containers/0/command","value":["sh","-c","sleep 7200"]}]'
kubectl get daemonset specialized-workloads-demo-ds
```

**Expected output**: `UP-TO-DATE` is `0`, though both Pods are
`READY`. The DaemonSet knows its Pods don't match the new template, but
with `OnDelete` it leaves them alone:

```
daemonset.apps "specialized-workloads-demo-ds" deleted from default namespace
daemonset.apps/specialized-workloads-demo-ds created
daemonset.apps/specialized-workloads-demo-ds patched
daemonset.apps/specialized-workloads-demo-ds patched
NAME                            DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE   NODE SELECTOR   AGE
specialized-workloads-demo-ds   2         2         2       0            2           <none>          4s
```

The deleted DaemonSet's three Pods take about 30 seconds to stop, so
wait until `kubectl get pods -l app=specialized-workloads-demo-ds`
lists only the two new ones:

```
NAME                                  READY   STATUS    RESTARTS   AGE
specialized-workloads-demo-ds-fqxt2   1/1     Running   0          45s
specialized-workloads-demo-ds-jdrds   1/1     Running   0          45s
```

Delete one of them, using a name from your own listing (this takes
about 30 seconds too), and only its replacement gets the new template:

```
kubectl delete pod specialized-workloads-demo-ds-fqxt2
kubectl get daemonset specialized-workloads-demo-ds
kubectl get pods -l app=specialized-workloads-demo-ds -o jsonpath='{range .items[*]}{.metadata.name}{": "}{.spec.containers[0].command}{"\n"}{end}'
```

**Expected output**: one Pod runs the new `sleep 7200` command and the
other the old `sleep 3600`, and `UP-TO-DATE` is `1`. That's what an
`OnDelete` update looks like halfway through, not a fault. Nothing will
finish it automatically; each remaining Pod is updated when someone
deletes it:

```
pod "specialized-workloads-demo-ds-fqxt2" deleted from default namespace
NAME                            DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE   NODE SELECTOR   AGE
specialized-workloads-demo-ds   2         2         1       1            1           <none>          77s
specialized-workloads-demo-ds-jdrds: ["sh","-c","sleep 3600"]
specialized-workloads-demo-ds-jnmlc: ["sh","-c","sleep 7200"]
```

`kubectl rollout history` and `rollout undo` (chapter 3) work for
DaemonSets too. A Deployment keeps a ReplicaSet for each revision; a
DaemonSet keeps a **ControllerRevision** object instead, and each Pod's
`controller-revision-hash` label says which revision it runs:

```
kubectl get controllerrevision -l app=specialized-workloads-demo-ds
```

```
NAME                                       CONTROLLER                                     REVISION   AGE
specialized-workloads-demo-ds-5dcc979dc8   daemonset.apps/specialized-workloads-demo-ds   1          77s
specialized-workloads-demo-ds-7f855998fd   daemonset.apps/specialized-workloads-demo-ds   2          73s
```

`rollout undo` only changes the DaemonSet's template, so with
`OnDelete` it's one more template change that no Pod picks up by
itself:

```
kubectl rollout undo daemonset specialized-workloads-demo-ds
kubectl rollout history daemonset specialized-workloads-demo-ds
kubectl get pods -l app=specialized-workloads-demo-ds -o jsonpath='{range .items[*]}{.metadata.name}{": "}{.spec.containers[0].command}{"\n"}{end}'
```

**Expected output**: the undo is recorded as revision `3`, and the
template is back to `sleep 3600`. Both Pods still run what they ran
before. The warning is about `kubectl apply`'s record of what it last
applied (chapter 2), which `rollout undo` doesn't update:

```
Warning: resource daemonsets/specialized-workloads-demo-ds was previously managed with 'kubectl apply'. Rolling back will not update the kubectl.kubernetes.io/last-applied-configuration annotation, which may cause unexpected behavior on future 'kubectl apply' operations. Consider using 'kubectl apply' with your previous configuration file instead.
daemonset.apps/specialized-workloads-demo-ds rolled back
daemonset.apps/specialized-workloads-demo-ds
REVISION  CHANGE-CAUSE
2         <none>
3         <none>

specialized-workloads-demo-ds-jdrds: ["sh","-c","sleep 3600"]
specialized-workloads-demo-ds-jnmlc: ["sh","-c","sleep 7200"]
```

Delete the Pod still running `sleep 7200`, and once its replacement is
running, both Pods match the template again; `UP-TO-DATE` is back to
`2`:

```
kubectl delete pod specialized-workloads-demo-ds-jnmlc
kubectl get daemonset specialized-workloads-demo-ds
```

```
pod "specialized-workloads-demo-ds-jnmlc" deleted from default namespace
NAME                            DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE   NODE SELECTOR   AGE
specialized-workloads-demo-ds   2         2         2       2            2           <none>          2m
```

Delete the DaemonSet when you're done:

```
kubectl delete daemonset specialized-workloads-demo-ds
```

### Workloads that run to completion: Job and CronJob

**Why**: some work is meant to finish: a batch calculation, a database
migration, a one-off maintenance task. A Deployment is the wrong tool,
because it restarts any container that exits. A **Job** runs one or
more Pods until they finish successfully, then stops. A **CronJob**
creates Jobs on a schedule, so you don't have to create each one
yourself. Both are controllers like the ones in chapter 3; they just
aim for "N successful completions" instead of "N running replicas".

**Example**: [`job.yaml`](examples/specialized-workloads/job.yaml) runs
once to completion:

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
```

```
job.batch/specialized-workloads-demo-job created
NAME                             STATUS    COMPLETIONS   DURATION   AGE
specialized-workloads-demo-job   Running   0/1                      0s
```

About 15 seconds later, look at the Job, its conditions, its Pod's
labels and its output:

```
kubectl get job specialized-workloads-demo-job
kubectl get job specialized-workloads-demo-job -o jsonpath='{range .status.conditions[*]}{.type}{" "}{.status}{" "}{.lastTransitionTime}{"\n"}{end}'
kubectl get pods -l job-name=specialized-workloads-demo-job -o jsonpath='{.items[0].metadata.labels}{"\n"}'
kubectl logs job/specialized-workloads-demo-job
```

**Expected output**: the Job reached `1/1` completions and stopped:

```
NAME                             STATUS     COMPLETIONS   DURATION   AGE
specialized-workloads-demo-job   Complete   1/1           10s        15s
SuccessCriteriaMet True 2026-11-19T11:42:55Z
Complete True 2026-11-19T11:42:55Z
{"batch.kubernetes.io/controller-uid":"a7dbb871-eef2-4c51-931f-1d3899511365","batch.kubernetes.io/job-name":"specialized-workloads-demo-job","controller-uid":"a7dbb871-eef2-4c51-931f-1d3899511365","job-name":"specialized-workloads-demo-job"}
Hello from the Job
```

The Job has two conditions, `SuccessCriteriaMet` and `Complete`. They're
separate because a Job's Pods may still be shutting down after it has
succeeded; for a Job this short they were set at the same time. The Pod
has two versions of the Job's name as labels: `job-name`, the original,
and `batch.kubernetes.io/job-name`, the newer one. The old one is kept
so that existing selectors still work.

[`cronjob.yaml`](examples/specialized-workloads/cronjob.yaml) runs the
same kind of Job every minute (`* * * * *`, in cron's schedule format),
and keeps only the most recent successful and failed Job:

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
```

```
cronjob.batch/specialized-workloads-demo-cronjob created
```

Let it run for a few minutes, then look at the CronJob and its Jobs:

```
kubectl get cronjob specialized-workloads-demo-cronjob
kubectl get jobs
```

**Expected output**: after about 4 minutes, the CronJob has run 4 times,
but only **one** of its Jobs is left. (`specialized-workloads-demo-job`
is the Job from the previous example.)

```
NAME                                 SCHEDULE    TIMEZONE   SUSPEND   ACTIVE   LAST SCHEDULE   AGE
specialized-workloads-demo-cronjob   * * * * *   <none>     False     0        56s             3m50s
NAME                                          STATUS     COMPLETIONS   DURATION   AGE
specialized-workloads-demo-cronjob-29918146   Complete   1/1           6s         56s
specialized-workloads-demo-job                Complete   1/1           10s        4m11s
```

`successfulJobsHistoryLimit: 1` makes the CronJob controller delete
each older Job when a newer one completes. (Look just after a run
starts and you'll see two: the last completed one and the new one,
`Running`.) So if a Job seems to have disappeared, or its duration
seems to have jumped between two checks, you're probably looking at a
different Job with a similar name.

The number at the end of the name is the time the Job was scheduled
for, in minutes since 1 January 1970 (Unix time divided by 60). Here
the last run was scheduled for 11:46 UTC:

```
kubectl get cronjob specialized-workloads-demo-cronjob -o jsonpath='{.status.lastScheduleTime}{"\n"}'
echo $(( $(date -u -d 2026-11-19T11:46:00Z +%s) / 60 ))
```

```
2026-11-19T11:46:00Z
29918146
```

(`date -d` is GNU `date`, as on Linux; on macOS, use
`date -u -j -f %Y-%m-%dT%H:%M:%SZ 2026-11-19T11:46:00Z +%s`.)

Delete the CronJob and the Job when you're done:

```
kubectl delete cronjob specialized-workloads-demo-cronjob
kubectl delete job specialized-workloads-demo-job
```
