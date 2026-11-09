# 8. Package management with Helm

Chapters 3 through 7 all used `kubectl apply -f` against one manifest
(or a small, manually-applied handful) at a time. Helm's job is
packaging and parameterizing a *whole set* of manifests - a Deployment,
a Service, a ServiceAccount, and more - as one versioned, installable,
upgradeable unit. It's covered last, deliberately: everything Helm
packages is exactly the object types the previous five chapters already
explained; there's nothing new here about what gets created, only about
how a bundle of it is templated and tracked as a single release.

### What Helm actually is: templating plus release tracking

**Why**: a Helm **chart** is a directory of Go-template YAML files plus
a `values.yaml` supplying the variables those templates reference -
`helm install` renders the templates locally into plain Kubernetes YAML,
then applies it, the same fundamental operation as `kubectl apply`
chapters 1-7 have used throughout. What Helm adds on top is a
**release**: a named, versioned record of what was installed and with
which values, stored in-cluster (as Secrets, in the release's
namespace), giving `helm upgrade`/`helm rollback`/`helm uninstall` a
concept - a whole bundle as one unit - that plain `kubectl apply` has no
equivalent for.

This is written against Helm v4 (v3 moved to security-patch-only
maintenance as of the v4 release) - chart format itself
(`apiVersion: v2` in `Chart.yaml`) is unchanged from v3, but v4 defaults
to **server-side apply** for creating/updating resources rather than a
client-side diff, which is directly checkable on anything Helm manages:

```
helm version
kubectl get deploy <a-helm-managed-deployment> -o jsonpath='{.metadata.managedFields[*].manager}{"\n"}{.metadata.managedFields[0].operation}'
```

**Expected output**:

```
version.BuildInfo{Version:"v4.2.2", ...}
```

```
helm kube-controller-manager
Apply
```

