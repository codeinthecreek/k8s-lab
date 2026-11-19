# 1. Cluster architecture

A Kubernetes cluster is a set of machines, called **nodes**, in two
roles: the **control plane** and the **workers**. This chapter covers
what runs in each role, and how kind turns that into Docker containers
on one machine. Everything in later chapters, from the API to
networking, is done by one of these components, so it helps to know
them before looking at any objects.

### Bringing up the cluster

The examples need a running cluster. From the repo root, with Docker
running and `kind` and `kubectl` installed:

```
make up
```

This creates the `default` profile: one control-plane node and two
workers, as Docker containers named `k8s-lab-default-control-plane`,
`k8s-lab-default-worker` and `k8s-lab-default-worker2`. When it has
finished, check that the cluster responds:

```
make status
```

**Expected output**: the three nodes, `Ready`, followed by a list of
every Pod in the cluster, all `Running` once they've started. The
nodes (with your machine's kernel version where this shows
`<host kernel>`):

```
--- profile: default (context kind-k8s-lab-default) ---
NAME                            STATUS   ROLES           AGE   VERSION   INTERNAL-IP   EXTERNAL-IP   OS-IMAGE                       KERNEL-VERSION           CONTAINER-RUNTIME
k8s-lab-default-control-plane   Ready    control-plane   39m   v1.36.1   172.18.0.4    <none>        Debian GNU/Linux 13 (trixie)   <host kernel> (amd64)   containerd://2.3.1
k8s-lab-default-worker          Ready    <none>          39m   v1.36.1   172.18.0.2    <none>        Debian GNU/Linux 13 (trixie)   <host kernel> (amd64)   containerd://2.3.1
k8s-lab-default-worker2         Ready    <none>          39m   v1.36.1   172.18.0.3    <none>        Debian GNU/Linux 13 (trixie)   <host kernel> (amd64)   containerd://2.3.1
```

Commands in this chapter that use `docker exec` need one of those
container names. On another profile, `docker ps --format '{{.Names}}'`
lists them.

### Control plane and worker: what each role runs

**Why**: Kubernetes separates deciding what should happen from doing
it. The control plane holds the cluster's state and makes the
decisions: where to run things, what to fix. The workers run the
application containers and report back. Because of that split, you can
add or lose workers without touching the components that hold the
state, and the control plane can be replicated on its own (chapter
12).

A control-plane node runs four components, each a separate program.
**etcd** holds the state; **kube-apiserver** is the only component that
reads and writes it; the other two watch the state through
kube-apiserver and act on it:

- **kube-apiserver**: the only component that talks to etcd. Every
  other component, and every `kubectl` command, goes through it. It
  checks and stores API objects, and that's all: it doesn't schedule
  or fix anything.
- **etcd**: the cluster's key-value store, holding the current state of
  every API object. No other component keeps its own authoritative
  copy; they all read the state through the API server.
- **kube-scheduler**: finds Pods that haven't been assigned a node yet,
  and picks one for each, based on resource requests, taints and
  affinity rules (chapter 7). It only decides *where* a Pod runs; it
  doesn't run anything.
- **kube-controller-manager**: runs the built-in **controllers**
  (for Nodes, ReplicaSets, Jobs and more). Each one watches the API
  server and works to make the actual state match the desired state. A
  Deployment scaling a ReplicaSet up or down (chapter 3) is one of
  them at work.

A worker node runs two components:

- **kubelet**: the agent on each node. It watches the API server for
  Pods assigned to its node, tells the container runtime to start and
  stop their containers, and reports the status of the node and its
  Pods. The kubelet also runs the control-plane components themselves;
  see "Static pods" below.
- **kube-proxy**: sets up each node's network rules (iptables or IPVS)
  so that Service IPs work (chapter 5). It doesn't pass the traffic
  through itself: it programs the kernel, which handles the packets.

Every node also runs a **container runtime**, which actually starts and
stops containers (containerd, in kind), and a **CNI** (Container
Network Interface) plugin, which sets up each Pod's network (chapter
5). The `CONTAINER-RUNTIME` column above shows containerd's version;
you can also ask containerd itself, inside a node container:

```
docker exec k8s-lab-default-worker containerd --version
```

```
containerd github.com/containerd/containerd/v2 v2.3.1 64b425cf570b3b8dd1d4cc46da7c1fce65c6651a
```

