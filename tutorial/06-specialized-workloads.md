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
kubectl get pods -l app=specialized-workloads-demo-sts -o wide
kubectl get pvc -l app=specialized-workloads-demo-sts
kubectl run specialized-workloads-demo-dnscheck --image=busybox:1.36 --restart=Never -i --rm --command -- \
  nslookup specialized-workloads-demo-sts-0.specialized-workloads-demo-sts.default.svc.cluster.local
```

**Expected output**: Pods named `-0` and `-1`, not random suffixes.
`-1` was only created once `-0` was running. Each has its own PVC:

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

Each Pod's DNS name resolves to that Pod's own IP address. A ClusterIP
Service's name resolves to one shared address that spreads requests
over all its Pods (chapter 5); here, each replica can be reached
individually, at a name that doesn't change:

```
$ kubectl run specialized-workloads-demo-dnscheck --image=busybox:1.36 --restart=Never -i --rm --command -- \
  nslookup specialized-workloads-demo-sts-0.specialized-workloads-demo-sts.default.svc.cluster.local
Name:	specialized-workloads-demo-sts-0.specialized-workloads-demo-sts.default.svc.cluster.local
Address: 10.244.1.5
```

`10.244.1.5` is the IP of `specialized-workloads-demo-sts-0` in the
`get pods -o wide` output above.

### PersistentVolumeClaims outlive their StatefulSet Pods

**Why**: per-replica storage is only useful if the data survives the Pod
being replaced. So when a StatefulSet's Pods are deleted, their PVCs
stay. Scaling down removes Pods from the highest number down, the
reverse of creation, and leaves their PVCs bound. Scaling back up gives
each recreated Pod the PVC it had before, data included.

**Example**: write a file in the Pod with the highest number, scale
down so that Pod is removed, scale back up, and check whether the file
is still there:

```
kubectl exec specialized-workloads-demo-sts-1 -- sh -c "echo 'from ordinal 1' > /usr/share/nginx/html/marker.txt"
kubectl scale statefulset specialized-workloads-demo-sts --replicas=1
kubectl get pvc -l app=specialized-workloads-demo-sts
kubectl scale statefulset specialized-workloads-demo-sts --replicas=2
kubectl exec specialized-workloads-demo-sts-1 -- cat /usr/share/nginx/html/marker.txt
```

**Expected output**: scaling down removes only `-1`; `-0` isn't touched.
`-1`'s PVC stays `Bound`:

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

Scaling back to 2 recreates `specialized-workloads-demo-sts-1` with the
same PVC, so the file is still there:

```
$ kubectl scale statefulset specialized-workloads-demo-sts --replicas=2
statefulset.apps/specialized-workloads-demo-sts scaled

$ kubectl exec specialized-workloads-demo-sts-1 -- cat /usr/share/nginx/html/marker.txt
from ordinal 1
```

Deleting the StatefulSet doesn't delete its PVCs either. You delete
them yourself:

```
kubectl delete statefulset specialized-workloads-demo-sts
kubectl delete pvc -l app=specialized-workloads-demo-sts
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
taint kept the DaemonSet off it, and there's one Pod on each worker:

```
$ kubectl get daemonset specialized-workloads-demo-ds
NAME                            DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE   NODE SELECTOR   AGE
specialized-workloads-demo-ds   2         2         2       2            2           <none>          8s

$ kubectl get pods -l app=specialized-workloads-demo-ds -o wide
NAME                                  READY   STATUS    RESTARTS   AGE   NODE
specialized-workloads-demo-ds-72hm4   1/1     Running   0          8s    k8s-lab-default-worker2
specialized-workloads-demo-ds-ksmpj   1/1     Running   0          8s    k8s-lab-default-worker
```

Now add the toleration that kindnet and kube-proxy have (chapter 7
covers taints and tolerations in general). `DESIRED` changes by itself,
because the control-plane node now qualifies too:

```
kubectl patch daemonset specialized-workloads-demo-ds --type=json \
  -p '[{"op":"add","path":"/spec/template/spec/tolerations","value":[{"key":"node-role.kubernetes.io/control-plane","operator":"Exists","effect":"NoSchedule"}]}]'
kubectl get daemonset specialized-workloads-demo-ds
kubectl get pods -l app=specialized-workloads-demo-ds -o wide
```

**Expected output**: `DESIRED` is `3`, and there's a Pod on the
control-plane node. Changing the Pod template also replaces the
existing Pods, one node at a time, so if you look too soon you may see
a Pod `Terminating` and its replacement `ContainerCreating`:

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

**Expected output**: `UP-TO-DATE` is `0`, though both Pods are still
`READY`. The DaemonSet knows its Pods don't match the new template, but
with `OnDelete` it leaves them alone:

```
NAME                            DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE   NODE SELECTOR   AGE
specialized-workloads-demo-ds   2         2         2       0            2           <none>          15s
```

Delete one Pod, and only its replacement gets the new template:

