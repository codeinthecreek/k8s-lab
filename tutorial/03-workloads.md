# 3. Pods and workloads

Chapter 2 used a Namespace, the simplest object there is, to show how
the API works. This chapter covers the objects that run your
applications: the **Pod**, and two controllers built on it,
**ReplicaSet** and **Deployment**, which replace Pods that disappear and
update them in a controlled way. All the Pods in this chapter are
interchangeable; chapter 6 covers workloads where they aren't.

### The Pod as the atomic unit

**Why**: Kubernetes never runs a container on its own. It runs **Pods**.
A Pod is one or more containers that always run together on the same
node. They share one IP address (containers in a Pod reach each other
on `localhost`), and they can share volumes. The scheduler places
whole Pods, so if two containers must run on the same node, they
belong in the same Pod.

**Example**: [`pod.yaml`](examples/workloads/pod.yaml) is a Pod with one
container, the most common case:

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

**Expected output**: one running Pod with its own IP, on whichever
worker the scheduler picked:

```
pod/workloads-demo-pod created
NAME                 READY   STATUS    RESTARTS   AGE   IP            NODE                      NOMINATED NODE   READINESS GATES
workloads-demo-pod   1/1     Running   0          10s   10.244.1.34   k8s-lab-default-worker2   <none>           <none>
```

(On a new cluster, the first `get` may show `ContainerCreating` while
the `nginx:1.27` image is pulled. Run it again after a few seconds.)

### Why you rarely create a Pod on its own

**Why**: there are two kinds of recovery, and a Pod on its own only
gets one of them:

- If a **container** in the Pod crashes, the kubelet on the node
  restarts it, following the Pod's `restartPolicy` (`Always` by
  default). The Pod itself stays, so nothing else is needed.
- If the **Pod** is deleted, nothing recreates it. Nothing is watching
  for "a Pod like this should exist", except whoever created it: here,
  you, once.

That missing piece is what ReplicaSets and Deployments add.

**Example**: stop the container's main process, then delete the Pod,
and compare:

```
kubectl exec workloads-demo-pod -- sh -c "kill 1"
kubectl get pod workloads-demo-pod
```

Right after the `kill`, the container has stopped:

```
NAME                 READY   STATUS      RESTARTS   AGE
workloads-demo-pod   0/1     Completed   0          11s
```

Run the `get` again a few seconds later.

**Expected output**: `RESTARTS` has gone up on the *same* Pod. The name
is the same and `AGE` keeps counting: the kubelet restarted the
container (nginx, the main process, PID 1), and the Pod was never
replaced:

```
NAME                 READY   STATUS    RESTARTS      AGE
workloads-demo-pod   1/1     Running   1 (10s ago)   20s
```

Deleting the Pod is different: it stays gone:

```
kubectl delete pod workloads-demo-pod
kubectl get pod workloads-demo-pod
```

```
pod "workloads-demo-pod" deleted from default namespace
Error from server (NotFound): pods "workloads-demo-pod" not found
```

### ReplicaSet: keeping a number of Pods running

**Why**: a ReplicaSet makes sure a given number of Pods, built from its
Pod template, exist at all times. It finds "its" Pods by their labels,
using its `spec.selector`. So you can delete a ReplicaSet and leave its
Pods running, and a new ReplicaSet with the same selector will take
over the Pods it finds instead of creating new ones.

**Example**: [`replicaset.yaml`](examples/workloads/replicaset.yaml) runs
3 replicas with the selector `app: workloads-demo-rs`. Delete it with
`--cascade=orphan`, which keeps its Pods, check that they're still
there, then apply the same ReplicaSet again and see whether it creates
new Pods or takes over the old ones:

```
kubectl apply -f tutorial/examples/workloads/replicaset.yaml
kubectl get pods -l app=workloads-demo-rs -o custom-columns=NAME:.metadata.name,CREATED:.metadata.creationTimestamp
```

`-o custom-columns` prints just the columns you name, here each Pod's
name and creation time:

```
replicaset.apps/workloads-demo-rs created
NAME                      CREATED
workloads-demo-rs-44mw6   2026-11-19T11:56:29Z
workloads-demo-rs-6lj9h   2026-11-19T11:56:29Z
workloads-demo-rs-bl9q6   2026-11-19T11:56:29Z
```

Delete the ReplicaSet but keep its Pods, then list them:

```
kubectl delete rs workloads-demo-rs --cascade=orphan
kubectl get pods -l app=workloads-demo-rs
```

```
replicaset.apps "workloads-demo-rs" deleted from default namespace
NAME                      READY   STATUS    RESTARTS   AGE
workloads-demo-rs-44mw6   1/1     Running   0          9s
workloads-demo-rs-6lj9h   1/1     Running   0          9s
workloads-demo-rs-bl9q6   1/1     Running   0          9s
```

Apply the same ReplicaSet again, and look at the Pods and the
ReplicaSet:

```
kubectl apply -f tutorial/examples/workloads/replicaset.yaml
kubectl get pods -l app=workloads-demo-rs -o custom-columns=NAME:.metadata.name,CREATED:.metadata.creationTimestamp
kubectl get rs workloads-demo-rs
```

