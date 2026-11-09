# Kubernetes tutorial

A from-scratch, concept-first Kubernetes tutorial. It's written for
anyone with `kind` and `kubectl` installed, and uses this repo's own
profiles (`default`, `ha-control-plane`, `calico`, and `gpu-fake` for the
GPU section) and manifests as its
working examples.

**Chapter order follows concept dependency.** The numeric filename
prefix (`01-`, `02-`, ...) is reading order only. See DESIGN.md's
"Tutorial content: structure and conventions" section for the full
reasoning behind this and every other convention this tutorial follows.

Written and verified against: **Kubernetes v1.36.1** (kind server
version, `default` profile, `kindest/node:v1.36.1`), captured via
`kubectl version`. Chapters using `ha-control-plane`, `calico` or `gpu-fake` note
that explicitly where relevant. Chapters 15 and 16 (the GPU section's
first two chapters) were verified against kind v0.33.0,
`kindest/node:v1.36.1` and kubectl client v1.37.1. Chapter 17 runs on a separate
real-GPU kind cluster (`lab-helpers/gpu-real/`, not a profile) and adds helm v4.3.0 and
the NVIDIA device plugin chart 0.20.1; its own "Verified against" line lists every
version. Version-specific behavior is flagged
inline per-chapter rather than assumed to hold indefinitely - see
DESIGN.md.

For a quick reference to the `kubectl`, `kind`, `helm`, and `make`
commands used throughout, see the [command cheat sheet](../cheatsheet.md).

## Chapters

