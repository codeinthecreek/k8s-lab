# 2. The API model

Everything in Kubernetes, from Pods and Services to the control-plane
components from chapter 1, is represented the same way: as an **object**
that you send to the API server, which stores it in etcd, and that a
controller then works to make real. This chapter covers that model
before any particular kind of object. Every later chapter builds on it:
each one explains what `spec` means for one kind of object.

### Desired state vs. actual state

**Why**: an object doesn't describe an action, it describes a state to
keep. You don't say "start 3 replicas now"; you say "3 replicas should
exist", and a controller keeps making that true, whatever changes
around it. That's why deleting something a controller manages often
does less than it sounds: you've removed part of the current state,
not the desired state, and the controller notices the difference and
fixes it.

**Example**: `kube-proxy` runs in `kube-system` as a DaemonSet: one Pod
on each node (chapter 3 covers Pods, chapter 6 DaemonSets). Delete one
of its Pods, using a name from your own listing, and see what
happens:

```
kubectl get pods -n kube-system -l k8s-app=kube-proxy
kubectl delete pod -n kube-system <one-pod-name-from-above>
kubectl get pods -n kube-system -l k8s-app=kube-proxy
```

**Expected output**: the deleted Pod is gone, and within seconds a
replacement with a new name appears. Nobody said again "there should
be a kube-proxy Pod on every node"; that desired state never
changed:

```
NAME               READY   STATUS    RESTARTS   AGE
kube-proxy-6fmjz   1/1     Running   0          16h
kube-proxy-lcn5k   1/1     Running   0          16h
kube-proxy-xx42q   1/1     Running   0          16h

$ kubectl delete pod -n kube-system kube-proxy-6fmjz
pod "kube-proxy-6fmjz" deleted from kube-system namespace

NAME               READY   STATUS    RESTARTS   AGE
kube-proxy-9vnfm   1/1     Running   0          8s
kube-proxy-lcn5k   1/1     Running   0          16h
kube-proxy-xx42q   1/1     Running   0          16h
```

`kube-proxy-9vnfm` is a new Pod, not the old one restarted. The
DaemonSet controller saw a node without a kube-proxy Pod and created
one.

### Anatomy of an object: apiVersion, kind, metadata, spec, status

**Why**: every object has the same top-level fields:

- `apiVersion` and `kind` say what type of object it is, and so which
  schema the rest is checked against.
- `metadata` holds the object's identity: name, namespace, labels,
  annotations. It's the same for every type.
- `spec` is the desired state. Its contents are completely different
  for each `kind`.
- `status` is the observed state. You don't write it; the API server
  and controllers fill it in. If you include it in a file you apply,
  it's ignored for most types.

**Example**: [`namespace.yaml`](examples/api-model/namespace.yaml) is
about as small as an object can be. A Namespace doesn't need a
`spec`:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: tutorial-api-model
```

```
kubectl apply -f tutorial/examples/api-model/namespace.yaml
kubectl get namespace tutorial-api-model -o yaml
```

**Expected output**: `namespace/tutorial-api-model created`, and the
object you get back has much more in it than you sent:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  annotations:
    kubectl.kubernetes.io/last-applied-configuration: |
      {"apiVersion":"v1","kind":"Namespace","metadata":{"annotations":{},"name":"tutorial-api-model"}}
  creationTimestamp: "2026-08-28T03:34:24Z"
  labels:
    kubernetes.io/metadata.name: tutorial-api-model
  name: tutorial-api-model
  resourceVersion: "99893"
  uid: 7ce8ace6-fb9f-46c3-a194-b990ca2cd702
spec:
  finalizers:
  - kubernetes
status:
  phase: Active
```

The file had none of `creationTimestamp`, `uid`, `resourceVersion`,
the `kubernetes.io/metadata.name` label, `spec.finalizers`, the
`last-applied-configuration` annotation or `status`; the API server and
`kubectl` added them. The `kubernetes.io/metadata.name` label is added
to every namespace by an **admission plugin**, part of the API server
that can change or reject requests before they're stored (chapter 9).
It lets you select a namespace by name with a label selector, which
NetworkPolicy uses, for example (chapter 9).

### Why namespaces: scope, not isolation

**Why**: a namespace is not a security boundary on its own: a Pod in
one namespace can reach a Service in another unless something stops it
(NetworkPolicy, chapter 9). What it provides is scope:

- Object names only have to be unique within a namespace.
- RBAC (chapter 9) and ResourceQuota (chapter 7) apply per namespace.

That makes a namespace the usual way to divide a cluster between
teams, applications or environments (`staging` and `prod`, `team-a` and
`team-b`) without name clashes or separate clusters. Some objects don't
belong to any namespace: `Node`, `PersistentVolume`, `ClusterRole` and
`Namespace` itself, among others. `kubectl api-resources
--namespaced=false` lists them all.

**Example**: two Pods with the same name, in two namespaces at once:

```
kubectl create namespace tutorial-api-model-team-b
kubectl run namespace-demo --image=nginx:1.27 -n tutorial-api-model
kubectl run namespace-demo --image=nginx:1.27 -n tutorial-api-model-team-b
kubectl get pods -n tutorial-api-model
kubectl get pods -n tutorial-api-model-team-b
```