**Expected output**: the same 3 Pods throughout. They kept running
without a ReplicaSet, and the new ReplicaSet took them over instead of
creating new ones:

```
replicaset.apps/workloads-demo-rs created
NAME                      CREATED
workloads-demo-rs-44mw6   2026-11-19T11:56:29Z
workloads-demo-rs-6lj9h   2026-11-19T11:56:29Z
workloads-demo-rs-bl9q6   2026-11-19T11:56:29Z
NAME                DESIRED   CURRENT   READY   AGE
workloads-demo-rs   3         3         3       2s
```

The names and creation times are the same before and after. The new
ReplicaSet was at `3/3` ready within seconds, because it found running
Pods that matched its selector. A ReplicaSet can own Pods it didn't
create; that's how selectors work.

### Deployment: rolling updates through ReplicaSets

**Why**: a ReplicaSet can't update its Pods to a new template on its
own: you'd have to delete them all at once, or manage a second
ReplicaSet yourself. A **Deployment** does that for you. It manages
ReplicaSets, and when you change its Pod template (a new image, for
example), it creates a *new* ReplicaSet and gradually moves replicas
from the old one to the new one. That's a **rolling update**. This is
why `kubectl rollout status`, `history` and `undo` work on
Deployments: rollouts belong to the Deployment, and ReplicaSets are
how it carries them out.

**Example**: [`deployment.yaml`](examples/workloads/deployment.yaml) runs
the same 3 nginx replicas as a Deployment. Record a reason for the
change in the `kubernetes.io/change-cause` annotation *before* making
it (afterwards is too late for the new revision), then change the
image and follow the rollout:

```
kubectl apply -f tutorial/examples/workloads/deployment.yaml
kubectl annotate deployment workloads-demo-deploy kubernetes.io/change-cause="bump nginx to 1.28" --overwrite
kubectl set image deployment/workloads-demo-deploy nginx=nginx:1.28
kubectl rollout status deployment/workloads-demo-deploy
kubectl get rs -l app=workloads-demo-deploy
kubectl rollout history deployment/workloads-demo-deploy
```

**Expected output**: Pods are replaced one at a time (the default
`RollingUpdate` strategy); `rollout status` reports progress until it's
done, repeating lines while it waits (shortened here). Afterwards there
are two ReplicaSets: the new one, and the old one scaled to zero. The
old one is kept so that `kubectl rollout undo` can go back to it:

```
deployment.apps/workloads-demo-deploy created
deployment.apps/workloads-demo-deploy annotated
deployment.apps/workloads-demo-deploy image updated
Waiting for deployment spec update to be observed...
Waiting for deployment "workloads-demo-deploy" rollout to finish: 0 out of 3 new replicas have been updated...
Waiting for deployment "workloads-demo-deploy" rollout to finish: 1 out of 3 new replicas have been updated...
Waiting for deployment "workloads-demo-deploy" rollout to finish: 2 out of 3 new replicas have been updated...
Waiting for deployment "workloads-demo-deploy" rollout to finish: 1 old replicas are pending termination...
deployment "workloads-demo-deploy" successfully rolled out
NAME                               DESIRED   CURRENT   READY   AGE
workloads-demo-deploy-5f48cd94b9   3         3         3       80s
workloads-demo-deploy-75bf95bd74   0         0         0       81s
deployment.apps/workloads-demo-deploy
REVISION  CHANGE-CAUSE
1         bump nginx to 1.28
2         bump nginx to 1.28
```

Both revisions show the same change cause. The annotation was added
while revision 1 was the current ReplicaSet, so it was copied there
too, as well as to revision 2. Adding it before the change gets it
onto the new revision, but it may end up on the old one as well.

Older material uses `kubectl set image ... --record` to fill in the
change cause. `--record` is deprecated: it still works, but prints
`Flag --record has been deprecated, --record will be removed in the
future`. Use `kubectl annotate` as above.

Does running the same `set image` command again create another
revision?

```
kubectl set image deployment/workloads-demo-deploy nginx=nginx:1.28
kubectl rollout history deployment/workloads-demo-deploy
```

```
deployment.apps/workloads-demo-deploy
REVISION  CHANGE-CAUSE
1         bump nginx to 1.28
2         bump nginx to 1.28
```

No, and `set image` printed nothing at all. It compares the new image
with the current one, and if they're the same, it does nothing. A script
that expects a new revision every time it runs won't get one, and
won't see an error either.

### Cleaning up

The ReplicaSet and the Deployment are still running (the bare Pod is
already gone). Delete both; by default, deleting a controller also
deletes everything it owns:

```
kubectl delete rs workloads-demo-rs
kubectl delete deployment workloads-demo-deploy
```

Pods can take a few seconds to stop. Check that nothing is left:

```
kubectl get rs,pods -l 'app in (workloads-demo-rs, workloads-demo-deploy)'
```

(`-l 'app in (...)'` is a set-based selector: it matches either
label value.) When it says `No resources found in default namespace.`, the chapter is
cleaned up.