```
kubectl delete pod specialized-workloads-demo-ds-cj84g
kubectl get daemonset specialized-workloads-demo-ds
kubectl get pods -l app=specialized-workloads-demo-ds -o jsonpath='{range .items[*]}{.metadata.name}{": "}{.spec.containers[0].command}{"\n"}{end}'
```

**Expected output**: one Pod runs the new `sleep 7200` command and the
other the old `sleep 3600`, and `UP-TO-DATE` is `1`. That's what an
`OnDelete` update looks like halfway through, not a fault. Nothing will
finish it automatically; each remaining Pod is updated when someone
deletes it:

```
NAME                            DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE   NODE SELECTOR   AGE
specialized-workloads-demo-ds   2         2         2       1            2           <none>          74s

specialized-workloads-demo-ds-5rd7p: ["sh","-c","sleep 7200"]
specialized-workloads-demo-ds-l2fds: ["sh","-c","sleep 3600"]
```

`kubectl rollout history` and `rollout undo` (chapter 3) work for
DaemonSets too. A Deployment keeps a ReplicaSet for each revision; a
DaemonSet keeps a **ControllerRevision** object instead
(`kubectl get controllerrevision -l app=specialized-workloads-demo-ds`
lists them), and each Pod's `controller-revision-hash` label says which
revision it runs. `rollout undo` only changes the DaemonSet's template,
so with `OnDelete` it's one more template change that no Pod picks up
by itself:
```
kubectl rollout undo daemonset specialized-workloads-demo-ds
kubectl rollout history daemonset specialized-workloads-demo-ds
kubectl get pods -l app=specialized-workloads-demo-ds -o jsonpath='{range .items[*]}{.metadata.name}{": "}{.spec.containers[0].command}{"\n"}{end}'
```

**Expected output**: the undo is recorded as revision `3`, and the
template is back to `sleep 3600`. Both Pods still run what they ran
before:

```
daemonset.apps/specialized-workloads-demo-ds
REVISION  CHANGE-CAUSE
2         <none>
3         <none>

specialized-workloads-demo-ds-5rd7p: ["sh","-c","sleep 7200"]
specialized-workloads-demo-ds-l2fds: ["sh","-c","sleep 3600"]
```

Delete the Pod still running `sleep 7200`, and both Pods match the
template again; `UP-TO-DATE` is back to `2`:

```
$ kubectl delete pod specialized-workloads-demo-ds-5rd7p
$ kubectl get daemonset specialized-workloads-demo-ds
NAME                            DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE   NODE SELECTOR   AGE
specialized-workloads-demo-ds   2         2         2       2            2           <none>          114s
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
kubectl get job specialized-workloads-demo-job -o jsonpath='{range .status.conditions[*]}{.type}{" "}{.status}{" "}{.lastTransitionTime}{"\n"}{end}'
kubectl get pods -l job-name=specialized-workloads-demo-job -o jsonpath='{.items[0].metadata.labels}'
```

**Expected output**: the Job reaches `1/1` completions and stops:

```
job.batch/specialized-workloads-demo-job created

NAME                 STATUS     COMPLETIONS   DURATION   AGE
specialized-workloads-demo-job   Complete   1/1           10s        11s

SuccessCriteriaMet True 2026-08-28T04:19:17Z
Complete True 2026-08-28T04:19:17Z

{"batch.kubernetes.io/controller-uid":"3714e799-...","batch.kubernetes.io/job-name":"specialized-workloads-demo-job","controller-uid":"3714e799-...","job-name":"specialized-workloads-demo-job"}
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
kubectl get cronjob specialized-workloads-demo-cronjob
kubectl get jobs | grep specialized-workloads-demo-cronjob
```

**Expected output**: the CronJob is created. Checked again after it had
run for 29 minutes:

```
cronjob.batch/specialized-workloads-demo-cronjob created
```

```
NAME                      SCHEDULE    SUSPEND   ACTIVE   LAST SCHEDULE   AGE
specialized-workloads-demo-cronjob    * * * * *   False     0        29s             29m

specialized-workloads-demo-cronjob-29798179   Complete   1/1   5s   29s
```

There's only **one** Job, although the CronJob has run about 29 times.
`successfulJobsHistoryLimit: 1` makes the CronJob controller delete
each older Job when a newer one completes. So if a Job seems to have
disappeared, or its duration seems to have jumped between two checks,
you're probably looking at a different Job with a similar name. The
number in the name is the scheduled time, in minutes since 1970:
```
$ kubectl get cronjob specialized-workloads-demo-cronjob -o jsonpath='{.status.lastScheduleTime}'
2026-08-28T04:19:00Z

$ date -u -d "2026-08-28T04:19:00Z" +%s
1787890740

$ echo $(( 1787890740 / 60 ))
29798179
```

The suffix of `specialized-workloads-demo-cronjob-29798179` is the
`lastScheduleTime` in Unix seconds, divided by 60.
