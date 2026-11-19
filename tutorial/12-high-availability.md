# 12. High availability and cluster operations

Every chapter so far used a cluster with one control-plane node. This
chapter uses the `ha-control-plane` profile, which has three. That means
three of everything: three apiservers, three schedulers, three
controller-managers and three etcd members.

Less changes than you might expect. A load balancer in front of the
apiservers, and etcd's own way of reaching agreement, hide most of the
difference, and everything from chapters 1-11 works the same way
underneath.

The chapter first looks at how this cluster is built, then at what
happens when a control-plane node fails. It ends with three operational
tasks: limiting planned disruption with PodDisruptionBudgets, backing up
and restoring etcd, and planning a cluster upgrade with `kubeadm`.

### Multi-control-plane topology: stacked etcd, one apiserver each

**Why**: the `ha-control-plane` profile has 3 control-plane nodes and 2
workers, on the same pinned node image as `default` (chapter 1). Each
control-plane node runs its own apiserver, controller-manager, scheduler
and etcd member, all as static Pods. Running etcd on the control-plane
nodes like this is called **stacked etcd**; the alternative is etcd on
separate, dedicated nodes. Static Pods work exactly as in chapter 1;
there are simply three copies of the same set, one per node.

**Example**: list the nodes and the Docker containers backing them:

```
kubectl get nodes -o wide
docker ps --filter "name=k8s-lab-ha-control-plane" --format "table {{.Names}}\t{{.Status}}"
```

**Expected output**: 3 control-plane nodes and 2 workers, all `Ready`,
plus a 6th container - the LB - that isn't a Kubernetes node at all:

```
$ kubectl get nodes -o wide
NAME                                      STATUS   ROLES           AGE     VERSION   INTERNAL-IP   EXTERNAL-IP   OS-IMAGE                       KERNEL-VERSION           CONTAINER-RUNTIME
k8s-lab-ha-control-plane-control-plane    Ready    control-plane   8m16s   v1.36.1   172.19.0.6    <none>        Debian GNU/Linux 13 (trixie)   <host kernel> (amd64)    containerd://2.3.1
k8s-lab-ha-control-plane-control-plane2   Ready    control-plane   6m30s   v1.36.1   172.19.0.5    <none>        Debian GNU/Linux 13 (trixie)   <host kernel> (amd64)    containerd://2.3.1
k8s-lab-ha-control-plane-control-plane3   Ready    control-plane   5m17s   v1.36.1   172.19.0.7    <none>        Debian GNU/Linux 13 (trixie)   <host kernel> (amd64)    containerd://2.3.1
k8s-lab-ha-control-plane-worker           Ready    <none>          5m13s   v1.36.1   172.19.0.4    <none>        Debian GNU/Linux 13 (trixie)   <host kernel> (amd64)    containerd://2.3.1
k8s-lab-ha-control-plane-worker2          Ready    <none>          5m13s   v1.36.1   172.19.0.3    <none>        Debian GNU/Linux 13 (trixie)   <host kernel> (amd64)    containerd://2.3.1

$ docker ps --filter "name=k8s-lab-ha-control-plane" --format "table {{.Names}}\t{{.Status}}"
NAMES                                             STATUS
k8s-lab-ha-control-plane-external-load-balancer   Up 9 minutes
k8s-lab-ha-control-plane-control-plane            Up 8 minutes
k8s-lab-ha-control-plane-worker                   Up 8 minutes
k8s-lab-ha-control-plane-control-plane2           Up 59 seconds
k8s-lab-ha-control-plane-control-plane3           Up 8 minutes
k8s-lab-ha-control-plane-worker2                  Up 8 minutes
```

That's 6 containers for 5 nodes. The extra one is the load balancer:
kind runs it as a Docker container, and it is not a Kubernetes node, so
`kubectl get nodes` never lists it. (`control-plane2` shows a short
uptime because this output was captured after the failure exercise later
in the chapter, which stops and restarts it.)

