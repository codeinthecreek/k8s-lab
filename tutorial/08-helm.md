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

This chapter uses Helm v4:

```
helm version
```

```
version.BuildInfo{Version:"v4.3.0", GitCommit:"bec5b06ed841fe5269972d864d5177944fd5970f", GitTreeState:"", GoVersion:"go1.27.1-X:nodwarf5", KubeClientVersion:"v1.37"}
```

Charts haven't changed since v3 (`apiVersion: v2` in `Chart.yaml`). Two
smaller v4 changes, in case you see the old names elsewhere: `helm
fetch` is now `helm pull` (the old name still works), and `--atomic` is
now `--rollback-on-failure` (the old flag still works but prints `Flag
--atomic has been deprecated, use --rollback-on-failure instead`). The
bigger change, server-side apply, is shown after the first install
below.

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

**Example**: create a chart in the current directory and list its
files:

```
helm create services-demo-chart
find services-demo-chart | sort
```

**Expected output**:

```
Creating services-demo-chart
services-demo-chart
services-demo-chart/charts
services-demo-chart/Chart.yaml
services-demo-chart/.helmignore
services-demo-chart/templates
services-demo-chart/templates/deployment.yaml
services-demo-chart/templates/_helpers.tpl
services-demo-chart/templates/hpa.yaml
services-demo-chart/templates/httproute.yaml
services-demo-chart/templates/ingress.yaml
services-demo-chart/templates/NOTES.txt
services-demo-chart/templates/serviceaccount.yaml
services-demo-chart/templates/service.yaml
services-demo-chart/templates/tests
services-demo-chart/templates/tests/test-connection.yaml
services-demo-chart/values.yaml
```

Now fill in the templates without installing anything. The full output
is long, one document per object, so `--show-only` picks just the
Service:

```
helm template services-demo services-demo-chart/ --show-only templates/service.yaml
```

**Expected output**: plain Kubernetes YAML with every placeholder
filled in. `helm template` doesn't contact the cluster:

```yaml
---
# Source: services-demo-chart/templates/service.yaml
apiVersion: v1
kind: Service
metadata:
  name: services-demo-services-demo-chart
  labels:
    helm.sh/chart: services-demo-chart-0.1.0
    app.kubernetes.io/name: services-demo-chart
    app.kubernetes.io/instance: services-demo
    app.kubernetes.io/version: "1.16.0"
    app.kubernetes.io/managed-by: Helm
spec:
  type: ClusterIP
  ports:
    - port: 80
      targetPort: http
      protocol: TCP
      name: http
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

**Example**: install the chart as a release called `services-demo`,
then list releases:

```
helm install services-demo services-demo-chart/
helm list
```

**Expected output**: the release is at revision 1. `helm install` ends
by printing the chart's `NOTES.txt`, which the next section uses:

```
NAME: services-demo
LAST DEPLOYED: Thu Nov 19 11:23:28 2026
NAMESPACE: default
STATUS: deployed
REVISION: 1
DESCRIPTION: Install complete
NOTES:
1. Get the application URL by running these commands:
  export POD_NAME=$(kubectl get pods --namespace default -l "app.kubernetes.io/name=services-demo-chart,app.kubernetes.io/instance=services-demo" -o jsonpath="{.items[0].metadata.name}")
  export CONTAINER_PORT=$(kubectl get pod --namespace default $POD_NAME -o jsonpath="{.spec.containers[0].ports[0].containerPort}")
  echo "Visit http://127.0.0.1:8080 to use your application"
  kubectl --namespace default port-forward $POD_NAME 8080:$CONTAINER_PORT
