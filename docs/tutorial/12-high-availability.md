# 12. High availability and cluster operations

Every chapter so far ran against a single-control-plane cluster, where
"the control plane" and "one node" were interchangeable. This capstone
chapter breaks that assumption: `ha-control-plane` runs 3 control-plane
nodes and asks what changes when there are three of everything -
apiserver, scheduler, controller-manager, and a member of etcd. The
short answer is: less than it looks like, because a load balancer and
etcd's own consensus protocol absorb almost all of the difference, and
almost everything from chapters 1-11 still applies unchanged
underneath. It closes with three operational skills this topology
exists to support: bounding *voluntary* disruption with
PodDisruptionBudgets (as opposed to the involuntary node failure
covered earlier), backing up and restoring etcd itself, and the real
`kubeadm upgrade` mechanism.

### Multi-control-plane topology: stacked etcd, one apiserver each

**Why**: `kind/profiles/ha-control-plane/cluster.yaml` runs 3
control-plane nodes and 2 workers, same pinned node image as `default`
(chapter 1). Each control-plane node runs its own etcd member alongside
its own apiserver/controller-manager/scheduler as static pods - this is
**stacked etcd**, etcd colocated on the same nodes as the control-plane
processes that use it, as opposed to etcd running on separate dedicated
nodes. Nothing about a static pod (chapter 1) changes with 3
control-plane nodes instead of 1 - there are just 3 independent copies
of the same static-pod manifest set, one per node.

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
k8s-lab-ha-control-plane-control-plane    Ready    control-plane   8m16s   v1.36.1   172.19.0.6    <none>        Debian GNU/Linux 13 (trixie)   7.1.11-arch1-1 (amd64)   containerd://2.3.1
k8s-lab-ha-control-plane-control-plane2   Ready    control-plane   6m30s   v1.36.1   172.19.0.5    <none>        Debian GNU/Linux 13 (trixie)   7.1.11-arch1-1 (amd64)   containerd://2.3.1
k8s-lab-ha-control-plane-control-plane3   Ready    control-plane   5m17s   v1.36.1   172.19.0.7    <none>        Debian GNU/Linux 13 (trixie)   7.1.11-arch1-1 (amd64)   containerd://2.3.1
k8s-lab-ha-control-plane-worker           Ready    <none>          5m13s   v1.36.1   172.19.0.4    <none>        Debian GNU/Linux 13 (trixie)   7.1.11-arch1-1 (amd64)   containerd://2.3.1
k8s-lab-ha-control-plane-worker2          Ready    <none>          5m13s   v1.36.1   172.19.0.3    <none>        Debian GNU/Linux 13 (trixie)   7.1.11-arch1-1 (amd64)   containerd://2.3.1

$ docker ps --filter "name=k8s-lab-ha-control-plane" --format "table {{.Names}}\t{{.Status}}"
NAMES                                             STATUS
k8s-lab-ha-control-plane-external-load-balancer   Up 9 minutes
k8s-lab-ha-control-plane-control-plane            Up 8 minutes
k8s-lab-ha-control-plane-worker                   Up 8 minutes
k8s-lab-ha-control-plane-control-plane2           Up 59 seconds
k8s-lab-ha-control-plane-control-plane3           Up 8 minutes
k8s-lab-ha-control-plane-worker2                  Up 8 minutes
```

(`control-plane2`'s short uptime above is real - it's the node this
chapter's own failure-simulation section stops and restarts further
down, captured after that exercise ran.) 6 containers total for 5
Kubernetes nodes - the load balancer is Docker infrastructure kind
manages, not a node `kubectl get nodes` will ever list.

### Why 3, not 4: etcd quorum

**Why**: etcd tolerates the loss of up to `floor(n/2)` members while
still serving writes - a 3-member cluster tolerates 1 failure (needs 2
of 3 to agree), and so does a 4-member cluster (needs 3 of 4), for the
cost of one extra node and strictly *worse* quorum math than 3. This is
why odd numbers of 3 or more are the practical convention for etcd
sizing - an even member count never buys additional fault tolerance
over the odd number just below it.

**Example**: check etcd's own view of its cluster membership and
health by running `etcdctl` inside the etcd static pod itself - it
ships `etcdctl` in-image, and its client requires the TLS certs
kubeadm already placed on disk:

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

**Expected output**: 3 members, all healthy, and no `docker exec`
fallback needed - `kubectl exec` into the etcd static pod works
directly, `etcdctl` is on its `PATH`, and the certs kubeadm placed are
exactly where the flags above expect:

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

### Envoy fronts the apiservers - the kubeconfig points at the LB, not a node

**Why**: with more than one control-plane node, kind stands up an
additional Docker container running Envoy
(`<cluster-name>-external-load-balancer`) in front of all 3
apiservers. The kubeconfig's `server:` field, and every control-plane
node's own `kubeadm join --control-plane` process, point at that Envoy
container - never at any individual apiserver directly. Envoy's actual
routing isn't its image's static `/etc/envoy/envoy.yaml` (that's
unused stock demo config) - it's dynamic xDS resources the container's
entrypoint generates at start: `/home/envoy/cds.yaml` (a cluster
listing all 3 control-plane nodes by container hostname on port 6443,
with active health checks) and `/home/envoy/lds.yaml` (a TCP listener
on 6443 forwarding into that cluster).

**Example**: confirm what the kubeconfig actually points at, and read
Envoy's real generated config directly (the Envoy image has no shell
utilities - no `curl`/`wget` - so reading the files it already wrote is
the practical approach, not hitting its admin API from inside the
container):

```
kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}'
docker ps --filter "name=external-load-balancer" --format "{{.Names}}"
docker exec <lb-container> cat /home/envoy/cds.yaml
docker port <lb-container>
```

**Expected output**: the kubeconfig points at a `127.0.0.1` port that
maps straight to the LB container, not to any control-plane node, and
`cds.yaml` lists all 3 by container hostname:

```
$ kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}'
https://127.0.0.1:40475

