# 11. Extending the API: CRDs

Every object type so far, from Pods to Jobs, is built into the
apiserver, and a controller inside `kube-controller-manager` acts on it.
A **CustomResourceDefinition** (CRD) lets you add a new type of your
own, without changing or rebuilding anything. You apply a manifest that
tells the apiserver about a new `apiVersion` and `kind`, and the
apiserver stores objects of that type like any other. If you want
something to *happen* when those objects change, you also write a
controller.

A custom type follows the same object model as the built-in ones
(chapter 2). So everything you already know carries over: `kubectl get`,
`describe`, `apply` and `delete` work on it, and chapter 10's ways of
finding out what's wrong apply to it too.

### Custom resources: the same object model, a new type

**Why**: a CRD is itself a Kubernetes object
(`apiVersion: apiextensions.k8s.io/v1`, `kind: CustomResourceDefinition`).
Once it's registered, objects of the new type have the usual
`apiVersion`, `kind`, `metadata` and `spec` (chapter 2), and you create,
list and delete them with the usual `kubectl` commands.

**Example**: [`crontab-crd.yaml`](examples/crds/crontab-crd.yaml)
registers a type called `CronTab`, and
[`crontab-instance.yaml`](examples/crds/crontab-instance.yaml) creates
one:

```
kubectl apply -f tutorial/examples/crds/crontab-crd.yaml
kubectl get crd crontabs.example.com
kubectl apply -f tutorial/examples/crds/crontab-instance.yaml
kubectl get crontabs
kubectl get ct
```

**Expected output**: the new type works at once, like any other
resource. Even its short name, `ct`, works the way `po` does for Pods:

```
$ kubectl apply -f tutorial/examples/crds/crontab-crd.yaml
customresourcedefinition.apiextensions.k8s.io/crontabs.example.com created

$ kubectl get crd crontabs.example.com
NAME                   CREATED AT
crontabs.example.com   2026-08-30T07:54:05Z

$ kubectl apply -f tutorial/examples/crds/crontab-instance.yaml
crontab.example.com/tutorial-demo-crontab created

$ kubectl get crontabs
NAME                    AGE
tutorial-demo-crontab   0s

$ kubectl get ct
NAME                    AGE
tutorial-demo-crontab   0s
```

`kubectl get` shows only `NAME` and `AGE` because the CRD doesn't say
which other columns to print. A CRD can add columns, for example for
`cronSpec`, with `additionalPrinterColumns`, but that's only about
display.

### A CRD alone is inert - no controller, no behavior

**Why**: a CRD only defines a type and stores objects of it. Nothing
reads `spec.cronSpec` and runs anything on that schedule. For that you
need a controller (often called an *operator*): a program that watches
objects of the type through the API and acts on them, as
`kube-controller-manager`'s built-in controllers do for ReplicaSets
(chapter 3) and Jobs (chapter 6). Without one, a `CronTab` is just data
stored in etcd, unchanged.

**Example**: no controller in this cluster watches `CronTab` objects.
Check whether anything has acted on the one created above:

```
kubectl get crontab tutorial-demo-crontab -o jsonpath='{.status}'
kubectl get events --field-selector involvedObject.name=tutorial-demo-crontab
```

**Expected output**: nothing. `status` is empty and there are no
events. Compare chapter 6's CronJob: its `status` fills in with
`lastScheduleTime` and its Jobs come and go, because a controller in
`kube-controller-manager` acts on it:

```
$ kubectl get crontab tutorial-demo-crontab -o jsonpath='{.status}'
(empty output)

$ kubectl get events --field-selector involvedObject.name=tutorial-demo-crontab
No resources found in default namespace.
```

### Schema validation: mandatory at definition, enforced on every instance

**Why**: in `apiextensions.k8s.io/v1`, every version in a CRD must have
an `openAPIV3Schema` describing its fields. (In the old `v1beta1`,
since removed, it was optional.) The apiserver then checks every new or
changed object against that schema and rejects anything that doesn't
match, just as it rejects a Pod whose `image` isn't a string.

