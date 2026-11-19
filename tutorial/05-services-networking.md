# 5. Services and networking

A Deployment (chapter 3) keeps a set of Pods running, but each Pod's IP
address changes whenever the Pod is replaced. A **Service** gives a set
of Pods one address that doesn't change: a virtual IP and a DNS name
that always lead to whichever Pods currently match its label selector,
the same kind of selector a ReplicaSet uses.

This chapter starts one level lower, with the network plugin that gives
each Pod its IP address in the first place. Then it covers the Service
types, in the order you'd usually need them, and finally Ingress, which
routes HTTP requests by path and host name to Services.

### CNI: how a Pod gets an IP in the first place

**Why**: chapter 1 mentioned a **CNI plugin** on every node. CNI
(Container Network Interface) is a standard way for container runtimes
to set up networking; it isn't specific to Kubernetes. Whenever the
kubelet creates a Pod, it calls the CNI plugin installed on the node
(programs in `/opt/cni/bin`, configured in `/etc/cni/net.d`). The plugin
gives the Pod an IP address and connects its network interface.

Which plugin is used depends on how the cluster was set up: Calico,
Cilium, kindnetd and many others all implement the same interface in
different ways. Everything else in this chapter only assumes that every
Pod has an IP address and that Pods can reach each other at those
addresses.

**Example**: this repo's `default` profile uses **kindnetd**, kind's own
CNI. It's small, and built from standard CNI plugins:

```
docker exec k8s-lab-default-worker cat /etc/cni/net.d/10-kindnet.conflist
docker exec k8s-lab-default-worker ls /opt/cni/bin/
kubectl get daemonset -n kube-system kindnet
```

**Expected output**: the configuration chains two standard plugins.
`ptp` creates the Pod's network interface, and `host-local` assigns it
an IP address from this node's share of the cluster's Pod addresses.
There's also a `kindnet` Pod on every node, run by a DaemonSet (a
workload type with one Pod per node, covered in chapter 6):

```json
{
	"cniVersion": "0.3.1",
	"name": "kindnet",
	"plugins": [
	{
		"type": "ptp",
		"ipMasq": false,
		"ipam": {
			"type": "host-local",
			"dataDir": "/run/cni-ipam-state",
			"routes": [
				
				
				{ "dst": "0.0.0.0/0" }
			],
			"ranges": [
				
				
				[ { "subnet": "10.244.2.0/24" } ]
			]
		}
		,
		"mtu": 1500
		
	},
	{
		"type": "portmap",
		"capabilities": {
			"portMappings": true
		}
	}
	]
}
host-local
loopback
portmap
ptp
NAME      DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE   NODE SELECTOR            AGE
kindnet   3         3         3       3            3           kubernetes.io/os=linux   22m
```

(The third plugin, `portmap`, handles `hostPort`, which this repo's
ingress uses.) `10.244.2.0/24` is this node's share of the Pod
addresses. `ptp` and `host-local` are enough for Pods on the same node
to reach each other. To reach a Pod on another node, the node needs a
route to that node's addresses, and that's what the `kindnet` Pods
add:

```
docker exec k8s-lab-default-worker ip route
```

```
default via 172.18.0.1 dev eth0 
10.244.0.0/24 via 172.18.0.4 dev eth0 
10.244.1.0/24 via 172.18.0.3 dev eth0 
172.18.0.0/16 dev eth0 proto kernel scope link src 172.18.0.2 
```

The two routes that matter are `10.244.0.0/24 via 172.18.0.4` and
`10.244.1.0/24 via 172.18.0.3`: one for each other node, through that
node's container IP on the Docker network. The kindnet Pods keep these
routes up to date. (Once Pods run on this node, there's also a route
for each of them, through its own network interface.) Other CNIs solve
the same problem in completely different ways (BGP, overlay networks
such as VXLAN, eBPF), which is why chapter 9 tests NetworkPolicy on
both kindnetd and Calico rather than assuming they behave the same.

### ClusterIP: the default, cluster-internal Service