### Why 3, not 4: etcd quorum

**Why**: etcd only accepts a write when a majority of its members agree
(a *quorum*). With 3 members, a majority is 2, so the cluster survives
losing 1. With 4 members, a majority is 3, so it *still* survives losing
only 1, and you pay for an extra node. In general, adding a member to an
odd-sized cluster buys no extra fault tolerance, which is why etcd
clusters are sized 3, 5 or 7.

**Example**: ask etcd for its members and their health. The etcd image
includes the `etcdctl` client, so run it inside an etcd static Pod. It
needs the TLS certificates kubeadm put on the node, passed as flags:

```
kubectl exec -n kube-system etcd-<a-control-plane-node-name> -- etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  member list -w table

kubectl exec -n kube-system etcd-<a-control-plane-node-name> -- etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  endpoint health --cluster
```

**Expected output**: 3 members, all healthy:

```
$ kubectl exec -n kube-system etcd-k8s-lab-ha-control-plane-control-plane -- etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  member list -w table
+------------------+---------+-----------------------------------------+-------------------------+-------------------------+------------+
|        ID        | STATUS  |                  NAME                   |       PEER ADDRS        |      CLIENT ADDRS       | IS LEARNER |
+------------------+---------+-----------------------------------------+-------------------------+-------------------------+------------+
|  344fc99f97f49a3 | started | k8s-lab-ha-control-plane-control-plane3 | https://172.19.0.7:2380 | https://172.19.0.7:2379 |      false |
| 6f1e1de96aea0868 | started |  k8s-lab-ha-control-plane-control-plane | https://172.19.0.6:2380 | https://172.19.0.6:2379 |      false |
| 77cf30ac74b21a08 | started | k8s-lab-ha-control-plane-control-plane2 | https://172.19.0.5:2380 | https://172.19.0.5:2379 |      false |
+------------------+---------+-----------------------------------------+-------------------------+-------------------------+------------+

$ kubectl exec -n kube-system etcd-k8s-lab-ha-control-plane-control-plane -- etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  endpoint health --cluster
https://172.19.0.6:2379 is healthy: successfully committed proposal: took = 4.398008ms
https://172.19.0.5:2379 is healthy: successfully committed proposal: took = 4.933509ms
https://172.19.0.7:2379 is healthy: successfully committed proposal: took = 4.869108ms
```

That's etcd. Next: how does a client such as `kubectl` reach one of
the three apiservers?

### Envoy fronts the apiservers - the kubeconfig points at the LB, not a node

**Why**: when a cluster has more than one control-plane node, kind adds
a Docker container running Envoy, a load balancer, named
`<cluster-name>-external-load-balancer`. Your kubeconfig points at this
container, not at any one apiserver, and so does each control-plane
node when it joins the cluster. Envoy forwards each connection to one of
the three apiservers.