`manager: helm` with `operation: Apply` on a Deployment this session
never ran `kubectl apply` against directly is the real evidence - but
it's field-manager bookkeeping from a genuinely different mechanism
than chapter 2 covered, not the same one. Chapter 2's `kubectl apply`
is what's now called *client-side* apply (the default when you don't
pass `--server-side`): it computes its three-way merge locally and
relies on the `kubectl.kubernetes.io/last-applied-configuration`
annotation to know what was previously applied. Server-side apply moves
that computation into the apiserver itself, which tracks each field's
owning manager directly and arbitrates conflicts between managers
server-side - there's no `last-applied-configuration` annotation
involved at all (check any Helm-managed object's annotations to
confirm it's absent), because the server no longer needs a client-
stashed diff to know what changed.

A couple of smaller v4 CLI changes worth knowing so old material doesn't
read as broken: `helm fetch` was renamed to `helm pull` (`helm fetch`
still works as an alias, no error), and `--atomic` was renamed to
`--rollback-on-failure` - the old flag still functions but prints
`Flag --atomic has been deprecated, use --rollback-on-failure instead`
on every use.

One version-current caution worth stating plainly: Bitnami's free,
versioned public chart catalog (`bitnami/*`, long the default example in
most Helm tutorials) was deprecated by Broadcom starting **August 28,
2025** - most of those charts and images now require a paid subscription
or point at an unsupported `bitnamilegacy` registry. Anything written
assuming `bitnami/*` charts are freely available is already stale; this
chapter uses `helm create` to scaffold a chart locally instead, which
sidesteps depending on any third-party chart repository's continued
availability at all.

### Chart anatomy and previewing before applying

**Why**: `helm create <name>` scaffolds a standard chart layout -
`Chart.yaml` (chart metadata: name, version, `apiVersion: v2`),
`values.yaml` (the default parameters), and `templates/` (the actual Go-
template manifests, referencing values as `{{ .Values.xyz }}`). Nothing
here is Helm-specific magic beyond the templating syntax itself - the
rendered output is ordinary Kubernetes YAML, and `helm template` lets you
see exactly that rendered output *without* applying anything, a preview
step plain `kubectl apply` has no equivalent of.

**Example**: scaffold a chart and render it without installing:

```
helm create services-demo-chart
helm template services-demo services-demo-chart/
```

**Expected output**: a real chart directory, and rendered plain
Kubernetes YAML - `{{ .Values.xyz }}` already substituted, `helm
template` never touches the cluster at all:

```
Creating services-demo-chart

services-demo-chart/Chart.yaml
services-demo-chart/values.yaml
services-demo-chart/templates/deployment.yaml
services-demo-chart/templates/service.yaml
services-demo-chart/templates/serviceaccount.yaml
services-demo-chart/templates/hpa.yaml
services-demo-chart/templates/ingress.yaml
services-demo-chart/templates/NOTES.txt
services-demo-chart/templates/_helpers.tpl
services-demo-chart/templates/tests/test-connection.yaml
```

```yaml
---
# Source: services-demo-chart/templates/serviceaccount.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: services-demo-services-demo-chart
  labels:
    helm.sh/chart: services-demo-chart-0.1.0
    app.kubernetes.io/name: services-demo-chart
    app.kubernetes.io/instance: services-demo
    app.kubernetes.io/version: "1.16.0"
    app.kubernetes.io/managed-by: Helm
automountServiceAccountToken: true

---
# Source: services-demo-chart/templates/service.yaml
apiVersion: v1
kind: Service
metadata:
  name: services-demo-services-demo-chart
  ...
spec:
  type: ClusterIP
  ports:
    - port: 80
      targetPort: http
  selector:
    app.kubernetes.io/name: services-demo-chart
    app.kubernetes.io/instance: services-demo
```

Ordinary `apiVersion`/`kind`/`metadata`/`spec` (chapter 2) all the way
down - a chart is a code-generation step in front of exactly the object
types this tutorial already covers, nothing more.

### Installing and managing a release

**Why**: `helm install` both applies the rendered manifests and records
revision 1 of the release. `helm upgrade` re-renders with new values and
records the next revision - conceptually the same rolling-update
mechanism chapter 3 covered for a single Deployment, just scoped to the
whole chart's worth of objects at once. `helm rollback` reverts to a
prior revision's rendered state - but, matching the same pattern chapter
3's Deployment rollback showed, "rolling back" isn't reverting history,
it's *recording a new revision* whose content happens to match an old
one; revision numbers only ever go up.

**Example**: install, upgrade a value, then roll back:

```
helm install services-demo services-demo-chart/
helm list
kubectl get deploy -l app.kubernetes.io/instance=services-demo
helm upgrade services-demo services-demo-chart/ --set replicaCount=2
helm history services-demo
kubectl get deploy -l app.kubernetes.io/instance=services-demo
helm rollback services-demo 1
helm history services-demo
```

**Expected output**: revision 1 is installed, the Deployment shows 1
replica; upgrading to `replicaCount=2` records revision 2 and the
Deployment scales up; rolling back to "1" doesn't restore revision 1 -
it creates **revision 3**, whose rendered content matches revision 1's:

```
NAME: services-demo
...
STATUS: deployed
REVISION: 1

NAME                                Ready
services-demo-services-demo-chart   1/1     1            1           <1s

$ helm upgrade services-demo services-demo-chart/ --set replicaCount=2
Release "services-demo" has been upgraded. Happy Helming!
REVISION: 2

REVISION	STATUS    	CHART                    	DESCRIPTION
1       	superseded	services-demo-chart-0.1.0	Install complete
2       	deployed  	services-demo-chart-0.1.0	Upgrade complete

NAME                                READY   UP-TO-DATE   AVAILABLE
services-demo-services-demo-chart   1/2     2            1

$ helm rollback services-demo 1
Rollback was a success! Happy Helming!

REVISION	STATUS    	CHART                    	DESCRIPTION
1       	superseded	services-demo-chart-0.1.0	Install complete
2       	superseded	services-demo-chart-0.1.0	Upgrade complete
3       	deployed  	services-demo-chart-0.1.0	Rollback to 1

NAME                                READY   UP-TO-DATE   AVAILABLE
services-demo-services-demo-chart   1/1     1            1
```

The Deployment is back to 1 replica, but the release is on revision 3,
not 1 - exactly the append-only revision numbering chapter 3 showed for
a plain Deployment's rollout history, one layer up.

Cleanup removes every object the chart created, in one command, the same
"one unit" property that made install/upgrade convenient in the first
place:

```
helm uninstall services-demo
kubectl get deploy,svc,sa -l app.kubernetes.io/instance=services-demo
```

**Expected output**:

```
release "services-demo" uninstalled

No resources found in default namespace.
```

### A chart's Service is still just a Service

**Why**: chapter 5's reachability rules don't change because something
was installed via Helm - a `ClusterIP` Service from a chart is exactly
as unreachable from the Docker host as any other, and `port-forward` is
still the reliable path regardless of what a chart's own `NOTES.txt`
output (printed after every `helm install`/`upgrade`) recommends. Read
it rather than assume it's correct for this environment specifically -
NOTES.txt is written by whoever authored the chart, targeting whatever
environment they had in mind, which may not be a kind cluster's port-
mapping constraints.

**Example**: `services-demo-chart`'s own NOTES.txt, printed by `helm
install` above, already gets this right - it recommends `kubectl
port-forward`, not a bare URL:

```
1. Get the application URL by running these commands:
  export POD_NAME=$(kubectl get pods --namespace default -l "app.kubernetes.io/name=services-demo-chart,app.kubernetes.io/instance=services-demo" -o jsonpath="{.items[0].metadata.name}")
  export CONTAINER_PORT=$(kubectl get pod --namespace default $POD_NAME -o jsonpath="{.spec.containers[0].ports[0].containerPort}")
  echo "Visit http://127.0.0.1:8080 to use your application"
  kubectl --namespace default port-forward $POD_NAME 8080:$CONTAINER_PORT
```

**Expected output**: following that suggestion works - real nginx
content, over `port-forward`, exactly like chapter 5:

```
Forwarding from 127.0.0.1:18081 -> 80

<!DOCTYPE html>
<html>
<head>
<title>Welcome to nginx!</title>
...
```

And a direct connection attempt on the Docker host, bypassing
`port-forward`, fails exactly the way chapter 5 predicted for any
`ClusterIP` Service - Helm packaging changes none of that:

```
curl: (7) Failed to connect to localhost:18081 after 0 ms: Could not connect to server
```

### The repository model: installing someone else's published chart

**Why**: `helm create` (above) is this chapter's answer to *authoring* a
chart - it deliberately never depends on a third-party chart repository
being available, which is exactly why it was chosen after Bitnami's
catalog was deprecated. But most real Helm usage isn't authoring; it's
*consuming* a chart someone else already published and maintains. That
needs a different mechanism: `helm repo add <name> <url>` registers a
chart repository (an index the client fetches once and caches, not
anything that touches the cluster), after which `helm search repo`
searches that local cache and `helm install <release> <repo>/<chart>`
installs straight from it, without ever cloning or scaffolding
anything locally. This tutorial keeps both approaches side by side
deliberately: `helm create` for a chart you're building yourself, the
repo model for a chart someone else already built.

`helm search repo` and `helm search hub` look similar but query
different things: `search repo` only ever searches repositories you've
already `helm repo add`-ed locally, while `search hub` queries Artifact
Hub - a public index of charts across many publishers - directly over
the network, with no `repo add` step at all. `search hub` is the faster
way to *discover* a chart; `repo add` is what you need before you can
actually `helm install` one from a specific repository.

**Example**: `stefanprodan/podinfo` is used here for the same reason
`helm create` was chosen over `bitnami/*` above - it's a small,
actively-maintained, freely-available chart, not a deprecated one:

```
helm search hub podinfo
helm repo add podinfo https://stefanprodan.github.io/podinfo
helm repo list
helm search repo podinfo
```

**Expected output**: `search hub` finds it (and a second, unrelated
`podinfo` chart from a different publisher) with no local setup at all;
`repo add` registers the repository, and only then does `search repo`
find anything - it has nothing to search before that:

```
URL                                                    CHART VERSION   APP VERSION   DESCRIPTION
https://artifacthub.io/packages/helm/podinfo/podinfo   6.15.0          6.15.0        Podinfo Helm chart for Kubernetes
https://artifacthub.io/packages/helm/flagger/podinfo   6.1.4           6.1.3         Flagger canary deployment demo application

"podinfo" has been added to your repositories

NAME      URL
podinfo   https://stefanprodan.github.io/podinfo

NAME              CHART VERSION   APP VERSION   DESCRIPTION
podinfo/podinfo   6.15.0          6.15.0        Podinfo Helm chart for Kubernetes
```

Installing from the repository is the same `helm install` already used
above, just pointed at `<repo>/<chart>` instead of a local directory:

```
helm install helm-demo-podinfo podinfo/podinfo
kubectl get pods -l app.kubernetes.io/name=helm-demo-podinfo
```

**Expected output**: a real, running Pod, from a chart this session
never downloaded or unpacked by hand:

```
NAME: helm-demo-podinfo
STATUS: deployed
REVISION: 1

NAME                                  READY   STATUS    RESTARTS   AGE
helm-demo-podinfo-5cff48488c-8j5zb    1/1     Running   0          25s
```

**Repo hygiene**: `helm repo add` is a purely local, client-side
registration - it doesn't touch the cluster, and a stale entry left
behind is silent clutter, not a running risk, but a one-off repository
added for a single chart is worth removing once you're done rather than
letting the local cache accumulate repos that are never searched again:

```
helm uninstall helm-demo-podinfo
helm repo remove podinfo
helm repo list
```

**Expected output**:

```
release "helm-demo-podinfo" uninstalled
"podinfo" has been removed from your repositories
no repositories to show
```