**Expected output**: two separate Pods with the same name:

```
namespace/tutorial-api-model-team-b created
pod/namespace-demo created
pod/namespace-demo created

NAME             READY   STATUS    RESTARTS   AGE
namespace-demo   1/1     Running   0          4s

NAME             READY   STATUS    RESTARTS   AGE
namespace-demo   1/1     Running   0          3s
```

It's also why the cluster's own components live in `kube-system`, not
`default`: `kubectl delete pods --all -n default`, or a ResourceQuota
on `default`, doesn't affect kube-proxy, CoreDNS or anything else from
chapter 1.

### kubectl as an API client, not a special protocol

**Why**: `kubectl` has no special way into the cluster. It sends ordinary
HTTPS requests to the same REST API that every other client uses
(controllers, CI pipelines, `curl` with a token), gets JSON back, and
formats it for you. `-v=8` makes `kubectl` print each request and
response, so you can see this for yourself.

**Example**: a read and a write on the same object, with tracing:

```
kubectl get namespace tutorial-api-model -v=8 2>&1
kubectl label namespace tutorial-api-model tutorial.example/stage=relabeled -v=8 2>&1
```

**Expected output**: a `GET` for the read, and a `PATCH` with a JSON
body for the label change, both plain HTTP requests to the same
URL:

```
"Request" verb="GET" url="https://127.0.0.1:34415/api/v1/namespaces/tutorial-api-model"
"Response" status="200 OK"
```

```
"Request Body" body="{\"metadata\":{\"labels\":{\"tutorial.example/stage\":\"relabeled\"}}}"
"Request" verb="PATCH" url="https://127.0.0.1:34415/api/v1/namespaces/tutorial-api-model?fieldManager=kubectl-label"
"Response" status="200 OK"
```

The port in the URL (`34415` here) is the port kind chose for this
cluster's API server on your host (chapter 1). It's different for
every cluster; the requests look the same.

> **Aside**: `kubectl` caches what it learns about a server's API (which
> resources and short names exist; that's how it knows `ep` means
> `endpoints`) in `~/.kube/cache/discovery/<host>_<port>/`. Each new
> kind cluster gets a new random port, so old directories pile up. They
> do no harm, since a missing entry is just fetched again, and you can
> delete them all at any time with `rm -rf ~/.kube/cache/discovery/*`.

### `kubectl apply`: diff and PATCH, not blind create

**Why**: `kubectl apply` doesn't delete and recreate the object, and it
doesn't just add whatever is in the file either. It compares three
things:

- the object as it is now on the server,
- the file you're applying, and
- the file you applied last time, which `kubectl` keeps on the object
  in the `kubectl.kubernetes.io/last-applied-configuration` annotation
  (seen above).

Because it knows what you applied last time, `apply` can tell when you
removed a field from the file, and removes it from the object too.
Applying the same file twice changes nothing the second time, so it's
safe to run `apply` repeatedly, for example from a CI pipeline.

**Example**: [`namespace-relabeled.yaml`](examples/api-model/namespace-relabeled.yaml)
is the same Namespace with a label added. Apply it, check that the
object wasn't recreated, then apply the original file again and see
whether the label survives:

```
kubectl get namespace tutorial-api-model -o jsonpath='{.metadata.uid}{"\n"}{.metadata.creationTimestamp}'
kubectl apply -f tutorial/examples/api-model/namespace-relabeled.yaml
kubectl get namespace tutorial-api-model -o jsonpath='{.metadata.uid}{"\n"}{.metadata.creationTimestamp}'
kubectl get namespace tutorial-api-model -o jsonpath='{.metadata.labels}'
kubectl apply -f tutorial/examples/api-model/namespace.yaml
kubectl get namespace tutorial-api-model -o jsonpath='{.metadata.labels}'
```

**Expected output**: `uid` and `creationTimestamp` are the same before
and after: the object was changed in place, not deleted and
recreated:

```
7ce8ace6-fb9f-46c3-a194-b990ca2cd702
2026-08-28T03:34:24Z
```
```
namespace/tutorial-api-model configured
```
```
7ce8ace6-fb9f-46c3-a194-b990ca2cd702
2026-08-28T03:34:24Z
```

The label is there after the apply:

```
{"kubernetes.io/metadata.name":"tutorial-api-model","tutorial.example/stage":"relabeled"}
```

After applying the original file again, which doesn't have that label,
it's gone from the object:

```
namespace/tutorial-api-model configured
```
```
{"kubernetes.io/metadata.name":"tutorial-api-model"}
```

So `apply` doesn't only add. If you remove a field from a file you
applied before, `apply` removes it from the object.
`kubernetes.io/metadata.name` survives because you never applied it: it
isn't in the `last-applied-configuration` annotation, so `apply`
leaves it alone.

### Cleaning up

Two namespaces are left, `tutorial-api-model` and
`tutorial-api-model-team-b`, with a `namespace-demo` Pod in each.
Deleting a namespace deletes everything in it, so one command removes
it all:

```
kubectl delete namespace tutorial-api-model tutorial-api-model-team-b
```

It waits for the Pods to stop, so it can take a few seconds.