$ docker port k8s-lab-ha-control-plane-external-load-balancer
6443/tcp -> 127.0.0.1:40475
```

`cat /home/envoy/cds.yaml` shows a `kube_apiservers` `STRICT_DNS`
cluster with all 3 control-plane nodes
(`k8s-lab-ha-control-plane-control-plane`, `-control-plane2`,
`-control-plane3`) as `lb_endpoints` on port 6443, plus active health
checks (`GET /healthz` every 2s) - this is what lets Envoy notice a
dead backend and stop routing to it, demonstrated in the next section.

Envoy's admin interface (port 10000) turns out **not** to be published
to the host at all - `docker port <lb-container>` only shows `6443`,
confirmed with `docker inspect <lb-container>` showing `"10000/tcp":
null`. It's still reachable, just not via `localhost`: from the
container's address on the `kind` Docker network directly:

```
$ LB_IP=$(docker inspect k8s-lab-ha-control-plane-external-load-balancer --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')
$ curl -s http://${LB_IP}:10000/clusters | head
```

returns real per-backend stats for all 3 apiservers - used again in the
next section to watch a backend go unhealthy in real time.

### Node-failure semantics: `docker stop` is the honest simulation

**Why**: not every way of breaking a control-plane node actually
simulates node failure. `docker stop <container>` removes the
container entirely - Envoy's health check fails, DNS can't resolve the
hostname, and the node is genuinely gone from the LB's perspective,
which is what real hardware failure looks like. `docker exec
<container> systemctl stop containerd`, by contrast, does **not**
reproduce failure - `containerd-shim` processes keep every
already-running container (apiserver included) alive independent of
the daemon that started them, so `kube-apiserver` keeps answering
health checks throughout. Only *new* CRI operations (starting or
pulling a container) are affected - an easy trap if you're trying to
demonstrate quorum loss and see nothing happen.

**Example**: try both, and compare what each actually does to cluster
availability and to Envoy's view of that backend:

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

**Expected output**: stopping `containerd` changes nothing observable
- every node, including the one whose `containerd` is down, still
shows `Ready`, because the already-running `kube-apiserver` container
keeps answering independent of the daemon that started it:

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

`docker stop`, by contrast, actually removes the container - and the
cluster stays available throughout (etcd quorum and 2/3 control-plane
capacity both hold), but the stopped node's own `Ready` status does
eventually flip, once its kubelet stops posting heartbeats for longer
than the node-monitor grace period - not instantly:

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

The other 4 nodes stay `Ready` throughout, and `kubectl get nodes`
itself never stops working - this is the whole point of 3
control-plane nodes plus etcd quorum plus a load balancer in front:
losing 1 of 3 degrades nothing observable to a client. Envoy's own view
confirms it noticed independently, faster than the node-status
timeout:

```
$ curl -s http://${LB_IP}:10000/clusters | grep -B1 health_flags
172.19.0.5:6443::health_flags::/failed_active_hc/active_hc_timeout
172.19.0.6:6443::health_flags::healthy
172.19.0.7:6443::health_flags::healthy
```

`172.19.0.5` is `control-plane2` - Envoy's 2-second active health
check marked it unhealthy well before Kubernetes' own node-status
mechanism did, and routes new apiserver requests to the other two
without anything downstream noticing.

### PodDisruptionBudgets: bounding voluntary disruption

**Why**: the previous section's `docker stop` was an *involuntary*
disruption - nothing asked permission, the container just died, and
the cluster's tolerance for it came entirely from etcd quorum and the
LB. A *voluntary* disruption is different in kind, not just cause: a
`kubectl drain` before maintenance, a node upgrade (next section), or
an autoscaler removing a node all go through the **Eviction API**
rather than a Pod just disappearing - and a PodDisruptionBudget (PDB)
is what a workload uses to cap how much of that voluntary disruption
it will tolerate at once, expressed as `minAvailable` or
`maxUnavailable`. Critically, only the Eviction API respects a PDB - a
plain `kubectl delete pod` bypasses it entirely, because deletion and
eviction are different requests even though both end with the Pod
gone.

**Example**: a 3-replica Deployment with a PDB requiring at least 2
available at all times, then two evictions fired in immediate
succession via the raw Eviction API (`kubectl drain`'s underlying
mechanism) - the first should succeed, the second should be refused
before it ever touches the second Pod:

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

**Expected output**: the PDB starts with `ALLOWED DISRUPTIONS: 1` (3
replicas, `minAvailable: 2`), the first eviction succeeds with a
`201`/`Success`, and the second - fired immediately after, before any
replacement Pod has had a chance to become `Ready` - is refused with a
`429`/`TooManyRequests`, citing the exact disruption-budget math:

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

`kubectl get pdb ha-demo-pdb` right after confirms `ALLOWED
DISRUPTIONS` dropped to `0` - the first eviction consumed the entire
budget, which is exactly why the second was refused rather than
merely delayed:

```
$ kubectl get pdb ha-demo-pdb
NAME          MIN AVAILABLE   MAX UNAVAILABLE   ALLOWED DISRUPTIONS   AGE
ha-demo-pdb   2               N/A               0                    10s
```

A `429` isn't a hard permanent failure the way the earlier `403`s in
chapter 9 were - it's a signal to retry later, which is exactly what
`kubectl drain` does internally: it keeps retrying an evict-refused Pod
until the budget allows it (typically once the first eviction's
replacement Pod becomes `Ready` again), rather than treating the
refusal as the end of the operation.

### etcd backup and restore

**Why**: etcd holds the cluster's entire state - every object chapter
2 onward has created lives there, not anywhere else. Losing it is a
categorically different failure from losing a control-plane node
(this chapter's earlier section, which quorum absorbs without any
backup involved at all): a backup is what recovers from etcd itself
being destroyed or corrupted, not from any single node dying.
`snapshot save` takes a point-in-time snapshot of one member's data
into a single file; `snapshot restore` rebuilds a fresh data directory
from that file - but restore isn't "hot": it writes a brand new
directory on disk and doesn't touch a running etcd process at all.
Actually swapping a restored directory in for a live one needs etcd
stopped first (moving its static pod manifest out of
`/etc/kubernetes/manifests/`, so kubelet stops it), the data directory
replaced, and the manifest moved back - real, but higher-risk to
demonstrate against a running lab cluster than the snapshot/restore
mechanism itself is, so this section verifies save-and-restore-to-a-
new-directory live, and describes the live swap as the documented next
step rather than performing it here. One version-specific wrinkle
worth stating rather than assuming away: on this cluster's etcd
(3.6.0), `snapshot status` and `snapshot restore` no longer live under
`etcdctl` at all - they moved to a separate offline tool, `etcdutl`,
shipped in the same container. `etcdctl` still does `snapshot save`
(it talks to a live etcd member over its client API); the other two
operate on a file with etcd stopped, which is a fundamentally
different (offline) operation - splitting them into a separate binary
makes that distinction explicit rather than implicit.

**Example**: take a real snapshot from one etcd member with
`etcdctl`, then use `etcdutl` - not `etcdctl` - for status and
restore into a separate directory, to prove the file is genuinely
valid and restorable:

```
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

**Expected output**: the snapshot saves cleanly, and its `etcdutl`
status check reports real numbers - not placeholders:

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

Running `snapshot status` under `etcdctl` instead - the natural
mistake to make from muscle memory on an older etcd version, where it
did live there - doesn't error at all; it silently prints the
`snapshot` subcommand's help text instead of a status table, which is
a worse failure mode than an error would be, precisely because nothing
about it looks like failure at a glance. `etcdutl snapshot restore` into the new directory
succeeds and produces a real, usable etcd data directory - confirmed
by its contents, `snap/` and `wal/`, the same two subdirectories any
running etcd member's own data directory has:

```
$ kubectl exec -n kube-system etcd-k8s-lab-ha-control-plane-control-plane -- etcdutl \
  snapshot restore /var/lib/etcd-backup-demo.db --data-dir=/var/lib/etcd-restore-test
{"level":"info","msg":"restored snapshot","...","data-dir":"/var/lib/etcd-restore-test"}
```

(Confirming the restored directory's actual contents needed a detour
- the etcd container itself ships no shell and no coreutils at all,
`kubectl exec ... ls` fails the same "executable file not found" way
chapter 10's `pause` container did, so the contents were checked via
the node's own filesystem instead, at `/proc/<container-pid>/root/var/lib/etcd-restore-test/`
- `snap` and `wal` present, exactly as a real etcd data directory
should have.)

`kubectl get nodes` stayed at 5/5 `Ready` throughout every step above
- restoring into a separate directory genuinely never touched the
live, running etcd member.

### Cluster upgrades

**Why**: `kubeadm upgrade` is the real mechanism behind a version
bump, not a rolling image swap you script yourself - it's
version-skew-aware and sequences the work in a fixed order: `kubeadm
upgrade plan` first (a dry run against the currently-running version,
mutates nothing), then `kubeadm upgrade apply <version>` on exactly
*one* control-plane node (rewrites that node's static pod manifests
and waits for the new versions to come up healthy), then `kubeadm
upgrade node` on every *other* control-plane node (syncing to what the
first node already decided, not re-deciding anything), and finally
each node's own kubelet/kubeadm/kubectl packages get upgraded via the
OS package manager - entirely outside kubeadm's control - before that
node's kubelet is restarted and it's uncordoned. Worth checking
directly what `kubeadm upgrade plan` actually does against this
cluster before assuming anything about it, and it's a genuinely good
example of why: the reasonable-sounding assumption going in here was
that `kubeadm upgrade plan` would report nothing available, since this
repo's `kind` node image bakes in exactly one Kubernetes version
(`kindest/node:v1.36.1`, chapter 1's pinning) and doesn't ship any
other version's binaries locally. That assumption turned out to be
wrong, and specifically wrong in a way worth naming: `upgrade plan`
doesn't check what's installed locally at all - it queries the public
Kubernetes release feed over the internet and compares version
numbers, entirely independent of what binaries the node image actually
has on disk to satisfy an upgrade with.

**Example**: run the real, non-mutating first step against this
cluster's actual pinned version:

```
kubectl exec -n kube-system kube-apiserver-<a-control-plane-node-name> -- kube-apiserver --version
docker exec <a-control-plane-container> kubeadm version
docker exec <a-control-plane-container> kubeadm upgrade plan
```

**Expected output**: not "nothing to upgrade" - a real, live-fetched
target version, because the node container has outbound internet
access and `kubeadm upgrade plan` uses it:

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

A real newer patch release (`v1.36.4`) exists upstream and `kubeadm`
found it correctly - it even applied its own minor-version skew policy
on the way, noting a newer `v1.37.0` exists but falling back to the
latest patch within the *current* minor series (`stable-1.36`) rather
than jumping a minor version, which `kubeadm upgrade` never does in
one step by design. Two rows are worth reading carefully rather than
assuming they follow the same pattern as the rest: CoreDNS
(`v1.14.2 -> v1.14.2`) and etcd (`3.6.8-0 -> 3.6.8-0`, matching the
version this chapter's etcd backup/restore section already saw
directly) both show **identical** current and target versions - no
bump proposed for either, because a v1.36.1 -> v1.36.4 patch release
doesn't necessarily require every bundled component to move in
lockstep, only the ones the release actually changed. Nothing about
running inside `kind` blocked or altered any of this: it's the
identical live version-check a real cluster with internet access would
get. What running `kubeadm upgrade apply v1.36.4` here would actually
hit is a different, later failure - the node image has no `v1.36.4`
kubelet/control-plane binaries locally to switch to, since (chapter 1)
this image bakes in exactly one pinned version - but that's a distinct
problem from what `upgrade plan` itself checks, and this section
didn't run `apply` against the live cluster to trigger it, since doing
so has a real chance of leaving a control-plane node in a
half-upgraded state for no additional teaching value beyond what
`plan`'s own real, successful network round-trip already demonstrates.
In an air-gapped or otherwise offline environment, this same command
would instead fail (or hang) trying to reach the release feed - worth
knowing in advance rather than discovering it mid-upgrade on a real
cluster.