**Why**: most traffic in a cluster goes from Pod to Pod. A `ClusterIP`
Service, the default type, is for that: a virtual IP that can only be
reached from inside the cluster, and that spreads connections over the
Pods matching `spec.selector`. kube-proxy (chapter 1) makes it work: it
watches Services and their endpoints (the IPs of the matching Pods) and
sets up packet rules on every node that redirect traffic for the
virtual IP to one of those Pods. No proxy process sits in between.

**Example**: [`backend-deployment.yaml`](examples/services-networking/backend-deployment.yaml)
runs 3 nginx replicas labelled `app: services-demo`, the backend for
every Service in this chapter.
[`clusterip-service.yaml`](examples/services-networking/clusterip-service.yaml)
selects them:

```
kubectl apply -f tutorial/examples/services-networking/backend-deployment.yaml
kubectl apply -f tutorial/examples/services-networking/clusterip-service.yaml
```

When the Pods are running (`kubectl rollout status
deploy/services-demo-backend`), look at the Service, its EndpointSlice
and the Pods:

```
kubectl get svc services-demo-clusterip
kubectl get endpointslice -l kubernetes.io/service-name=services-demo-clusterip
kubectl get pods -l app=services-demo -o wide
```

**Expected output**: the Service's virtual IP, and an **EndpointSlice**
listing the IPs of the 3 backend Pods. kube-proxy reads that list:

```
NAME                      TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)   AGE
services-demo-clusterip   ClusterIP   10.96.162.176   <none>        80/TCP    4s
NAME                            ADDRESSTYPE   PORTS   ENDPOINTS                             AGE
services-demo-clusterip-bx8nr   IPv4          80      10.244.2.35,10.244.1.14,10.244.2.36   3s
NAME                                    READY   STATUS    RESTARTS   AGE   IP            NODE                      NOMINATED NODE   READINESS GATES
services-demo-backend-b848b94c9-9lbgc   1/1     Running   0          5s    10.244.2.36   k8s-lab-default-worker    <none>           <none>
services-demo-backend-b848b94c9-dvxks   1/1     Running   0          5s    10.244.2.35   k8s-lab-default-worker    <none>           <none>
services-demo-backend-b848b94c9-vghrl   1/1     Running   0          5s    10.244.1.14   k8s-lab-default-worker2   <none>           <none>
```

The same three addresses. If a Pod were replaced now, the EndpointSlice
would be updated within moments, and the Service's IP wouldn't
change.

**EndpointSlice and Endpoints**: older material uses the `Endpoints`
object (`kubectl get endpoints`, or `ep`). You can still read it, but
the API warns you not to:

```
kubectl get endpoints services-demo-clusterip
```

```
Warning: v1 Endpoints is deprecated in v1.33+; use discovery.k8s.io/v1 EndpointSlice
NAME                      ENDPOINTS                                      AGE
services-demo-clusterip   10.244.1.14:80,10.244.2.35:80,10.244.2.36:80   4s
```

The reason is scale. A Service has a single `Endpoints` object holding
every address. In a large Service, adding or removing one Pod means
rewriting the whole object and sending all of it to kube-proxy on every
node. EndpointSlices split the addresses over several objects (up to
100 addresses each by default), each labelled
`kubernetes.io/service-name` with its Service's name, as used in the
`-l` selector above. A change to one Pod only touches one slice.
`endpoints` still works for now; the warning is a deprecation notice,
not a removal.

### CoreDNS: turning Service names into addresses

**Why**: a Service's IP is stable, but nobody wants to write IPs into
configuration. **CoreDNS**, the cluster's DNS server, resolves a
Service's name, `services-demo-clusterip` or in full
`services-demo-clusterip.default.svc.cluster.local`, to its IP. CoreDNS
runs as an ordinary Deployment in `kube-system`. Its configuration, the
**Corefile**, is stored in the `coredns` ConfigMap (chapter 4).

**Example**: to look names up from inside the cluster, start a busybox
Pod that just sleeps, as a client. This chapter uses it a few times:

```
kubectl run services-demo-client --image=busybox:1.36 --command -- sleep 3600
```

When it's running, look up the Service's full name from it, then look
at the Corefile:

