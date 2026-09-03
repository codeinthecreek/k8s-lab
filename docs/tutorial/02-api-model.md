# 2. The API model

Everything in Kubernetes - Pods, Services, the control-plane components
from chapter 1's static pods - is represented the same way: an object
submitted to the apiserver, stored in etcd, and reconciled toward by
some controller. This chapter covers that model directly, before any
specific object type, because every later chapter is really just "here's
what `spec` means for this one kind of object."

### Desired state vs. actual state

**Why**: Kubernetes objects don't describe an action to take - they
describe a state to maintain. You don't tell it "start 3 replicas now,"
you tell it "3 replicas should exist," and a controller keeps making
that true, continuously, independent of whatever caused the current
state to drift. This is why deleting something a controller manages
usually isn't destructive in the way it sounds: you're not removing the
desired state, only a piece of the currently-observed state, and the
controller notices the gap and closes it.

**Example**: `kube-proxy` runs as a DaemonSet in `kube-system` - one Pod
per node (chapter 3 covers what a Pod actually is), desired count fixed
by node count, no user intervention. Delete one of its Pods directly
and watch what happens to desired state versus what you just changed:

```
kubectl get pods -n kube-system -l k8s-app=kube-proxy
kubectl delete pod -n kube-system <one-pod-name-from-above>
kubectl get pods -n kube-system -l k8s-app=kube-proxy
```

**Expected output**: the deleted Pod is gone, and a replacement with a
new name appears on its own within seconds, without anyone re-declaring
"I want 3 kube-proxy Pods" - that desired state was never touched:

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

`kube-proxy-9vnfm` is a genuinely new Pod object, not the old one
restarted - the DaemonSet controller (chapter 6 covers DaemonSet in
depth) is watching desired vs. actual node coverage and created it the
moment it saw one node without a kube-proxy Pod.

### Anatomy of an object: apiVersion, kind, metadata, spec, status

**Why**: every object, regardless of type, is submitted with the same
four top-level fields. `apiVersion` and `kind` identify which API group
and schema the rest of the object is validated against. `metadata`
carries identity (name, namespace, labels, annotations) - things that
apply uniformly across every object type. `spec` is where the type-
specific desired state lives, and its shape is entirely different per
`kind` - a Namespace's spec looks nothing like a Deployment's. What you
never write yourself is `status`: it's a separate part of the object
that only the apiserver and controllers populate, reporting observed
state back. Submitting a `status` in a create/apply is accepted but
ignored for most types - it isn't how you make anything happen.

**Example**: `tutorial/examples/api-model/namespace.yaml` is about as
minimal an object as exists - a Namespace needs nothing under `spec` to
be valid:

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
object read back has substantially more in it than what was submitted:

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

None of `creationTimestamp`, `uid`, `resourceVersion`, the
`kubernetes.io/metadata.name` label, `spec.finalizers`, the
`last-applied-configuration` annotation, or the entire `status` block
were in the file that got applied - the apiserver added all of it. The
`kubernetes.io/metadata.name` label in particular is worth noticing: an
admission controller - a piece of apiserver logic that intercepts a
request after auth and before it's persisted, and can mutate or reject
it; chapter 9 covers this stage properly - adds it to every namespace
automatically, which is what makes label selectors like
`kubernetes.io/metadata.name=<ns>` usable for targeting a specific
namespace elsewhere in the API (NetworkPolicy namespaceSelectors, for
instance - chapter 9).

### Why namespaces: isolation, scoping, and multi-tenancy

