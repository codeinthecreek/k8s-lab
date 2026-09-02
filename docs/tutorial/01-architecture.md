# 1. Cluster architecture

A Kubernetes cluster is a set of machines (nodes) split into two roles:
control plane and worker. This chapter covers what each role's
components actually do and how kind maps that model onto Docker
containers running on a single host. Everything later in this tutorial -
the API model, workloads, networking - is something one of these
components implements, so it's worth having the mental map before
looking at any object spec.

### Control plane and worker: what each role runs

**Why**: Kubernetes splits "decide what should happen" from "make it
happen." The control plane holds cluster state and makes scheduling and
reconciliation decisions; worker nodes run the actual application
containers and report status back. This separation is what lets you add
or lose worker capacity without touching the components that hold
cluster state, and what lets the control plane itself be replicated
independently of workload placement (see chapter 12).

A control-plane node runs four components, each a separate process. All
four exist to serve etcd, the cluster's single source of truth for
state: kube-apiserver is the only one allowed to read or write it
directly, and the other two watch it through kube-apiserver and act on
what they see:

- **kube-apiserver** - the only component that talks to etcd directly.
  Every other component, and every `kubectl` command, goes through it.
  It validates and persists API objects and does nothing else - no
  scheduling logic, no reconciliation logic.
- **etcd** - the cluster's key-value store. Every API object's current
  state lives here. Nothing else in the cluster stores authoritative
  state; components reconstruct their view by reading from the
  apiserver, which reads from etcd.
- **kube-scheduler** - watches for Pods with no node assigned and picks
  one, based on resource requests, taints/tolerations, affinity rules
  (chapter 7). It only decides *where* a Pod should run - it doesn't run
  anything itself.
- **kube-controller-manager** - runs the built-in control loops (Node
  controller, ReplicaSet controller, Job controller, and others) that
  watch the apiserver and act to move observed state toward desired
  state. A Deployment scaling a ReplicaSet up or down (chapter 3) is one
  of these loops in action.

A worker node runs two components:

- **kubelet** - the per-node agent. It watches the apiserver for Pods
  assigned to its node, tells the container runtime to start/stop
  containers accordingly, and reports node and Pod status back.
  Notably, kubelet is also what runs *control-plane* components
  themselves - see "Static pods" below.
- **kube-proxy** - programs each node's networking rules (iptables or
  IPVS, depending on configuration) to implement Service IPs (chapter
  5). It doesn't proxy traffic through userspace in modern
  configurations; it programs the kernel's packet handling and gets out
  of the way.

Both roles also run a **container runtime** (containerd, in kind's case
- verified via `containerd --version` inside a node container, currently
`v2.3.1`) and a **CNI** (Container Network Interface) plugin, which
provisions networking for each Pod - covered in chapter 5.

### Static pods: how the control plane bootstraps itself

**Why**: kube-apiserver, etcd, kube-scheduler, and kube-controller-manager
are themselves programs that need to be started and kept running - but
at cluster bootstrap, there's no functioning apiserver yet to schedule
Pods onto anything. kubeadm resolves this by having kubelet manage these
four components directly from static files, independent of the API
server entirely.

**Example**: on any control-plane node, kubelet is configured to watch a
manifest directory and run whatever Pod specs it finds there, without an
apiserver in the loop:

```
docker exec <control-plane-container> ls /etc/kubernetes/manifests/
```

**Expected output**: four files, one per control-plane component:

```
etcd.yaml
kube-apiserver.yaml
kube-controller-manager.yaml
kube-scheduler.yaml
```

These show up in `kubectl get pods -n kube-system` as ordinary-looking
Pods (`etcd-<node-name>`, `kube-apiserver-<node-name>`, etc.), which is a
common point of confusion - they are not scheduled by kube-scheduler and
have no controller managing replicas. If you edit or delete one, kubelet
notices the manifest file directly and restarts the process from it; the
apiserver only finds out about the change after the fact, by kubelet
mirroring the static pod's status as a regular Pod object it can be
observed through. There is no failure mode here worth demonstrating by
breaking a manifest on a single-node lab - doing so takes down the
apiserver itself.

### kind's node-as-container model

**Why**: kind's central trick is running each "node" as a Docker
container rather than a VM, with systemd and a container runtime
installed inside that container - a container that itself runs
containers. This is why a full multi-node cluster, or even multiple
independent clusters (this repo's profiles), can start in seconds
locally rather than minutes, and why `docker exec` and `docker logs`
work directly against a "node" the same way they'd work against any
other container.

**Example**: with the `default` profile up, compare kind's view of the
cluster against Docker's:

```
kubectl get nodes -o wide
docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Ports}}'
```

**Expected output**: one Docker container per Kubernetes node, sharing a
single Docker bridge network (`kind`) with the control-plane node's
container publishing host ports for the components that need to be
reachable from outside the cluster (here, 80/443 for ingress - see
chapter 5):

```
NAME                            STATUS   ROLES           VERSION
k8s-lab-default-control-plane   Ready    control-plane   v1.36.1
k8s-lab-default-worker          Ready    <none>          v1.36.1
k8s-lab-default-worker2         Ready    <none>          v1.36.1

NAMES                            IMAGE                   PORTS
k8s-lab-default-worker2          kindest/node:v1.36.1
k8s-lab-default-control-plane    kindest/node:v1.36.1    0.0.0.0:80->80/tcp, 0.0.0.0:443->443/tcp, ...
k8s-lab-default-worker           kindest/node:v1.36.1
```

Each node container's PID 1 is `systemd` (`docker exec
k8s-lab-default-control-plane ps -o pid,comm --no-headers -p 1` returns
`1 systemd`), which is what makes kubelet-as-a-systemd-service work the
same way it would on a real VM - kind isn't faking process supervision,
it's running the real thing one layer down. The practical consequence:
"a node going away" and "a container going away" are the same event in
kind (`docker stop <node-container>` is a valid, real way to simulate
node failure - see chapter 12), which doesn't hold on a real cluster
where a node is a whole machine.

### Control-plane scheduling exclusion

**Why**: running application workloads on the same node that hosts
etcd and the apiserver would let a noisy or misbehaving workload starve
the components the whole cluster depends on. kubeadm (and therefore
kind) taints every control-plane node on creation so that ordinary Pods
aren't scheduled there by default, without making the node unusable for
anything - DaemonSets that tolerate the taint (kindnet, kube-proxy) still
run on it.

**Example**:

```
kubectl describe node k8s-lab-default-control-plane | grep -A1 Taints:
```

**Expected output**:

```
Taints:             node-role.kubernetes.io/control-plane:NoSchedule
Unschedulable:      false
```

This is a `NoSchedule` taint specifically (chapter 7 covers taint
effects in full) - it blocks new Pods from being placed there but
doesn't evict anything already running. It's why the `default` profile's
two worker nodes end up hosting ordinary workloads while the
control-plane node doesn't, by design rather than by accident. If you
ever see a Pod stuck `Pending` with an event like `0/3 nodes are
available: 1 node(s) had untolerated taint...`, this taint - or one like
it - is almost always why.