| # | Title | Scope | Status |
|---|-------|-------|--------|
| 1 | [Cluster architecture](01-architecture.md) | Control plane / worker split, what each component does, how kind's node-as-container model maps onto it. No YAML - conceptual foundation only. | verified against live cluster |
| 2 | [The API model](02-api-model.md) | Declarative desired-state model, apiVersion/kind/metadata/spec, kubectl as an API client, what `apply` actually does (diff + PATCH, not blind create). First chapter with a YAML example. | verified against live cluster |
| 3 | [Pods and workloads](03-workloads.md) | Pod as the atomic unit, then ReplicaSet -> Deployment, rolling updates, why you almost never create a bare Pod. | verified against live cluster |
| 4 | [Configuration and storage](04-config-storage.md) | ConfigMaps/Secrets, Volumes, PV/PVC static binding, StorageClass. Placed after workloads - none of this means anything without a Pod to attach it to. | verified against live cluster |
| 5 | [Services and networking](05-services-networking.md) | ClusterIP/NodePort/LoadBalancer, CoreDNS service discovery, Ingress as L7 routing on top of Services. | verified against live cluster |
| 6 | [Specialized workloads](06-specialized-workloads.md) | Workload shapes that deliberately break from the interchangeable-replica model: StatefulSet (stable identity, per-replica storage) and a "workloads that run to completion" subsection on Job and CronJob. | verified against live cluster |
| 7 | [Scheduling and resource management](07-scheduling.md) | Labels/selectors, node affinity, pod affinity/anti-affinity, taints/tolerations, resource requests/limits, PriorityClass and preemption (including `preemptionPolicy: Never`), and namespace-level governance via ResourceQuota (compute and storage dimensions)/LimitRange. | verified against live cluster |
| 8 | [Package management with Helm](08-helm.md) | Templating/release management for patterns already taught in chapters 3-7, via both `helm create` scaffolding and the `helm repo add`/published-chart model. Deliberately not covered earlier. | verified against live cluster |
| 9 | [Security](09-security.md) | ServiceAccounts, RBAC (Role/RoleBinding and ClusterRole/ClusterRoleBinding, including binding a ClusterRole via a namespaced RoleBinding), x509 client-certificate authentication (CN/O mapping, curling the API with --cert/--key/--cacert), kubectl proxy as an RBAC-vs-connectivity diagnostic, admission control (Pod Security Admission, plus an aside on admission-plugin flags vs compiled-in defaults), and NetworkPolicy. NetworkPolicy depends on chapter 5's networking model and covers verifying CNI enforcement directly rather than assuming it (kindnetd on this repo's pinned node image and Calico both enforce it - see DESIGN.md). | verified against live cluster |
| 10 | [Observability and troubleshooting](10-observability.md) | Logs, `kubectl debug`/ephemeral containers, `crictl` (CRI-level view, independent of API server/kubelet health), `journalctl -u kubelet` on a kind node, metrics-server, common failure-mode diagnosis (including a `kubectl describe -l` selector caveat). Placed late so the reader has enough vocabulary from prior chapters to interpret what's broken. | verified against live cluster |
| 11 | [Extending the API: CRDs](11-crds.md) | Custom resources and controllers as the mechanism the built-in objects (chapters 3-7) are themselves examples of, plus a conceptual aside on the aggregated-API-server alternative for when a CRD isn't enough. | verified against live cluster |
| 12 | [High availability and cluster operations](12-high-availability.md) | Multi-control-plane topology, etcd quorum, load-balancer fronting, node-failure semantics, PodDisruptionBudgets, etcd backup/restore, and kubeadm cluster upgrades. Capstone chapter. | verified against live cluster |
| 13 | [From source code to a running workload](13-app-deployment.md) | The developer-perspective seam chapters 1-12 don't cover: a minimal app + Dockerfile, build/tag/push to a local registry (`lab-helpers/registry`), `imagePullPolicy` failure modes for a self-built image, Deployment/Service/Ingress/ConfigMap tying chapters 3-5 together, and a rolling update triggered by a real source code change. Structurally distinct from the other chapters, not an extension of one. | verified against live cluster |
| 14 | [Advanced and supplementary topics](14-advanced-topics.md) | Topics that don't fit chapters 1-13's concept-dependency ordering: `KubeSchedulerConfiguration`/Scheduling Profiles (the mechanism replacing the removed `--policy-config-file`), Dynamic Resource Allocation (`resource.k8s.io`, GA in 1.34 - optional, depends on an external Helm chart), Headlamp as a cluster web UI, and a short krew subsection. Appended after the capstone/structurally-distinct chapters rather than interleaved. | verified against live cluster |
| 15 | [Fake GPUs: extended resources as a scheduler-accounted counter](15-fake-gpu-nodes.md) | First chapter of the GPU section, on its own `gpu-fake` profile (1 control-plane + 2 workers, no GPU, no add-ons). Advertises `nvidia.com/gpu` on a node through the Node `status` subresource, schedules and exhausts it, adds capacity so a Pending Pod places itself, covers the request/limit rules, and shows that a count attaches nothing to the container. Opens with the state of the device-plugin and DRA models as documented for v1.36. GPU labels and taints are chapter 16; device plugins and a real GPU are [chapter 17](17-real-gpu-device-plugin.md); sharing GPUs and quotas come later. | verified against live cluster |
| 16 | [GPU node labels and taints: steering GPU Pods, keeping other Pods off](16-gpu-node-labels-taints.md) | Second chapter of the GPU section, on the `gpu-fake` profile. Applies GPU Feature Discovery-style node labels by hand (`nvidia.com/gpu.product`, `gpu.count`, `gpu.memory`, with names and example values from the NVIDIA GFD docs), steers GPU Pods with `nodeSelector` and node affinity (including `Gt` on a numeric label), shows that a matching label is not capacity, taints the one GPU node with `nvidia.com/gpu:NoSchedule` so ordinary Pods stay off, and tolerates it on GPU Pods. Checks whether the `ExtendedResourceToleration` admission plugin is enabled on the cluster. The labels are hand-applied stand-ins; automatic generation and device plugins are not covered. | verified against live cluster |
| 17 | [A real GPU: the device plugin, a first GPU Pod, and what to check when it fails](17-real-gpu-device-plugin.md) | Third chapter of the GPU section, on a separate kind cluster with one real NVIDIA GPU worker (`lab-helpers/gpu-real/`, created with nvkind; not a profile). Installs the NVIDIA device plugin with Helm so `nvidia.com/gpu` capacity appears with no patch, shows why the plugin does not start on an unlabelled node and what its log says when the container runtime is wrong (`runtimeClassName: nvidia`), runs a CUDA sample Pod that requests one GPU, reads the event of a Pending GPU Pod, and shows what happens to node allocatable and a running GPU Pod when the plugin is uninstalled. Sharing GPUs and quotas are the next chapter; the GPU Operator, MIG, DRA and monitoring are not covered. | verified against live cluster |

Status values: **not started** / **drafted** (written, examples not yet
re-verified against a live cluster) / **verified against live cluster**
(examples applied and their output captured for real, per this chapter's
run).