```
kubectl exec services-demo-client -- nslookup services-demo-clusterip.default.svc.cluster.local
kubectl get configmap coredns -n kube-system -o jsonpath='{.data.Corefile}'
```

**Expected output**: the name resolves to the Service's IP from the
previous section:

```
Server:		10.96.0.10
Address:	10.96.0.10:53


Name:	services-demo-clusterip.default.svc.cluster.local
Address: 10.96.162.176

```

A Pod in the `default` namespace can also use the short name,
`services-demo-clusterip`: its DNS settings add the namespace's
domains to short names. busybox's `nslookup` prints a
`can't find ... NXDOMAIN` line for each domain it tries first, which is
why the full name gives cleaner output here.

The Corefile is a list of plugins, each handling part of the work: the
`kubernetes` plugin answers for cluster names, `forward` sends other
names to the node's DNS servers, and so on. You can edit the ConfigMap
like any other. The `reload` plugin picks up changes after a while;
restarting the CoreDNS Pods (`kubectl -n kube-system delete pod -l
k8s-app=kube-dns`) applies them straight away:

```
.:53 {
    errors
    health {
       lameduck 5s
    }
    ready
    kubernetes cluster.local in-addr.arpa ip6.arpa {
       pods insecure
       fallthrough in-addr.arpa ip6.arpa
       ttl 30
    }
    prometheus :9153
    forward . /etc/resolv.conf {
       max_concurrent 1000
    }
    cache 30 {
       disable success cluster.local
       disable denial cluster.local
    }
    loop
    reload
    loadbalance
}
```

### NodePort: exposing a Service on every node's own IP

**Why**: a `NodePort` Service is a ClusterIP Service that is also
reachable on one port, from the range 30000-32767 by default, on
**every** node's IP. That's a way in from outside the cluster without a
cloud load balancer or an Ingress controller.

In kind, a node's IP is its Docker container's IP on the Docker
network, not your host's. So `curl localhost:<nodePort>` on your host
does **not** work. That's confusing if you're used to clusters on VMs,
where the node's IP is one you can reach. It's also why this repo
reaches ingress-nginx through ports published on one node container
instead (DESIGN.md, "Ingress: hostPort + node pinning").

**Example**: [`nodeport-service.yaml`](examples/services-networking/nodeport-service.yaml)
exposes the same backend as a NodePort:

```
kubectl apply -f tutorial/examples/services-networking/nodeport-service.yaml
kubectl get svc services-demo-nodeport
```

```
service/services-demo-nodeport created
NAME                     TYPE       CLUSTER-IP      EXTERNAL-IP   PORT(S)        AGE
services-demo-nodeport   NodePort   10.96.206.162   <none>        80:31512/TCP   0s
```

`80:31512/TCP` means the Service's port 80 is also open on port 31512
of every node. Yours will probably be a different number; use it below.
Try it from your host:

```
curl -sS -m 3 localhost:31512
```

**Expected output**: it fails, because nothing on your host listens on
that port:

```
curl: (7) Failed to connect to localhost:31512 after 0 ms: Could not connect to server
```

Two ways that work. `port-forward` connects you straight to a Pod
through the API server; run it in the background with `&`, fetch the
page, then stop it:

```
kubectl port-forward svc/services-demo-nodeport 18080:80 &
curl -sS localhost:18080 | head -4
kill %1
```

```
Forwarding from 127.0.0.1:18080 -> 80
Forwarding from [::1]:18080 -> 80
Handling connection for 18080
<!DOCTYPE html>
<html>
<head>
<title>Welcome to nginx!</title>
```

And inside a node container, the NodePort is open:

```
docker exec k8s-lab-default-worker2 curl -sS -m 3 localhost:31512 | head -4
```

```
<!DOCTYPE html>
<html>
<head>
<title>Welcome to nginx!</title>
```

### LoadBalancer: requesting a cloud load balancer kind can't provide

**Why**: a `LoadBalancer` Service is a NodePort Service that also asks
the cloud provider for an external load balancer, whose address is then
written into the Service's `status.loadBalancer`. kind has nothing that
provides load balancers (no cloud controller, no MetalLB), so the
request is never fulfilled. The Service works as a NodePort, but its
external IP stays `<pending>` for good.

