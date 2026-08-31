# 11. Extending the API: CRDs

Chapter 10's diagnostic techniques - events, logs, `describe` output -
worked because every object involved is built into the apiserver and
reconciled by a controller running inside `kube-controller-manager`,
same as every other object covered so far (Pods, Deployments, Services,
even Jobs). A CustomResourceDefinition (CRD) is how you register an
entirely new type the same way, without recompiling anything: a plain
manifest that teaches the apiserver a new `apiVersion`/`kind`, storage
for it, and (if you write one) a controller to watch and act on it.
This chapter treats CRDs as the generalization of the object model
chapter 2 introduced, not a separate feature bolted on top of it - which
is exactly why chapter 10's techniques carry over unchanged to a `kind`
you registered yourself.

### Custom resources: the same object model, a new type

**Why**: a CRD's own manifest is itself a Kubernetes object
(`apiVersion: apiextensions.k8s.io/v1`, `kind:
CustomResourceDefinition`) - registering it teaches the apiserver a new
type, after which instances of that type are created, listed, and
deleted exactly like any built-in object: same `apiVersion`/`kind`/
`metadata`/`spec` shape (chapter 2), same `kubectl apply`/`get`/
`describe`/`delete` verbs, same declarative model throughout.

**Example**: register the `CronTab` type
(`tutorial/examples/crds/crontab-crd.yaml`), then create an instance of
it (`tutorial/examples/crds/crontab-instance.yaml`):

```
kubectl apply -f tutorial/examples/crds/crontab-crd.yaml
kubectl get crd crontabs.example.com
kubectl apply -f tutorial/examples/crds/crontab-instance.yaml
kubectl get crontabs
kubectl get ct
```

**Expected output**: the CRD registers immediately, and once it does,
`crontabs` behaves like any other resource - including its
`shortNames` entry working exactly like `po` does for Pods:

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

No printer columns were configured on the CRD, so `kubectl get` falls
back to the generic NAME/AGE view - a CRD can define
`additionalPrinterColumns` to surface fields like `cronSpec` here, but
that's cosmetic, not part of the core mechanism this chapter covers.

### A CRD alone is inert - no controller, no behavior

**Why**: registering a type and storing instances of it is all a CRD
does by itself. Nothing watches `spec.cronSpec` and actually schedules
anything - that requires a separate controller (an operator) running
somewhere, watching the type via the API and taking action, the same
role `kube-controller-manager`'s built-in controllers play for
ReplicaSets and Jobs (ReplicaSets - chapter 3; Jobs - chapter 6). A `CronTab` object with no controller
watching it just sits in etcd as structured data, forever, exactly as
created.

**Example**: the `tutorial-demo-crontab` object created above has no
controller watching `crontabs.example.com` anywhere in this cluster -
confirm nothing acts on it over time, unlike chapter 6's CronJob (which
has a real controller built into `kube-controller-manager`):

```
kubectl get crontab tutorial-demo-crontab -o jsonpath='{.status}'
kubectl get events --field-selector involvedObject.name=tutorial-demo-crontab
```

**Expected output**: nothing - `status` is empty and there are no
events, because no controller in this cluster is watching
`crontabs.example.com`. Contrast this with chapter 6's CronJob, whose
`status` fills in with `lastScheduleTime` and whose Job history rotates
on its own, entirely because a real controller inside
`kube-controller-manager` is reconciling it:

```
$ kubectl get crontab tutorial-demo-crontab -o jsonpath='{.status}'
(empty output)

$ kubectl get events --field-selector involvedObject.name=tutorial-demo-crontab
No resources found in default namespace.
```

### Schema validation: mandatory at definition, enforced on every instance

**Why**: `apiextensions.k8s.io/v1` requires every version listed in a
CRD to carry an `openAPIV3Schema` - unlike the removed `v1beta1`, where
it was optional. This isn't just a definition-time formality: once a
schema is in place, the apiserver validates every instance against it
the same way it validates a Pod's `spec.containers[].image` is a
string, rejecting anything that doesn't match before it's ever stored.

**Example**: a CRD missing `schema` entirely
(`tutorial/examples/crds/crontab-crd-no-schema.yaml`), and a `CronTab`
instance with `replicas` as a string instead of an integer
(`tutorial/examples/crds/crontab-instance-invalid.yaml`), which
violates `crontab-crd.yaml`'s schema:

```
kubectl apply -f tutorial/examples/crds/crontab-crd-no-schema.yaml
kubectl apply -f tutorial/examples/crds/crontab-instance-invalid.yaml
```

**Expected output**: both rejected outright by the apiserver, before
either object is ever stored - the missing-schema CRD fails at
definition time, the bad-type instance fails at instance-creation time
against the schema `crontab-crd.yaml` already registered:

```
$ kubectl apply -f tutorial/examples/crds/crontab-crd-no-schema.yaml
The CustomResourceDefinition "crontabs.example.com" is invalid: spec.versions[0].schema.openAPIV3Schema: Required value

$ kubectl apply -f tutorial/examples/crds/crontab-instance-invalid.yaml
The CronTab "tutorial-demo-crontab-invalid" is invalid: spec.replicas: Invalid value: "string": spec.replicas in body must be of type integer: "string"
```

Neither the malformed CRD nor the invalid instance is created - the
schema does real validation work at both layers, not just at the
apiserver's own bookkeeping level.

### Deleting a CRD cascades to every instance - and the type itself

**Why**: a CRD isn't just a template for validating instances - it's
the API type registration itself. Deleting it removes both: every
existing instance of that type is deleted along with it, and the type
stops existing at the API level entirely. `kubectl get` against it
afterward isn't an empty list (as it would be for, say, a Deployment
after the last one is deleted) - it's a genuine "the server doesn't
have a resource type" error, because the type itself is gone.

**Example**: delete the CRD registered earlier and check what's left:

```
kubectl delete crd crontabs.example.com
kubectl get crontabs
```

**Expected output**: the delete cascades away `tutorial-demo-crontab`
along with the CRD itself, and the follow-up `get` fails with a
type-level error, not an empty list:

```
$ kubectl delete crd crontabs.example.com
customresourcedefinition.apiextensions.k8s.io "crontabs.example.com" deleted

$ kubectl get crontabs
Error from server (NotFound): Unable to list "example.com/v1, Resource=crontabs": the server could not find the requested resource (get crontabs.example.com)
```

That's a `NotFound` on the resource type itself (`get crontabs.example.com`
in the error), not on any particular object - the apiserver no longer
knows what a `CronTab` is at all.
