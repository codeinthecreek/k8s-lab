# 8. Package management with Helm

Chapters 3 to 7 applied manifests one at a time with `kubectl apply -f`.
A real application usually needs several objects together: a
Deployment, a Service, a ServiceAccount and more. **Helm** packages a
set like that as one unit that you can install, configure, upgrade and
remove in one step. Helm creates nothing new: everything it installs
is an object type from the earlier chapters. What's new is how the set
is generated from templates and tracked as a whole.

### What Helm is: templates plus release tracking

**Why**: a Helm **chart** is a directory of YAML templates, plus a
`values.yaml` file with the settings the templates use. `helm install`
fills in the templates to produce ordinary Kubernetes YAML and applies
it to the cluster, much as `kubectl apply` would.

What Helm adds is the **release**: a named record of what was installed
from which chart, with which values. Helm stores it in the cluster, as
Secrets in the release's namespace. Because of it, you can upgrade, roll
back or uninstall the whole set as one unit with `helm upgrade`,
`helm rollback` and `helm uninstall`. Plain `kubectl apply` has nothing
like that.

This chapter uses Helm v4. Charts themselves haven't changed since v3
(`apiVersion: v2` in `Chart.yaml`), but v4 applies objects with
**server-side apply** by default. You can see that on any object Helm
manages:

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

Every object records which programs (field managers) set its fields.
Here `helm` set them with the operation `Apply`, which means server-side
apply.

Chapter 2's `kubectl apply` is *client-side* apply (the default unless
you pass `--server-side`). `kubectl` works out the changes itself, and
stores the configuration it applied in the
`kubectl.kubernetes.io/last-applied-configuration` annotation so it can
compare next time. With server-side apply, the API server does that
work instead. It records which manager owns each field and settles
conflicts between managers. No annotation is needed, so objects that
Helm manages don't have one.

Two smaller v4 changes, in case you see the old names elsewhere:
`helm fetch` is now `helm pull` (the old name still works), and
`--atomic` is now `--rollback-on-failure` (the old flag still works but
prints `Flag --atomic has been deprecated, use --rollback-on-failure
instead`).

Many Helm tutorials use Bitnami's charts (`bitnami/*`) as examples.
Since **August 28, 2025**, most of those charts and images need a paid
subscription, or point at an unsupported `bitnamilegacy` registry, so
those examples may no longer work. This chapter creates its own chart
with `helm create` instead, so it doesn't depend on anyone else's chart
repository.

### Chart anatomy and previewing before applying

**Why**: `helm create <name>` creates a starter chart with the standard
layout:

- `Chart.yaml`: the chart's name, version and `apiVersion: v2`.
- `values.yaml`: the default settings.
- `templates/`: the manifests, with placeholders such as
  `{{ .Values.replicaCount }}` that are filled in from the values.

`helm template` fills in the templates and prints the result without
applying anything, so you can see exactly what would be created.
`kubectl apply` has no equivalent preview.

**Example**: scaffold a chart and render it without installing:

```
helm create services-demo-chart
helm template services-demo services-demo-chart/
```

**Expected output**: the chart's files, then plain Kubernetes YAML with
every placeholder filled in. `helm template` doesn't contact the
cluster:

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

It's the same `apiVersion`, `kind`, `metadata` and `spec` as in
chapter 2. A chart is a way of generating the objects you already know,
nothing more.

### Installing and managing a release

**Why**: `helm install` applies the generated manifests and records
them as revision 1 of the release. `helm upgrade` generates them again
with new values and records revision 2, and so on. `helm rollback`
returns to an earlier revision's manifests. As with a Deployment's
rollback in chapter 3, it doesn't go back in history: it records a
*new* revision with the old content. Revision numbers only go up.

**Example**: install the chart, upgrade it with a different value, then
roll back:

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

**Expected output**: the install is revision 1, with 1 replica. The
upgrade to `replicaCount=2` is revision 2, and the Deployment scales to
2. Rolling back to 1 creates **revision 3**, with the same content as
revision 1:

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

The Deployment is back to 1 replica, and the release is at revision 3,
not 1. It's the same numbering you saw for a Deployment's rollout
history in chapter 3, one level up.

`helm uninstall` removes every object the chart created, in one
command:

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

**Why**: a Service installed by Helm follows the same rules as any other
(chapter 5). A `ClusterIP` Service can't be reached from your host, and
`kubectl port-forward` is the reliable way in. After every install and
upgrade, Helm prints the chart's `NOTES.txt`, usually with instructions
for reaching the application. The chart's author wrote them for
whatever environment they had in mind, so read them, but check that
they suit a kind cluster.

**Example**: the `NOTES.txt` that `helm create` generates, printed by
`helm install` above, gets this right. It suggests `kubectl
port-forward`, not a URL:

```
1. Get the application URL by running these commands:
  export POD_NAME=$(kubectl get pods --namespace default -l "app.kubernetes.io/name=services-demo-chart,app.kubernetes.io/instance=services-demo" -o jsonpath="{.items[0].metadata.name}")
  export CONTAINER_PORT=$(kubectl get pod --namespace default $POD_NAME -o jsonpath="{.spec.containers[0].ports[0].containerPort}")
  echo "Visit http://127.0.0.1:8080 to use your application"
  kubectl --namespace default port-forward $POD_NAME 8080:$CONTAINER_PORT
```

**Expected output**: following it works, and nginx answers through
`port-forward`, as in chapter 5:

```
Forwarding from 127.0.0.1:18081 -> 80

<!DOCTYPE html>
<html>
<head>
<title>Welcome to nginx!</title>
...
```

Connecting directly from the host, without `port-forward`, fails, as
chapter 5 showed for any `ClusterIP` Service:

```
curl: (7) Failed to connect to localhost:18081 after 0 ms: Could not connect to server
```

### Installing a published chart from a repository

**Why**: `helm create` is for writing your own chart. More often you'll
install a chart that someone else publishes and maintains. Charts are
published in **chart repositories**. `helm repo add <name> <url>`
registers one with your Helm client: Helm downloads the repository's
index and keeps a local copy. That happens only on your machine, not in
the cluster. After that, `helm search repo` searches the indexes you've
added, and `helm install <release> <repo>/<chart>` installs a chart
straight from the repository.

`helm search hub` is different from `helm search repo`. It searches
**Artifact Hub**, a public website that lists charts from many
publishers, with no `repo add` needed. Use `search hub` to find a chart,
then `repo add` its repository so you can install from it.

**Example**: `podinfo`, a small, actively maintained chart that's free
to use:

```
helm search hub podinfo
helm repo add podinfo https://stefanprodan.github.io/podinfo
helm repo list
helm search repo podinfo
```

**Expected output**: `search hub` finds two charts called `podinfo`,
from different publishers. After `repo add`, `search repo` finds the
one from the repository you added; before it, it would find
nothing:

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

Installing from a repository uses the same `helm install`, with
`<repo>/<chart>` instead of a local directory:

```
helm install helm-demo-podinfo podinfo/podinfo
kubectl get pods -l app.kubernetes.io/name=helm-demo-podinfo
```

**Expected output**: a running Pod, from a chart you never downloaded
yourself:

```
NAME: helm-demo-podinfo
STATUS: deployed
REVISION: 1

NAME                                  READY   STATUS    RESTARTS   AGE
helm-demo-podinfo-5cff48488c-8j5zb    1/1     Running   0          25s
```

**Removing the repository**: a repository you added only affects your
own Helm client, so leaving it registered does no harm. Still, when you
added one for a single chart, remove it once you're done:

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