**Example**: this repo's `ingress-nginx-controller` Service, installed by
every profile, is already `type: LoadBalancer`. Look at it, then create
one of your own:

```
kubectl get svc -n ingress-nginx ingress-nginx-controller
kubectl apply -f tutorial/examples/services-networking/loadbalancer-service.yaml
kubectl get svc services-demo-loadbalancer
```

**Expected output**: `ingress-nginx-controller` has been `<pending>`
since the cluster was created, and it won't change. The new Service is
the same, with a NodePort assigned, as in the previous section:

```
NAME                       TYPE           CLUSTER-IP      EXTERNAL-IP   PORT(S)                      AGE
ingress-nginx-controller   LoadBalancer   10.96.213.231   <pending>     80:30912/TCP,443:31626/TCP   22m
service/services-demo-loadbalancer created
NAME                         TYPE           CLUSTER-IP     EXTERNAL-IP   PORT(S)        AGE
services-demo-loadbalancer   LoadBalancer   10.96.228.45   <pending>     80:31806/TCP   0s
```

### ExternalName: a Service that's really just a DNS alias

**Why**: an `ExternalName` Service has no selector, no Pods and no IP.
It's only a DNS alias: looking up its name returns a `CNAME` record
pointing at the host name in `spec.externalName`. Use it to give
something outside the cluster, such as a managed database, a name
inside the cluster, so that applications don't have to contain the
real host name. It also works the other way round, as in the example
below: during a migration, one name inside the cluster can point at
another.

**Example**: [`externalname-service.yaml`](examples/services-networking/externalname-service.yaml)
points `services-demo-externalname` at
`services-demo-clusterip.default.svc.cluster.local`, standing in for an
external host:

```
kubectl apply -f tutorial/examples/services-networking/externalname-service.yaml
kubectl get svc services-demo-externalname
kubectl exec services-demo-client -- nslookup services-demo-externalname.default.svc.cluster.local
```

**Expected output**: `CLUSTER-IP` is `<none>`: there's no virtual IP.
The DNS answer is a `CNAME` naming the other Service, which then
resolves to that Service's IP:

```
service/services-demo-externalname created
NAME                         TYPE           CLUSTER-IP   EXTERNAL-IP                                         PORT(S)   AGE
services-demo-externalname   ExternalName   <none>       services-demo-clusterip.default.svc.cluster.local   <none>    0s
Server:		10.96.0.10
Address:	10.96.0.10:53


services-demo-externalname.default.svc.cluster.local	canonical name = services-demo-clusterip.default.svc.cluster.local
Name:	services-demo-clusterip.default.svc.cluster.local
Address: 10.96.162.176

```

kube-proxy isn't involved: there's no virtual IP and no EndpointSlice,
only a DNS answer from CoreDNS. That's also the limitation. If the
target is outside the cluster, the client must be able to resolve and
reach it itself. `ExternalName` only provides the name, not a
connection.

### Ingress: HTTP routing to Services

**Why**: Services work with IP addresses and ports (layer 4). They know
nothing about HTTP paths or host names. One `NodePort` or
`LoadBalancer` per application quickly gets unwieldy. **Ingress** is a
separate API for HTTP (layer 7): rules that send requests to Services
by host name and path, with TLS if needed, all through one entry point.

An Ingress object does nothing by itself. An **Ingress controller**
watches Ingress objects and does the routing, the same pattern as
every other controller in this tutorial. This repo runs ingress-nginx
(`manifests/ingress/ingress-nginx.yaml`), set up so you can reach it at
`localhost:80` on your host (DESIGN.md, "Ingress: hostPort + node
pinning"). `spec.ingressClassName` says which controller handles an
Ingress, here `nginx`. Older material uses the
`kubernetes.io/ingress.class` annotation instead, which is no longer
read.

**Example**: [`ingress.yaml`](examples/services-networking/ingress.yaml)
sends `/` to `services-demo-clusterip`:

```
kubectl apply -f tutorial/examples/services-networking/ingress.yaml
kubectl get ingress services-demo-ingress
curl -sS -m 5 localhost/ | head -4
```

**Expected output**: `CLASS` is `nginx`, and the request goes all the way
through: your host's port 80, ingress-nginx, the Service, a Pod. (If
the first `curl` fails, give ingress-nginx a few seconds to pick up the
new Ingress.)