**Example**: [`crontab-crd-no-schema.yaml`](examples/crds/crontab-crd-no-schema.yaml)
is a CRD without a schema.
[`crontab-instance-invalid.yaml`](examples/crds/crontab-instance-invalid.yaml)
is a `CronTab` whose `replicas` is a string, although
`crontab-crd.yaml`'s schema says it must be an integer:

```
kubectl apply -f tutorial/examples/crds/crontab-crd-no-schema.yaml
kubectl apply -f tutorial/examples/crds/crontab-instance-invalid.yaml
```

**Expected output**: the apiserver rejects both. The CRD fails because
it has no schema; the `CronTab` fails because it doesn't match the
schema that's already registered:

```
$ kubectl apply -f tutorial/examples/crds/crontab-crd-no-schema.yaml
The CustomResourceDefinition "crontabs.example.com" is invalid: spec.versions[0].schema.openAPIV3Schema: Required value

$ kubectl apply -f tutorial/examples/crds/crontab-instance-invalid.yaml
The CronTab "tutorial-demo-crontab-invalid" is invalid: spec.replicas: Invalid value: "string": spec.replicas in body must be of type integer: "string"
```

Neither object was stored.

### Deleting a CRD cascades to every instance - and the type itself

**Why**: the CRD *is* the type. Deleting it deletes every object of
that type too, and the type itself disappears from the API. So a
`kubectl get` afterwards doesn't return an empty list, as it would after
you delete the last Deployment. It returns an error saying the server
doesn't know the resource type.

**Example**: delete the CRD and look for `CronTab` objects:

```
kubectl delete crd crontabs.example.com
kubectl get crontabs
```

**Expected output**: `tutorial-demo-crontab` is deleted along with the
CRD, and `get` fails:

```
$ kubectl delete crd crontabs.example.com
customresourcedefinition.apiextensions.k8s.io "crontabs.example.com" deleted

$ kubectl get crontabs
Error from server (NotFound): Unable to list "example.com/v1, Resource=crontabs": the server could not find the requested resource (get crontabs.example.com)
```

The `NotFound` is about the resource type (`get crontabs.example.com`),
not about one object: the apiserver no longer knows what a `CronTab`
is.

### When a CRD isn't enough: the aggregated-API-server alternative

**Why**: a CRD gives you a lot for free. The apiserver stores the
objects in etcd, validates them against the schema, and supports
`kubectl get`, `apply`, `describe` and `watch` on them, all from one
manifest. But that's also its limit: every object is stored in etcd and
returned as stored. A CRD can't keep its data somewhere else, can't
compute an answer when someone reads it, and can't add authorization
checks beyond RBAC. No schema can change that.

When you need any of those, the alternative is an **aggregated API**:
a separate API server of your own, which the main apiserver forwards
requests to. The forwarding is done by the apiserver's *aggregation
layer*, which is always on. You register your server with an
`APIService` object, which names an API group and the `Service` in
front of your server. From then on, requests for that group go to your
server, which can store and compute its answers however it likes.

You've already used one. `kubectl top` (chapter 10) reads the
`metrics.k8s.io` group, and that group is served by metrics-server, a
separate Deployment registered with an `APIService`. On this cluster,
`kubectl get apiservice v1beta1.metrics.k8s.io` shows it, with
`service.name: metrics-server`. metrics-server doesn't read anything
from etcd: it works out its answers from the metrics it collects from
each node's kubelet.

One related apiserver flag: `--enable-aggregator-routing` (listed in
`kube-apiserver --help` on this cluster) doesn't turn aggregation on or
off. It only changes how the apiserver reaches a registered server:
directly at its Pods' IPs instead of through its Service's cluster IP.

An aggregated API costs more than a CRD. It's another program to build,
release and keep running, and if it's down, its whole API group is
unavailable. A CRD's objects, by contrast, can still be read from etcd
even when the controller that acts on them is broken. So use a CRD (plus
a controller, if something should happen) by default. Use an aggregated
API only when "data in etcd plus a controller" can't do the job: your
own storage, answers computed on request, or behavior the object model
can't express.

A new API group can also arrive a third way: built into
`kube-apiserver` itself, neither a CRD nor a separate server.
`resource.k8s.io` (Dynamic Resource Allocation, chapter 14) is an
example. It's present on every Kubernetes 1.34+ cluster with nothing to
apply, and it does nothing until a device driver uses it.