NAME         	NAMESPACE	REVISION	UPDATED                                	STATUS  	CHART                    	APP VERSION
services-demo	default  	1       	2026-11-19 11:23:28.860025401 +0000 UTC	deployed	services-demo-chart-0.1.0	1.16.0
```

The chart's Deployment has 1 replica. Once its image is pulled:

```
kubectl get deploy -l app.kubernetes.io/instance=services-demo
```

```
NAME                                READY   UP-TO-DATE   AVAILABLE   AGE
services-demo-services-demo-chart   1/1     1            1           34s
```

**Server-side apply**: every object records which programs (**field
managers**) set its fields, and how. Look at the Deployment's:

```
kubectl get deploy services-demo-services-demo-chart -o jsonpath='{range .metadata.managedFields[*]}{.manager}{" "}{.operation}{"\n"}{end}'
```

```
helm Apply
kube-controller-manager Update
```

`helm` set the fields with the operation `Apply`, which means
server-side apply, Helm v4's default. (`kube-controller-manager` updated
the Deployment's status.)

Chapter 2's `kubectl apply` is *client-side* apply (the default unless
you pass `--server-side`). `kubectl` works out the changes itself, and
stores the configuration it applied in the
`kubectl.kubernetes.io/last-applied-configuration` annotation so it can
compare next time. With server-side apply, the API server does that
work instead. It records which manager owns each field and settles
conflicts between managers. No annotation is needed, so objects that
Helm manages don't have one.

Now upgrade the release with a different value, look at its history,
and check the Deployment:

```
helm upgrade services-demo services-demo-chart/ --set replicaCount=2
helm history services-demo
kubectl get deploy -l app.kubernetes.io/instance=services-demo
```

**Expected output**: the upgrade is revision 2, and the Deployment now
wants 2 replicas. Here the second Pod was still starting:

```
Release "services-demo" has been upgraded. Happy Helming!
NAME: services-demo
LAST DEPLOYED: Thu Nov 19 11:24:12 2026
NAMESPACE: default
STATUS: deployed
REVISION: 2
...
REVISION	UPDATED                 	STATUS    	CHART                    	APP VERSION	DESCRIPTION
1       	Thu Nov 19 11:23:28 2026	superseded	services-demo-chart-0.1.0	1.16.0     	Install complete
2       	Thu Nov 19 11:24:12 2026	deployed  	services-demo-chart-0.1.0	1.16.0     	Upgrade complete
NAME                                READY   UP-TO-DATE   AVAILABLE   AGE
services-demo-services-demo-chart   1/2     2            1           52s
```

(`...` stands for the `NOTES.txt` text, printed again after every
upgrade.) Now roll back to revision 1:

```
helm rollback services-demo 1
helm history services-demo
kubectl get deploy -l app.kubernetes.io/instance=services-demo
```

**Expected output**: rolling back to 1 creates **revision 3**, with the
same content as revision 1, and the Deployment is back to 1 replica:

```
Rollback was a success! Happy Helming!
REVISION	UPDATED                 	STATUS    	CHART                    	APP VERSION	DESCRIPTION
1       	Thu Nov 19 11:23:28 2026	superseded	services-demo-chart-0.1.0	1.16.0     	Install complete
2       	Thu Nov 19 11:24:12 2026	superseded	services-demo-chart-0.1.0	1.16.0     	Upgrade complete
3       	Thu Nov 19 11:24:21 2026	deployed  	services-demo-chart-0.1.0	1.16.0     	Rollback to 1
NAME                                READY   UP-TO-DATE   AVAILABLE   AGE
services-demo-services-demo-chart   1/1     1            1           58s
```

The release is at revision 3, not 1. It's the same numbering you saw
for a Deployment's rollout history in chapter 3, one level up.

### A chart's Service is still just a Service

**Why**: a Service installed by Helm follows the same rules as any other
(chapter 5). A `ClusterIP` Service can't be reached from your host, and
`kubectl port-forward` is the reliable way in. The chart's `NOTES.txt`
usually explains how to reach the application. The chart's author wrote
it for whatever environment they had in mind, so read it, but check
that it suits a kind cluster.

**Example**: the `NOTES.txt` that `helm create` generates, printed by
`helm install` above, gets this right: it suggests `kubectl
port-forward`, not a URL. Run its commands, with `&` to keep the
port-forward running in the background, then fetch the page:

```
export POD_NAME=$(kubectl get pods --namespace default -l "app.kubernetes.io/name=services-demo-chart,app.kubernetes.io/instance=services-demo" -o jsonpath="{.items[0].metadata.name}")
export CONTAINER_PORT=$(kubectl get pod --namespace default $POD_NAME -o jsonpath="{.spec.containers[0].ports[0].containerPort}")
kubectl --namespace default port-forward $POD_NAME 8080:$CONTAINER_PORT &
curl -sS http://127.0.0.1:8080 | head -4
kill %1
```

**Expected output**: nginx answers through the port-forward, as in
chapter 5:

```
Forwarding from 127.0.0.1:8080 -> 80
Forwarding from [::1]:8080 -> 80
Handling connection for 8080
<!DOCTYPE html>
<html>
<head>
<title>Welcome to nginx!</title>
```

Without the port-forward, the Service can't be reached from your host.
Try the `CLUSTER-IP` that `kubectl get svc` shows:

```
kubectl get svc services-demo-services-demo-chart
curl -sS -m 5 http://<CLUSTER-IP>
```

**Expected output**: `curl` gives up after 5 seconds (`-m 5`), as
chapter 5 showed for any `ClusterIP` Service:

```
NAME                                TYPE        CLUSTER-IP     EXTERNAL-IP   PORT(S)   AGE
services-demo-services-demo-chart   ClusterIP   10.96.72.172   <none>        80/TCP    18s
curl: (28) Connection timed out after 5001 milliseconds
```

### Removing a release

`helm uninstall` removes every object the chart created, in one
command. The chart directory is only on your machine; delete it too:

```
helm uninstall services-demo
kubectl get deploy,svc,sa -l app.kubernetes.io/instance=services-demo
rm -r services-demo-chart
```

**Expected output**:

```
release "services-demo" uninstalled
No resources found in default namespace.
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
helm search repo podinfo
helm repo add podinfo https://stefanprodan.github.io/podinfo
helm repo list
helm search repo podinfo
```

**Expected output**: `search hub` finds two charts called `podinfo`,
from different publishers (it shortens long URLs). `search repo` finds
nothing until you've added a repository; afterwards it finds the chart
in the one you added:

```
URL                                               	CHART VERSION	APP VERSION	DESCRIPTION
https://artifacthub.io/packages/helm/podinfo/po...	6.17.0       	6.17.0     	Podinfo Helm chart for Kubernetes
https://artifacthub.io/packages/helm/flagger/po...	6.1.4        	6.1.3      	Flagger canary deployment demo application
Error: no repositories configured
"podinfo" has been added to your repositories
NAME   	URL
podinfo	https://stefanprodan.github.io/podinfo
NAME           	CHART VERSION	APP VERSION	DESCRIPTION
podinfo/podinfo	6.17.0       	6.17.0     	Podinfo Helm chart for Kubernetes
```

If you've added other repositories before, the first `search repo`
searches those instead of printing the error.

Installing from a repository uses the same `helm install`, with
`<repo>/<chart>` instead of a local directory:

```
helm install helm-demo-podinfo podinfo/podinfo
```

```
NAME: helm-demo-podinfo
LAST DEPLOYED: Thu Nov 19 11:24:46 2026
NAMESPACE: default
STATUS: deployed
REVISION: 1
DESCRIPTION: Install complete
...
```

When the image has been pulled, which took about 3 minutes here:

```
kubectl get pods -l app.kubernetes.io/name=helm-demo-podinfo
```

**Expected output**: a running Pod, from a chart you never downloaded
yourself:

```
NAME                                 READY   STATUS    RESTARTS   AGE
helm-demo-podinfo-84f9d5874f-bh74j   1/1     Running   0          3m1s
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