```
ingress.networking.k8s.io/services-demo-ingress created
NAME                    CLASS   HOSTS   ADDRESS   PORTS   AGE
services-demo-ingress   nginx   *                 80      0s
<!DOCTYPE html>
<html>
<head>
<title>Welcome to nginx!</title>
```

`ADDRESS` stays empty, and that's expected. ingress-nginx copies it
from its own Service's external IP, which is the `<pending>`
LoadBalancer from earlier. It never gets one here, so `ADDRESS` stays
empty however long you wait. The `curl` shows that routing works
anyway.

### Extending the Corefile: the `rewrite` plugin

**This section is optional.** Nothing later in the tutorial depends on
it.

**Why**: the Corefile is a chain of plugins that each query passes
through from top to bottom. The `rewrite` plugin can change the name in
a query before the `kubernetes` plugin sees it, and, with
`answer name`, change it back in the response. One use is to keep an
old Service name working after a rename, so clients can be updated one
at a time. Unlike an `ExternalName` Service, it applies to every query
CoreDNS answers.

**Example**: [`corefile-rewrite.txt`](examples/services-networking/corefile-rewrite.txt)
adds a `rewrite` rule before the `kubernetes` plugin, which makes the
name `legacy-backend` resolve to `services-demo-clusterip`. The
`coredns` ConfigMap comes with the cluster, so save a copy of the
original first:

```
kubectl get configmap coredns -n kube-system -o jsonpath='{.data.Corefile}' > /tmp/coredns-corefile-original.txt
kubectl create configmap coredns -n kube-system \
  --from-file=Corefile=tutorial/examples/services-networking/corefile-rewrite.txt \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n kube-system delete pod -l k8s-app=kube-dns
```

**Expected output**: `kubectl apply` warns that the ConfigMap wasn't
created with `kubectl apply` (it came with the cluster) and fixes that
itself. Then the CoreDNS Pods are restarted:

```
Warning: resource configmaps/coredns is missing the kubectl.kubernetes.io/last-applied-configuration annotation which is required by kubectl apply. kubectl apply should only be used on resources created declaratively by either kubectl create --save-config or kubectl apply. The missing annotation will be patched automatically.
configmap/coredns configured
pod "coredns-589f44dc88-7x6dq" deleted from kube-system namespace
pod "coredns-589f44dc88-b2b6r" deleted from kube-system namespace
```

A few seconds later, look up the old name:

```
kubectl exec services-demo-client -- nslookup legacy-backend.default.svc.cluster.local
```

**Expected output**: no Service called `legacy-backend` exists, but the
name resolves, because of the rewrite rule, to
`services-demo-clusterip`'s IP. There's no `CNAME` in the answer:
`answer name` changed the name in the response back to the one you
asked for:

```
Server:		10.96.0.10
Address:	10.96.0.10:53


Name:	legacy-backend.default.svc.cluster.local
Address: 10.96.162.176

```

When you're done, restore the original Corefile from your copy and
restart CoreDNS again:

```
kubectl create configmap coredns -n kube-system --from-file=Corefile=/tmp/coredns-corefile-original.txt --dry-run=client -o yaml | kubectl apply -f -
kubectl -n kube-system delete pod -l k8s-app=kube-dns
```

A few seconds later, `legacy-backend` no longer resolves:

```
kubectl exec services-demo-client -- nslookup legacy-backend.default.svc.cluster.local
```

```
Server:		10.96.0.10
Address:	10.96.0.10:53

** server can't find legacy-backend.default.svc.cluster.local: NXDOMAIN

** server can't find legacy-backend.default.svc.cluster.local: NXDOMAIN

command terminated with exit code 1
```

### Cleaning up

Delete the busybox client. The backend, the Services and the Ingress
can stay: later chapters don't depend on them, and chapter 13's Ingress
uses a different path, so the two don't clash.

```
kubectl delete pod services-demo-client
```