Envoy's routing is set up when the container starts, in two files it
generates: `/home/envoy/cds.yaml` lists the three control-plane nodes on
port 6443, with health checks, and `/home/envoy/lds.yaml` sets up a
listener on 6443 that forwards to them. (The image also contains
`/etc/envoy/envoy.yaml`, but that's an unused example config.)

**Example**: check where the kubeconfig points, and read Envoy's
generated config. The Envoy image has no shell tools such as `curl`, so
reading the files is easier than querying Envoy from inside the
container:

```
kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}'
docker ps --filter "name=external-load-balancer" --format "{{.Names}}"
docker exec <lb-container> cat /home/envoy/cds.yaml
docker port <lb-container>
```

**Expected output**: the kubeconfig points at a port on `127.0.0.1`,
and that port belongs to the load balancer container, not to any
control-plane node:

```
$ kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}'
https://127.0.0.1:40475

$ docker port k8s-lab-ha-control-plane-external-load-balancer
6443/tcp -> 127.0.0.1:40475
```

`cds.yaml` (not shown in full) lists all 3 control-plane nodes on port
6443, and health-checks each one with `GET /healthz` every 2 seconds.
Those checks are how Envoy notices a dead apiserver and stops sending
traffic to it, as the next section shows.

Envoy also has an admin interface on port 10000. kind doesn't publish
it to the host (`docker port` only lists 6443), but you can reach it on
the container's own address on the `kind` Docker network:

```
$ LB_IP=$(docker inspect k8s-lab-ha-control-plane-external-load-balancer --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')
$ curl -s http://${LB_IP}:10000/clusters | head
```

This prints statistics for each of the 3 apiservers. The next section
uses it to watch one of them fail.

That's how the cluster is built. The rest of the chapter is about what
happens when part of it fails or needs maintenance.

### Node-failure semantics: `docker stop` is the honest simulation

**Why**: to see what happens when a control-plane node fails, you have
to break it the right way.

- `docker stop <container>` stops the whole node container. Envoy's
  health checks fail, its hostname stops resolving, and as far as the
  rest of the cluster can tell the node is gone. That's what a real
  hardware failure looks like.
- `docker exec <container> systemctl stop containerd` looks similar but
  isn't. Containers that are already running, including the apiserver,
  keep running without the containerd daemon, so the apiserver keeps
  answering health checks. Only *new* container operations fail. If you
  use this to try to break quorum, nothing seems to happen.

**Example**: try both, and compare what each does to the cluster and to
Envoy's view of that node:

```
# The one that does NOT reproduce node failure:
docker exec <a-control-plane-container> systemctl stop containerd
kubectl get nodes
docker exec <a-control-plane-container> systemctl start containerd   # restore

# The one that does:
docker stop <a-control-plane-container>
kubectl get nodes                 # check immediately...
kubectl get nodes                 # ...and again ~1 minute later
curl -s http://${LB_IP}:10000/clusters | grep -A2 <stopped-node-ip>
docker start <a-control-plane-container>   # restore
```

**Expected output**: stopping containerd changes nothing you can see.
Every node, including the one without containerd, stays `Ready`:

```
$ docker exec k8s-lab-ha-control-plane-control-plane2 systemctl stop containerd
$ kubectl get nodes
NAME                                      STATUS   ROLES           AGE   VERSION
k8s-lab-ha-control-plane-control-plane    Ready    control-plane   ...   v1.36.1
k8s-lab-ha-control-plane-control-plane2   Ready    control-plane   ...   v1.36.1
k8s-lab-ha-control-plane-control-plane3   Ready    control-plane   ...   v1.36.1
k8s-lab-ha-control-plane-worker           Ready    <none>          ...   v1.36.1
k8s-lab-ha-control-plane-worker2          Ready    <none>          ...   v1.36.1
```

`docker stop` really takes the node away. The cluster keeps working,
because etcd still has a quorum and two apiservers are left. The stopped
node's status doesn't change at once, though: it turns `NotReady` only
after its kubelet has missed status updates for longer than the node
monitor's grace period:

```
$ docker stop k8s-lab-ha-control-plane-control-plane2
$ kubectl get nodes          # immediately after - heartbeat hasn't timed out yet
...control-plane2   Ready    control-plane   ...   v1.36.1

$ kubectl get nodes          # ~52s later
...control-plane2   NotReady   control-plane   ...   v1.36.1
```

```
$ kubectl get node k8s-lab-ha-control-plane-control-plane2 -o jsonpath='{.status.conditions[?(@.type=="Ready")]}'
{"lastHeartbeatTime":"2026-08-30T08:05:59Z","lastTransitionTime":"2026-08-30T08:06:51Z","message":"Kubelet stopped posting node status.","reason":"NodeStatusUnknown","status":"Unknown","type":"Ready"}
```

The other 4 nodes stay `Ready`, and `kubectl get nodes` keeps working
the whole time. That's the point of 3 control-plane nodes, etcd quorum
and a load balancer: a client doesn't notice when 1 of the 3 is lost.
Envoy noticed even sooner than Kubernetes did:

```
$ curl -s http://${LB_IP}:10000/clusters | grep -B1 health_flags
172.19.0.5:6443::health_flags::/failed_active_hc/active_hc_timeout
172.19.0.6:6443::health_flags::healthy
172.19.0.7:6443::health_flags::healthy
```

`172.19.0.5` is `control-plane2`. Envoy's 2-second health check marked
it as failed well before its node status changed, and Envoy now sends
new requests only to the other two apiservers.

### PodDisruptionBudgets: bounding voluntary disruption

**Why**: the `docker stop` above was an *involuntary* disruption: the
node just died, and nothing asked permission. A *voluntary* disruption is
a planned one: draining a node before maintenance with `kubectl drain`,
upgrading a node (next section), or an autoscaler removing one. These
remove Pods through the **Eviction API**, and a workload can limit how
many of its Pods are evicted at once with a **PodDisruptionBudget**
(PDB), using `minAvailable` or `maxUnavailable`.

Only evictions respect a PDB. A plain `kubectl delete pod` ignores it:
deleting and evicting both end with the Pod gone, but they're different
requests.

**Example**: create a Deployment with 3 replicas and a PDB that keeps
at least 2 available. Then send two evictions straight after each other
through the Eviction API, which is what `kubectl drain` uses. The first
should succeed and the second should be refused:

```
kubectl create deployment ha-demo-pdb --image=nginx:1.27 --replicas=3
kubectl rollout status deployment/ha-demo-pdb
kubectl create poddisruptionbudget ha-demo-pdb --selector=app=ha-demo-pdb --min-available=2
kubectl get pdb ha-demo-pdb

kubectl proxy --port=8001 &
POD1=$(kubectl get pods -l app=ha-demo-pdb -o jsonpath='{.items[0].metadata.name}')
POD2=$(kubectl get pods -l app=ha-demo-pdb -o jsonpath='{.items[1].metadata.name}')
curl -s -X POST localhost:8001/api/v1/namespaces/default/pods/$POD1/eviction \
  -H "Content-Type: application/json" \
  -d "{\"apiVersion\":\"policy/v1\",\"kind\":\"Eviction\",\"metadata\":{\"name\":\"$POD1\",\"namespace\":\"default\"}}"
curl -s -X POST localhost:8001/api/v1/namespaces/default/pods/$POD2/eviction \
  -H "Content-Type: application/json" \
  -d "{\"apiVersion\":\"policy/v1\",\"kind\":\"Eviction\",\"metadata\":{\"name\":\"$POD2\",\"namespace\":\"default\"}}"
```

**Expected output**: with 3 replicas and `minAvailable: 2`, the PDB
allows 1 disruption. The first eviction succeeds (`201`). The second
comes before a replacement Pod is ready, and is refused with `429
TooManyRequests`:

```
$ kubectl get pdb ha-demo-pdb
NAME          MIN AVAILABLE   MAX UNAVAILABLE   ALLOWED DISRUPTIONS   AGE
ha-demo-pdb   2               N/A               1                    0s

$ curl -s -X POST localhost:8001/api/v1/namespaces/default/pods/$POD1/eviction ...
{
  "kind": "Status",
  "apiVersion": "v1",
  "status": "Success",
  "code": 201
}

$ curl -s -X POST localhost:8001/api/v1/namespaces/default/pods/$POD2/eviction ...
{
  "kind": "Status",
  "apiVersion": "v1",
  "status": "Failure",
  "message": "Cannot evict pod as it would violate the pod's disruption budget.",
  "reason": "TooManyRequests",
  "details": {
    "causes": [
      {
        "reason": "DisruptionBudget",
        "message": "The disruption budget ha-demo-pdb needs 2 healthy pods and has 2 currently"
      }
    ]
  },
  "code": 429
}
```

Right afterwards, the PDB allows no more disruptions: the first eviction
used up the budget.

```
$ kubectl get pdb ha-demo-pdb
NAME          MIN AVAILABLE   MAX UNAVAILABLE   ALLOWED DISRUPTIONS   AGE
ha-demo-pdb   2               N/A               0                    10s
```

A `429` doesn't mean "never", unlike chapter 9's `403` errors. It means
"try again later". `kubectl drain` does exactly that: it keeps retrying
the refused eviction until the budget allows it, usually once the
replacement Pod is `Ready`.

### etcd backup and restore

**Why**: etcd holds the cluster's entire state: every object you've
created since chapter 2 is stored there and nowhere else. Losing a
control-plane node is survivable, as the earlier section showed. Losing
or corrupting etcd's data is not, and a backup is how you recover from
that.

A backup has two steps:

- `snapshot save` copies one etcd member's data into a single file,
  while etcd is running.
- `snapshot restore` builds a new etcd data directory from that file. It
  doesn't touch the running etcd at all.

To actually recover, you would stop etcd (by moving its static Pod
manifest out of `/etc/kubernetes/manifests/`, so the kubelet stops it),
replace its data directory with the restored one, and move the manifest
back. That last part risks the lab cluster's data, so this section only
describes it. It does run the save and the restore, into a separate
directory.

On this cluster's etcd (3.6), the commands are split between two tools,
both in the etcd image. `etcdctl` talks to a running etcd and does
`snapshot save`. `etcdutl` works on files, offline, and does `snapshot
status` and `snapshot restore`. Older etcd versions had all three under
`etcdctl`.

One more thing before the commands: etcd reports two version numbers.
`VERSION` is the etcd release that's running (`3.6.8` here). `STORAGE
VERSION` is the format of its stored data (`3.6.0` here), which etcd
tracks separately so that downgrades stay safe. The snapshot commands
report the *storage* version, even though they call it `VERSION` or
`etcd-version`. So you'll see `3.6.0` from the snapshot commands and
`3.6.8` from `kubeadm` later in this chapter, for the same etcd member.
Both are correct.

**Example**: show the member's status, save a snapshot with `etcdctl`,
then use `etcdutl` to check the file and restore it into a separate
directory:

```
kubectl exec -n kube-system etcd-<a-control-plane-node-name> -- etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  endpoint status -w table

kubectl exec -n kube-system etcd-<a-control-plane-node-name> -- etcdctl \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  snapshot save /var/lib/etcd-backup-demo.db

kubectl exec -n kube-system etcd-<a-control-plane-node-name> -- etcdutl \
  snapshot status /var/lib/etcd-backup-demo.db -w table

kubectl exec -n kube-system etcd-<a-control-plane-node-name> -- etcdutl \
  snapshot restore /var/lib/etcd-backup-demo.db --data-dir=/var/lib/etcd-restore-test
```

**Expected output**: `endpoint status` shows both version numbers side
by side:

```
$ kubectl exec -n kube-system etcd-k8s-lab-ha-control-plane-control-plane -- etcdctl \
  --endpoints=https://127.0.0.1:2379 --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt --key=/etc/kubernetes/pki/etcd/server.key \
  endpoint status -w table
+------------------------+------------------+---------+-----------------+---------+--------+-----------------------+--------+-----------+------------+-----------+------------+--------------------+--------+--------------------------+-------------------+
|        ENDPOINT        |        ID        | VERSION | STORAGE VERSION | DB SIZE | IN USE | PERCENTAGE NOT IN USE | QUOTA  | IS LEADER | IS LEARNER | RAFT TERM | RAFT INDEX | RAFT APPLIED INDEX | ERRORS | DOWNGRADE TARGET VERSION | DOWNGRADE ENABLED |
+------------------------+------------------+---------+-----------------+---------+--------+-----------------------+--------+-----------+------------+-----------+------------+--------------------+--------+--------------------------+-------------------+
| https://127.0.0.1:2379 | 4c95f7dc5897214a |   3.6.8 |           3.6.0 |  2.5 MB | 2.5 MB |                    0% | 2.1 GB |      true |      false |         2 |       1424 |               1421 |        |                          |             false |
+------------------------+------------------+---------+-----------------+---------+--------+-----------------------+--------+-----------+------------+-----------+------------+--------------------+--------+--------------------------+-------------------+
```

The snapshot saves, and `etcdutl snapshot status` describes the file.
Its `VERSION` column is the storage version, `3.6.0`:

```
$ kubectl exec -n kube-system etcd-k8s-lab-ha-control-plane-control-plane -- etcdctl \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key snapshot save /var/lib/etcd-backup-demo.db
{"level":"info","msg":"created temporary db file","path":"/var/lib/etcd-backup-demo.db.part"}
{"level":"info","msg":"fetched snapshot","endpoint":"127.0.0.1:2379","size":"2.7 MB","took":"650.372095ms","etcd-version":"3.6.0"}
{"level":"info","msg":"saved","path":"/var/lib/etcd-backup-demo.db"}
Snapshot saved at /var/lib/etcd-backup-demo.db

$ kubectl exec -n kube-system etcd-k8s-lab-ha-control-plane-control-plane -- etcdutl \
  snapshot status /var/lib/etcd-backup-demo.db -w table
+----------+----------+------------+------------+---------+
|   HASH   | REVISION | TOTAL KEYS | TOTAL SIZE | VERSION |
+----------+----------+------------+------------+---------+
| 682bd1a0 |     1272 |        517 |     2.7 MB |   3.6.0 |
+----------+----------+------------+------------+---------+
```

A common mistake from older etcd versions is to run `snapshot status`
with `etcdctl`. It doesn't fail with an error: it prints the help text
for `etcdctl snapshot` instead, which is easy to miss.

`etcdutl snapshot restore` creates the new data directory:

```
$ kubectl exec -n kube-system etcd-k8s-lab-ha-control-plane-control-plane -- etcdutl \
  snapshot restore /var/lib/etcd-backup-demo.db --data-dir=/var/lib/etcd-restore-test
{"level":"info","msg":"restored snapshot","...","data-dir":"/var/lib/etcd-restore-test"}
```

The new directory contains `snap/` and `wal/`, the same two
subdirectories as a running member's data directory. (Checking that
takes a detour: the etcd image has no shell and no `ls`, so `kubectl
exec ... ls` fails with "executable file not found", as with chapter
10's `pause` container. The contents were checked from the node instead,
under `/proc/<container-pid>/root/var/lib/etcd-restore-test/`.)

All 5 nodes stayed `Ready` throughout: restoring into a separate
directory doesn't affect the running etcd.

Backups are for disasters. The last task is a routine one: upgrading the
cluster to a newer Kubernetes version.

### Cluster upgrades

**Why**: on a kubeadm cluster, upgrades go through `kubeadm upgrade`,
which knows the version-skew rules and does the steps in a fixed order:

1. `kubeadm upgrade plan` checks what you can upgrade to. It changes
   nothing.
2. `kubeadm upgrade apply <version>` runs on *one* control-plane node.
   It rewrites that node's static Pod manifests and waits for the new
   versions to come up healthy.
3. `kubeadm upgrade node` runs on every other control-plane node, and
   copies what the first node decided.
4. On each node, you upgrade the kubelet, kubeadm and kubectl packages
   with the operating system's package manager (kubeadm doesn't do
   this), restart the kubelet, and uncordon the node.

You might expect `kubeadm upgrade plan` to find nothing on this cluster,
because the kind node image contains just one Kubernetes version
(`v1.36.1`, chapter 1). It does find something: `upgrade plan` doesn't
look at what's installed on the node. It checks the public Kubernetes
release list over the internet and compares version numbers.

**Example**: check the running versions, then run the planning step,
which changes nothing:

```
kubectl exec -n kube-system kube-apiserver-<a-control-plane-node-name> -- kube-apiserver --version
docker exec <a-control-plane-container> kubeadm version
docker exec <a-control-plane-container> kubeadm upgrade plan
```

**Expected output**: a real upgrade target, fetched from the internet
by the node:

```
$ kubectl exec -n kube-system kube-apiserver-k8s-lab-ha-control-plane-control-plane -- kube-apiserver --version
Kubernetes v1.36.1

$ docker exec k8s-lab-ha-control-plane-control-plane kubeadm upgrade plan
[upgrade/versions] Cluster version: 1.36.1
[upgrade/versions] kubeadm version: v1.36.1
[upgrade/versions] Target version: v1.36.4
[upgrade/versions] Latest version in the v1.36 series: v1.36.4

Components that must be upgraded manually after you have upgraded the control plane with 'kubeadm upgrade apply':
COMPONENT   NODE                                      CURRENT   TARGET
kubelet     k8s-lab-ha-control-plane-control-plane    v1.36.1   v1.36.4
kubelet     k8s-lab-ha-control-plane-control-plane2   v1.36.1   v1.36.4
kubelet     k8s-lab-ha-control-plane-control-plane3   v1.36.1   v1.36.4
kubelet     k8s-lab-ha-control-plane-worker           v1.36.1   v1.36.4
kubelet     k8s-lab-ha-control-plane-worker2          v1.36.1   v1.36.4

Upgrade to the latest version in the v1.36 series:

COMPONENT                 NODE                                      CURRENT   TARGET
kube-apiserver            k8s-lab-ha-control-plane-control-plane    v1.36.1   v1.36.4
kube-apiserver            k8s-lab-ha-control-plane-control-plane2   v1.36.1   v1.36.4
kube-apiserver            k8s-lab-ha-control-plane-control-plane3   v1.36.1   v1.36.4
kube-controller-manager   k8s-lab-ha-control-plane-control-plane    v1.36.1   v1.36.4
kube-controller-manager   k8s-lab-ha-control-plane-control-plane2   v1.36.1   v1.36.4
kube-controller-manager   k8s-lab-ha-control-plane-control-plane3   v1.36.1   v1.36.4
kube-scheduler            k8s-lab-ha-control-plane-control-plane    v1.36.1   v1.36.4
kube-scheduler            k8s-lab-ha-control-plane-control-plane2   v1.36.1   v1.36.4
kube-scheduler            k8s-lab-ha-control-plane-control-plane3   v1.36.1   v1.36.4
kube-proxy                                                          1.36.1    v1.36.4
CoreDNS                                                              v1.14.2   v1.14.2
etcd                       k8s-lab-ha-control-plane-control-plane    3.6.8-0   3.6.8-0
etcd                       k8s-lab-ha-control-plane-control-plane2   3.6.8-0   3.6.8-0
etcd                       k8s-lab-ha-control-plane-control-plane3   3.6.8-0   3.6.8-0

You can now apply the upgrade by executing the following command:

	kubeadm upgrade apply v1.36.4
```

`kubeadm` found a newer patch release, `v1.36.4`. It stays within the
current minor version (1.36), because `kubeadm upgrade` never skips to
the next minor version in one step.

Two rows don't change: CoreDNS (`v1.14.2`) and etcd (`3.6.8-0`) have
the same current and target versions. A patch release only moves the
components it actually changed. `3.6.8-0` is the running etcd release
(the `-0` is the image's build suffix), the same `3.6.8` that `endpoint
status` showed in the previous section, not the `3.6.0` storage version.

Running inside kind changed nothing about `upgrade plan`: a real
cluster with internet access gets the same check. `kubeadm upgrade
apply v1.36.4` would be a different story, because the node image has
no `v1.36.4` binaries to switch to. This chapter doesn't run it, since a
failed apply could leave a control-plane node half-upgraded and wouldn't
teach anything more than `plan` already has.

On a cluster without internet access, `kubeadm upgrade plan` fails or
hangs trying to reach the release list. Better to know that before you
start an upgrade.
