# Kubernetes + kind Cheat Sheet

Everyday commands only. For this repo, cluster name is `k8s-lab-<PROFILE>` and the kubectl context is `kind-k8s-lab-<PROFILE>`.

## Contents

- [This repo (make)](#this-repo-make)
- [kind](#kind)
- [kubectl basics](#kubectl-basics)
- [Contexts and namespaces](#contexts-and-namespaces)
- [Creating and changing resources](#creating-and-changing-resources)
- [Inspecting and debugging](#inspecting-and-debugging)
- [Deployments and rollouts](#deployments-and-rollouts)
- [Services and networking](#services-and-networking)
- [Config and secrets](#config-and-secrets)
- [Storage](#storage)
- [Nodes and scheduling](#nodes-and-scheduling)
- [RBAC](#rbac)
- [Helm](#helm)
- [Output formatting and filtering](#output-formatting-and-filtering)
- [Handy patterns](#handy-patterns)

---

## This repo (make)

`PROFILE` selects `kind/profiles/<PROFILE>/` and defaults to `default`. Cluster name is `k8s-lab-<PROFILE>` and the kubectl context is `kind-k8s-lab-<PROFILE>`. Only one ingress-enabled profile can run at a time (host ports 80/443). See the [README](../README.md#makefile-targets) for the full picture.

| Target                       | Action | If `PROFILE` is omitted |
|-------------------------------|--------|--------------------------|
| `make up PROFILE=x`           | `kind create cluster` with the profile's `cluster.yaml`, then `kubectl apply -f` each path in `manifests.txt`, in order | Uses `default` |
| `make down PROFILE=x`         | `kind delete cluster` for that profile | Uses `default` |
| `make reset PROFILE=x`        | `down` then `up` | Uses `default` |
| `make list-profiles`          | List `kind/profiles/*` | n/a |
| `make kubeconfig PROFILE=x`   | `kind export kubeconfig` for that profile | Uses `default` |
| `make status PROFILE=x`       | `kubectl get nodes -o wide` and `get pods -A` against that profile's context | Auto-detects the running profile (errors if none, or if several are up) |

```bash
make up                          # default profile
make up PROFILE=ha-control-plane
make status                      # auto-detects the single running cluster
make down PROFILE=ha-control-plane
```

### NFS helper (PV/PVC exercise)

Standalone NFS server container on the `kind` Docker network, not tied to any cluster's lifecycle.

| Target                              | Action |
|--------------------------------------|--------|
| `make nfs-up`                        | Start the NFS server container (idempotent; needs a kind cluster already up, any profile) |
| `make nfs-down`                      | Stop and remove it (`lab-helpers/nfs-server/data/` persists) |
| `make nfs-status`                    | Show container status and, if `showmount` is installed, try to list exports (empty is expected: NFSv4-only image) |
| `make nfs-client-install PROFILE=x`  | Install `nfs-common` into every node of that profile (idempotent; re-run after nodes are recreated) |

### Local registry helper (tutorial chapter 13)

One `registry:3` container shared across profiles, published on `localhost:5001`.

| Target                                   | Action |
|-------------------------------------------|--------|
| `make registry-up`                        | Start the registry container (idempotent; no cluster needed yet) |
| `make registry-down`                      | Stop and remove it (`lab-helpers/registry/data/` persists) |
| `make registry-status`                    | Show container status and list pushed repositories |
| `make registry-client-install PROFILE=x`  | Wire containerd on every node of that profile to pull from `localhost:5001/<image>` (re-run after nodes are recreated) |

Requires the containerd `config_path` patch in `cluster.yaml`, which can't be added after the cluster is created.

```bash
make registry-up
make registry-client-install                       # once per cluster
docker build -t localhost:5001/myapp:v1 .
docker push localhost:5001/myapp:v1
kubectl create deploy myapp --image=localhost:5001/myapp:v1
```

---

## kind

```bash
kind create cluster --name NAME --config cluster.yaml   # create from config
kind get clusters                                       # list clusters
kind get nodes --name NAME                              # list node containers
kind delete cluster --name NAME                         # delete one cluster
kind delete clusters --all                              # delete all clusters
kind export kubeconfig --name NAME                      # write/refresh kubeconfig entry
kind export logs ./logs --name NAME                     # dump all cluster logs
kind load docker-image IMG:TAG --name NAME              # side-load a local image into nodes
kind load image-archive img.tar --name NAME             # load from tarball
kind version
```

Nodes are Docker containers, so Docker commands work on them:

```bash
docker ps --filter name=k8s-lab                         # see node containers
docker exec -it NAME-control-plane bash                 # shell into a node
docker exec NAME-control-plane crictl ps                # containers inside a node
docker exec NAME-control-plane crictl images            # images inside a node
```

---

## kubectl basics

```bash
kubectl get <resource>                  # list
kubectl get <resource> NAME             # one item
kubectl get <resource> -o wide          # extra columns (node, IP)
kubectl get <resource> -w               # watch for changes
kubectl get all                         # common workload types in namespace
kubectl get pods -A                     # all namespaces
kubectl get pods -n NS                  # specific namespace
kubectl get pods -l app=web             # by label
kubectl get pods --show-labels
kubectl describe <resource> NAME        # details + events (first stop for debugging)
kubectl api-resources                   # all resource types, short names, scope
kubectl explain pod.spec.containers     # built-in field docs
kubectl explain deploy --recursive      # full field tree
```

Common short names: `po` pods, `deploy` deployments, `rs` replicasets, `svc` services, `ds` daemonsets, `sts` statefulsets, `cm` configmaps, `pv`/`pvc` volumes/claims, `ns` namespaces, `no` nodes, `ing` ingresses, `sa` serviceaccounts.

---

## Contexts and namespaces

```bash
kubectl config get-contexts                              # list contexts
kubectl config current-context
kubectl config use-context kind-k8s-lab-default          # switch cluster
kubectl config set-context --current --namespace=NS      # default namespace for this context
kubectl get ns
kubectl create ns NS
kubectl delete ns NS                                     # deletes everything inside it
kubectl cluster-info
```

---

## Creating and changing resources

```bash
kubectl apply -f file.yaml              # create or update (declarative)
kubectl apply -f dir/                   # all files in a directory
kubectl apply -f https://url/file.yaml
kubectl diff -f file.yaml               # preview what apply would change
kubectl delete -f file.yaml
kubectl delete <resource> NAME
kubectl delete pod -l app=web           # by label
kubectl replace --force -f file.yaml    # delete + recreate (use when apply can't change a field)
kubectl edit <resource> NAME            # edit live object in $EDITOR
kubectl patch deploy NAME -p '{"spec":{"replicas":3}}'
kubectl label pod NAME env=dev          # add label (--overwrite to change, `env-` to remove)
kubectl annotate pod NAME note="hi"
```

Imperative creation (quick one-offs, and for generating YAML):

```bash
kubectl run web --image=nginx                            # single pod
kubectl create deploy web --image=nginx --replicas=2
kubectl expose deploy web --port=80 --target-port=80     # create a Service
kubectl scale deploy web --replicas=5
kubectl set image deploy/web nginx=nginx:1.27            # update container image

# Generate YAML without creating anything
kubectl create deploy web --image=nginx --dry-run=client -o yaml > web.yaml
kubectl run web --image=nginx --dry-run=client -o yaml > pod.yaml
```

---

## Inspecting and debugging

```bash
kubectl logs POD                        # container logs
kubectl logs POD -c CONTAINER           # specific container in multi-container pod
kubectl logs POD -f                     # follow
kubectl logs POD --previous             # logs from the last crashed container
kubectl logs -l app=web --tail=50       # by label
kubectl logs deploy/web                 # pick a pod from the deployment

kubectl exec -it POD -- sh              # shell in pod
kubectl exec POD -- ls /app             # one-off command
kubectl exec -it POD -c CONTAINER -- sh

kubectl port-forward pod/POD 8080:80    # localhost:8080 -> pod:80
kubectl port-forward svc/web 8080:80    # through a Service
kubectl cp POD:/path/file ./file        # copy out (and `./file POD:/path` to copy in)

kubectl get events --sort-by=.lastTimestamp
kubectl get events -n NS --field-selector type=Warning

kubectl top nodes                       # needs metrics-server
kubectl top pods -A --sort-by=memory

# Throwaway debug pod
kubectl run tmp --rm -it --image=busybox --restart=Never -- sh
kubectl run tmp --rm -it --image=curlimages/curl --restart=Never -- curl -s http://web
kubectl debug -it POD --image=busybox --target=CONTAINER   # ephemeral container in a live pod
```

Typical pod-status meanings:

| Status | Usual cause | Where to look |
|---|---|---|
| `Pending` | Not scheduled (resources, taints, nodeSelector, unbound PVC) | `describe pod` -> Events |
| `ImagePullBackOff` / `ErrImagePull` | Wrong image name/tag, or registry auth | `describe pod` -> Events |
| `CrashLoopBackOff` | Container exits repeatedly | `logs --previous` |
| `CreateContainerConfigError` | Missing ConfigMap/Secret/key | `describe pod` |
| `OOMKilled` (in describe) | Exceeded memory limit | raise limit / fix leak |
| `Running` but not Ready | Readiness probe failing | `describe pod`, check probe |

---

## Deployments and rollouts

```bash
kubectl rollout status deploy/web
kubectl rollout history deploy/web
kubectl rollout undo deploy/web                    # back one revision
kubectl rollout undo deploy/web --to-revision=2
kubectl rollout restart deploy/web                 # rolling restart (e.g. to pick up new config)
kubectl rollout pause deploy/web                   # and `resume`
kubectl scale deploy/web --replicas=3
kubectl autoscale deploy/web --min=2 --max=6 --cpu-percent=70   # creates an HPA
kubectl get hpa
```

---

## Services and networking

```bash
kubectl get svc
kubectl get endpoints web                          # which pod IPs back the Service (empty = selector mismatch)
kubectl get endpointslices
kubectl get ing                                    # ingresses
kubectl describe ing NAME
kubectl get networkpolicy

# DNS check from inside the cluster
kubectl run tmp --rm -it --image=busybox --restart=Never -- nslookup web.default.svc.cluster.local
```

Service DNS: `<svc>.<namespace>.svc.cluster.local` (just `<svc>` works inside the same namespace).

Service types: `ClusterIP` (in-cluster only, default), `NodePort` (opens a port on every node), `LoadBalancer` (needs a cloud/LB controller; stays `<pending>` on plain kind).

---

## Config and secrets

```bash
kubectl create cm app-cfg --from-literal=KEY=value
kubectl create cm app-cfg --from-file=config.properties
kubectl create secret generic db --from-literal=password=s3cret
kubectl create secret tls tls-cert --cert=tls.crt --key=tls.key
kubectl get secret db -o jsonpath='{.data.password}' | base64 -d
kubectl get cm app-cfg -o yaml
```

---

## Storage

```bash
kubectl get pv
kubectl get pvc
kubectl get storageclass                           # `sc`; kind ships `standard` (local-path)
kubectl describe pvc NAME                          # Pending? Events say why
```

---

## Nodes and scheduling

```bash
kubectl get nodes -o wide
kubectl describe node NAME                         # capacity, allocated resources, taints, conditions
kubectl label node NAME disktype=ssd               # then use nodeSelector in pod spec
kubectl cordon NAME                                # stop new pods landing here
kubectl uncordon NAME
kubectl drain NAME --ignore-daemonsets --delete-emptydir-data   # evict pods + cordon
kubectl taint nodes NAME key=value:NoSchedule      # add taint (`key=value:NoSchedule-` to remove)
kubectl get pods -A -o wide --field-selector spec.nodeName=NAME # what's running on a node
```

---

## RBAC

```bash
kubectl get sa                                     # service accounts
kubectl create sa NAME
kubectl create role pod-reader --verb=get,list,watch --resource=pods
kubectl create rolebinding rb --role=pod-reader --serviceaccount=default:NAME
kubectl create clusterrole ...                     # same flags as role
kubectl create clusterrolebinding ...
kubectl auth can-i list pods                       # for yourself
kubectl auth can-i list pods --as=system:serviceaccount:default:NAME
kubectl auth can-i --list                          # everything you can do
```

---

## Helm

Helm installs a packaged app (a *chart*) as a named *release*. It uses the same kubeconfig and context as kubectl, and `-n NS` works the same way.

```bash
# Repositories
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update                                   # refresh chart index
helm repo list
helm search repo nginx                             # search added repos
helm search repo nginx --versions                  # all available chart versions
helm search hub nginx                              # search Artifact Hub

# Inspect a chart before installing
helm show values bitnami/nginx                     # default values (what you can override)
helm show chart bitnami/nginx
helm show readme bitnami/nginx

# Install
helm install web bitnami/nginx                     # release "web" from chart
helm install web bitnami/nginx -n NS --create-namespace
helm install web bitnami/nginx --version 18.2.0    # pin chart version
helm install web bitnami/nginx --set replicaCount=2
helm install web bitnami/nginx -f my-values.yaml   # values file (repeatable, last wins)
helm install web ./mychart                         # from a local chart directory
helm install web bitnami/nginx --dry-run --debug   # render and show, don't install

# Inspect releases
helm list                                          # current namespace (-A for all)
helm status web
helm get values web                                # values you supplied (--all for computed)
helm get manifest web                              # rendered YAML that was applied
helm history web

# Upgrade, roll back, remove
helm upgrade web bitnami/nginx --set replicaCount=3
helm upgrade --install web bitnami/nginx -f my-values.yaml   # idempotent: install or upgrade
helm upgrade web bitnami/nginx --reuse-values --set x=y      # keep earlier values, change one
helm rollback web 1                                # back to revision 1
helm uninstall web

# Authoring and debugging charts
helm create mychart                                # scaffold a new chart
helm lint ./mychart
helm template web ./mychart -f my-values.yaml      # render locally, no cluster needed
helm package ./mychart
```

Notes:

- `--set` overrides are lost on the next `helm upgrade` unless you pass them again, use `-f`, or add `--reuse-values`. A values file kept in git is the reliable way.
- Prefer `helm upgrade --install` in scripts so the same command works on first run and re-runs.
- `helm template ... | kubectl apply -f -` and `helm get manifest` are useful for seeing exactly what a chart creates.
- This repo applies plain manifests instead of Helm charts (see DESIGN.md), so Helm here is for trying out third-party charts on a lab cluster.

---

## Output formatting and filtering

```bash
kubectl get pod NAME -o yaml                       # full object
kubectl get pod NAME -o json
kubectl get pods -o name                           # just pod/NAME lines
kubectl get pods -o jsonpath='{.items[*].metadata.name}'
kubectl get pods -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.phase}{"\n"}{end}'
kubectl get pods -o custom-columns=NAME:.metadata.name,NODE:.spec.nodeName,IP:.status.podIP
kubectl get pods --sort-by=.metadata.creationTimestamp
kubectl get pods --field-selector status.phase=Running
kubectl get pods --field-selector status.phase!=Running -A    # find unhealthy pods
```

---

## Handy patterns

```bash
# Wait for something instead of polling by hand
kubectl wait --for=condition=Ready pod -l app=web --timeout=120s
kubectl wait --for=condition=Available deploy/web --timeout=120s

# Which image is a deployment running?
kubectl get deploy web -o jsonpath='{.spec.template.spec.containers[*].image}'

# Everything in a namespace, including less common types
kubectl api-resources --verbs=list --namespaced -o name | xargs -n1 kubectl get -n NS --ignore-not-found

# Force-delete a stuck pod (last resort)
kubectl delete pod NAME --grace-period=0 --force

# Shell aliases worth having
alias k=kubectl
source <(kubectl completion bash) && complete -o default -F __start_kubectl k
```