### Static pods: how the control plane bootstraps itself

**Why**: the four control-plane components are programs that something
has to start and keep running. But when a cluster is first set up,
there's no API server yet to create Pods through. kubeadm, the tool
kind uses to set up clusters, solves this by having the kubelet run the
four components directly from files on disk, without the API
server.

**Example**: on a control-plane node, the kubelet watches a directory of
Pod manifests and runs whatever it finds there:

```
docker exec k8s-lab-default-control-plane ls /etc/kubernetes/manifests/
```

**Expected output**: one file per control-plane component:

```
etcd.yaml
kube-apiserver.yaml
kube-controller-manager.yaml
kube-scheduler.yaml
```

These **static pods** appear in `kubectl get pods -n kube-system` like
other Pods (`etcd-<node-name>`, `kube-apiserver-<node-name>` and so
on), which can be confusing: the scheduler didn't place them and no
controller manages them. The kubelet runs them from the files, and
creates a read-only copy of each in the API (a *mirror Pod*) so that
you can see them. If you change or delete a file, the kubelet acts on
it directly; the API server only sees the result. Don't try this on a
cluster with one control-plane node: breaking the API server's file
takes the API server down.

### kind's node-as-container model

**Why**: kind runs each node as a Docker container instead of a virtual
machine. Inside each container are systemd, the kubelet and a container
runtime: a container that runs containers. That's why a whole
multi-node cluster, or several (this repo's profiles), can start in
seconds, and why `docker exec` and `docker logs` work on a node like on
any other container.

**Example**: compare Kubernetes's view of the nodes with Docker's:

```
kubectl get nodes
docker ps --filter name=k8s-lab-default --format 'table {{.Names}}\t{{.Image}}\t{{.Ports}}'
```

(`--filter` leaves out any other containers you have running.)

**Expected output**: one Docker container per node, all on one Docker
network (`kind`). Only the control-plane container publishes ports on
your host: 80 and 443 for ingress (chapter 5), and the API server's
port:

```
NAME                            STATUS   ROLES           AGE   VERSION
k8s-lab-default-control-plane   Ready    control-plane   40m   v1.36.1
k8s-lab-default-worker          Ready    <none>          40m   v1.36.1
k8s-lab-default-worker2         Ready    <none>          40m   v1.36.1
NAMES                           IMAGE                  PORTS
k8s-lab-default-worker2         kindest/node:v1.36.1
k8s-lab-default-worker          kindest/node:v1.36.1
k8s-lab-default-control-plane   kindest/node:v1.36.1   0.0.0.0:80->80/tcp, 0.0.0.0:443->443/tcp, 127.0.0.1:41419->6443/tcp
```

`127.0.0.1:41419->6443/tcp` is the API server: port 6443 in the
container, published on a random port on your host's loopback address.
Your kubeconfig points `kubectl` at it.

Each node container's first process, PID 1, is `systemd`, as on a real
machine, and the kubelet runs as a systemd service under it:

```
docker exec k8s-lab-default-control-plane ps -o pid,comm --no-headers -p 1
```

```
      1 systemd
```

The practical consequence: in kind, a node going away and a container going
away are the same thing. `docker stop <node-container>` is a real way
to simulate a node failure (chapter 12). On a real cluster, a node is a
whole machine.

### Control-plane scheduling exclusion

**Why**: if applications ran on the node that hosts etcd and the API
server, one misbehaving application could starve the components the
whole cluster depends on. So kubeadm, and therefore kind, gives every
control-plane node a **taint** when it's created, which keeps ordinary
Pods off it. Pods that *tolerate* the taint can still run there, such
as the kindnet and kube-proxy Pods, which a DaemonSet runs on every
node (chapter 6).

**Example**:

```
kubectl describe node k8s-lab-default-control-plane | grep -A1 Taints:
```

**Expected output**:

```
Taints:             node-role.kubernetes.io/control-plane:NoSchedule
Unschedulable:      false
```

`NoSchedule` stops new Pods from being placed on the node, but doesn't
remove Pods already running there (chapter 7 covers taints in full).
That's why, in the `default` profile, ordinary workloads run on the two
workers and not on the control-plane node. If a Pod is stuck
`Pending` with an event like `0/3 nodes are available: 1 node(s) had
untolerated taint...`, this taint, or one like it, is usually part of
the reason.
