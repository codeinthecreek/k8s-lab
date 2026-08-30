# 11. High availability and cluster operations

Every chapter so far ran against a single-control-plane cluster, where
"the control plane" and "one node" were interchangeable. This capstone
chapter breaks that assumption: `ha-control-plane` runs 3 control-plane
nodes and asks what changes when there are three of everything -
apiserver, scheduler, controller-manager, and a member of etcd. The
short answer is: less than it looks like, because a load balancer and
etcd's own consensus protocol absorb almost all of the difference, and
almost everything from chapters 1-10 still applies unchanged underneath.

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
