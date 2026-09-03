# Kubernetes tutorial

A from-scratch, concept-first Kubernetes tutorial. It's written for
anyone with `kind` and `kubectl` installed, and uses this repo's own
profiles (`default`, `ha-control-plane`, `calico`) and manifests as its
working examples.

**Chapter order follows concept dependency.** The numeric filename
prefix (`01-`, `02-`, ...) is reading order only. See DESIGN.md's
"Tutorial content: structure and conventions" section for the full
reasoning behind this and every other convention this tutorial follows.

Written and verified against: **Kubernetes v1.36.1** (kind server
version, `default` profile, `kindest/node:v1.36.1`), captured via
`kubectl version`. Chapters using `ha-control-plane` or `calico` note
that explicitly where relevant. Version-specific behavior is flagged
inline per-chapter rather than assumed to hold indefinitely - see
DESIGN.md.

## Chapters

| # | Title | Scope | Status |
|---|-------|-------|--------|
| 1 | [Cluster architecture](01-architecture.md) | Control plane / worker split, what each component does, how kind's node-as-container model maps onto it. No YAML - conceptual foundation only. | verified against live cluster |
| 2 | [The API model](02-api-model.md) | Declarative desired-state model, apiVersion/kind/metadata/spec, kubectl as an API client, what `apply` actually does (diff + PATCH, not blind create). First chapter with a YAML example. | verified against live cluster |
| 3 | [Pods and workloads](03-workloads.md) | Pod as the atomic unit, then ReplicaSet -> Deployment, rolling updates, why you almost never create a bare Pod. | verified against live cluster |
| 4 | [Configuration and storage](04-config-storage.md) | ConfigMaps/Secrets, Volumes, PV/PVC static binding, StorageClass. Placed after workloads - none of this means anything without a Pod to attach it to. | verified against live cluster |
| 5 | [Services and networking](05-services-networking.md) | ClusterIP/NodePort/LoadBalancer, CoreDNS service discovery, Ingress as L7 routing on top of Services. | verified against live cluster |
| 6 | [Specialized workloads](06-specialized-workloads.md) | Workload shapes that deliberately break from the interchangeable-replica model: StatefulSet (stable identity, per-replica storage) and a "workloads that run to completion" subsection on Job and CronJob. | verified against live cluster |
| 7 | [Scheduling and resource management](07-scheduling.md) | Labels/selectors, node affinity, pod affinity/anti-affinity, taints/tolerations, resource requests/limits, and namespace-level governance via ResourceQuota (compute and storage dimensions)/LimitRange. | verified against live cluster |
| 8 | [Package management with Helm](08-helm.md) | Templating/release management for patterns already taught in chapters 3-7, via both `helm create` scaffolding and the `helm repo add`/published-chart model. Deliberately not covered earlier. | verified against live cluster |
| 9 | [Security](09-security.md) | ServiceAccounts, RBAC (Role/RoleBinding and ClusterRole/ClusterRoleBinding, including binding a ClusterRole via a namespaced RoleBinding), x509 client-certificate authentication (CN/O mapping, curling the API with --cert/--key/--cacert), kubectl proxy as an RBAC-vs-connectivity diagnostic, admission control (Pod Security Admission, plus an aside on admission-plugin flags vs compiled-in defaults), and NetworkPolicy. NetworkPolicy depends on chapter 5's networking model and covers verifying CNI enforcement directly rather than assuming it (kindnetd on this repo's pinned node image and Calico both enforce it - see DESIGN.md). | verified against live cluster |
| 10 | [Observability and troubleshooting](10-observability.md) | Logs, `kubectl debug`/ephemeral containers, `crictl` (CRI-level view, independent of API server/kubelet health), `journalctl -u kubelet` on a kind node, metrics-server, common failure-mode diagnosis (including a `kubectl describe -l` selector caveat). Placed late so the reader has enough vocabulary from prior chapters to interpret what's broken. | verified against live cluster |
| 11 | [Extending the API: CRDs](11-crds.md) | Custom resources and controllers as the mechanism the built-in objects (chapters 3-7) are themselves examples of, plus a conceptual aside on the aggregated-API-server alternative for when a CRD isn't enough. | verified against live cluster |
| 12 | [High availability and cluster operations](12-high-availability.md) | Multi-control-plane topology, etcd quorum, load-balancer fronting, node-failure semantics, PodDisruptionBudgets, etcd backup/restore, and kubeadm cluster upgrades. Capstone chapter. | verified against live cluster |
| 13 | [From source code to a running workload](13-app-deployment.md) | The developer-perspective seam chapters 1-12 don't cover: a minimal app + Dockerfile, build/tag/push to a local registry (`lab-helpers/registry`), `imagePullPolicy` failure modes for a self-built image, Deployment/Service/Ingress/ConfigMap tying chapters 3-5 together, and a rolling update triggered by a real source code change. Structurally distinct from the other chapters, not an extension of one. | verified against live cluster |

Status values: **not started** / **drafted** (written, examples not yet
re-verified against a live cluster) / **verified against live cluster**
(examples applied and their output captured for real, per this chapter's
run).