**Why**: a Namespace isn't a security boundary by itself - a Pod in one
namespace can still reach a Service in another over the network unless
something explicitly stops it (chapter 9's NetworkPolicy). What it
*does* provide is a scoping boundary that almost everything else in
Kubernetes is defined relative to: object names only have to be unique
within a namespace, not across the whole cluster, and mechanisms like
RBAC (chapter 9) and ResourceQuota (chapter 7) apply per-namespace by default. This
is what makes a namespace the practical unit for dividing one physical
cluster among multiple teams, applications, or environments (`staging`
vs `prod`, `team-a` vs `team-b`) without them colliding on names or
needing separate infrastructure. Not every object is scoped this way,
though - `Node`, `PersistentVolume`, `ClusterRole`, and `Namespace`
itself exist once per cluster regardless of namespace, checkable
directly with `kubectl api-resources --namespaced=false`.

**Example**: the exact same object name, `Pod` and all, created in two
different namespaces at once - something a single flat namespace
couldn't allow:

```
kubectl create namespace tutorial-api-model-team-b
kubectl run namespace-demo --image=nginx:1.27 -n tutorial-api-model
kubectl run namespace-demo --image=nginx:1.27 -n tutorial-api-model-team-b
kubectl get pods -n tutorial-api-model
kubectl get pods -n tutorial-api-model-team-b
```

**Expected output**: two genuinely separate Pod objects, same name,
neither aware the other exists:

```
namespace/tutorial-api-model-team-b created
pod/namespace-demo created
pod/namespace-demo created

NAME             READY   STATUS    RESTARTS   AGE
namespace-demo   1/1     Running   0          4s

NAME             READY   STATUS    RESTARTS   AGE
namespace-demo   1/1     Running   0          3s
```

This is also why `kube-system` is kept separate from `default` rather
than running the control plane's own DaemonSets and Deployments
alongside whatever the cluster is actually used for: a `kubectl delete
pods --all -n default`, or a ResourceQuota applied to `default`, has
zero effect on anything in `kube-system` (`kube-proxy`, CoreDNS, and
everything else chapter 1 covered), and vice versa. Namespace boundaries
being the thing access control is drawn against also carries forward
into chapter 9, where every effective RBAC permission is the union of
whichever `Role`/`ClusterRole` objects are bound to an identity - a
`Role` scoped to a single namespace, a `ClusterRole` scoped to the whole
cluster - a distinction that only makes sense once namespace scoping
itself is a solid mental model, which is what this section is for.

### kubectl as an API client, not a special protocol

**Why**: `kubectl` has no privileged channel into the cluster - it builds
plain HTTPS requests against the same REST API any other client (a
controller, a CI pipeline using a service account token, `curl` with a
bearer token) would use, gets JSON back, and renders it. `-v=8` turns on
request/response tracing so this stops being an assertion and becomes
something you can watch happen.

**Example**: a read and a write against the same object, traced:

```
kubectl get namespace tutorial-api-model -v=8 2>&1
kubectl label namespace tutorial-api-model tutorial.example/stage=relabeled -v=8 2>&1
```

**Expected output**: a `GET` for the read, a `PATCH` carrying a JSON
merge-patch body for the label write - both plain HTTP against the same
resource URL:

```
"Request" verb="GET" url="https://127.0.0.1:34415/api/v1/namespaces/tutorial-api-model"
"Response" status="200 OK"
```

```
"Request Body" body="{\"metadata\":{\"labels\":{\"tutorial.example/stage\":\"relabeled\"}}}"
"Request" verb="PATCH" url="https://127.0.0.1:34415/api/v1/namespaces/tutorial-api-model?fieldManager=kubectl-label"
"Response" status="200 OK"
```

The port in that URL (`34415` here) is kind's randomly-assigned
apiserver host port for this cluster (see chapter 1's node-as-container
model and the top-level README's architecture diagram) - it'll differ
per cluster, the request shape won't.

> **Aside** (a detour from this section's actual point - skippable):
> kubectl caches a server's OpenAPI/discovery data (which API groups,
> resources, and shortnames exist - what makes `kubectl get ep` resolve
> to `endpoints` at all) under `~/.kube/cache/discovery/<server-address>/`,
> keyed by host:port, not by "which cluster this is." Recreating a kind
> cluster gets a fresh, randomly-assigned apiserver port, so it never
> reuses or invalidates an old entry - it just leaves it behind:
>
> ```
> $ kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}'
> https://127.0.0.1:36673
> $ ls ~/.kube/cache/discovery/
> 127.0.0.1_34415
> 127.0.0.1_34503
> 127.0.0.1_35045
> 127.0.0.1_36541
> 127.0.0.1_36673
> 127.0.0.1_38431
> ...
> ```
>
> `34415` is the exact port this section's own trace above hit - still
> sitting there, stale. None of those stale directories cause wrong
> answers - a cache miss just means kubectl re-fetches on the next call
> - they're disk clutter, safe to delete wholesale
> (`rm -rf ~/.kube/cache/discovery/*`) any time.

### `kubectl apply`: diff and PATCH, not blind create

**Why**: `apply` is not "delete and recreate from this file," and it's
not a naive "add whatever fields are in the file" either. It computes a
three-way merge between three things: the object's live state on the
server, the file you're applying now, and the *previous* applied
configuration (which kubectl stores on the object itself, in the
`kubectl.kubernetes.io/last-applied-configuration` annotation seen
above). That three-way comparison is what lets `apply` do something a
simple overlay can't: a field that was in the previous applied config
but is missing from the new file gets actively removed from the live
object, not just left alone. Re-running the same `apply` twice is a
no-op PATCH, not two creates - which is what makes `apply` safe to wire
into a loop or a CI pipeline.

**Example**: apply the relabeled version of the same namespace, inspect
identity fields to confirm nothing was recreated, then apply the
*original* file again and check whether the added label survives:

```
kubectl get namespace tutorial-api-model -o jsonpath='{.metadata.uid}{"\n"}{.metadata.creationTimestamp}'
kubectl apply -f tutorial/examples/api-model/namespace-relabeled.yaml
kubectl get namespace tutorial-api-model -o jsonpath='{.metadata.uid}{"\n"}{.metadata.creationTimestamp}'
kubectl get namespace tutorial-api-model -o jsonpath='{.metadata.labels}'
kubectl apply -f tutorial/examples/api-model/namespace.yaml
kubectl get namespace tutorial-api-model -o jsonpath='{.metadata.labels}'
```

**Expected output**: `uid` and `creationTimestamp` are identical before
and after the relabel apply - proof the object was patched in place, not
deleted and recreated:

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

The label is present right after the relabel apply:

```
{"kubernetes.io/metadata.name":"tutorial-api-model","tutorial.example/stage":"relabeled"}
```

Then, after re-applying the *original* file (which never had that
label), it's genuinely gone - not just absent from the file, absent from
the live object:

```
namespace/tutorial-api-model configured
```
```
{"kubernetes.io/metadata.name":"tutorial-api-model"}
```

This is the failure mode worth internalizing: a common wrong mental
model is "apply only ever adds fields, so it's always safe regardless of
what I removed from the file." It isn't - `apply` actively deletes
fields you drop from the source, provided they were part of what you
applied last time. `kubernetes.io/metadata.name` survives both applies
because it was never something *you* applied - the admission controller
that set it, not kubectl, is that field's manager, and `apply`'s merge
only ever touches fields it owns.
