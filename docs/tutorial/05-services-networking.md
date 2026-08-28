# 5. Services and networking

Chapter 3's Deployment gave a stable *set* of Pods, but each Pod's own
IP is still not stable - it's assigned on creation and gone the moment
that Pod is replaced (chapter 3 replaced plenty of Pods along the way).
A Service is Kubernetes' answer to "how do I address a moving target":
a stable virtual IP and/or DNS name that always resolves to whichever
Pods currently match a label selector - the same selector-based
membership model chapter 3 already introduced for ReplicaSets, applied
here to network addressing instead of process supervision. This chapter
covers the Service types in the order you'd actually reach for them,
then Ingress as an L7 layer built on top of a Service rather than a
replacement for one.

### ClusterIP: the default, cluster-internal Service

**Why**: most traffic in a cluster is Pod-to-Pod, and `ClusterIP` (the
default type if you don't set one) is built for exactly that - a stable
virtual IP, reachable only from inside the cluster, that always load-
balances to whichever Pods currently match `spec.selector`. kube-proxy
(chapter 1) is what actually implements this: it watches Services and
Endpoints/EndpointSlices and programs each node's packet handling so
traffic to the virtual IP gets redirected to a real Pod IP, with no
proxy process actually sitting in the data path.

**Example**: `tutorial/examples/services-networking/backend-deployment.yaml`
(3 nginx replicas, `app: services-demo`) backs every Service example in
this chapter. `tutorial/examples/services-networking/clusterip-service.yaml`
selects it:

```
kubectl apply -f tutorial/examples/services-networking/backend-deployment.yaml
kubectl apply -f tutorial/examples/services-networking/clusterip-service.yaml
kubectl get svc services-demo-clusterip
kubectl get endpointslice -l kubernetes.io/service-name=services-demo-clusterip
```

**Expected output**: the EndpointSlice's addresses are exactly the 3
backend Pods' real IPs - not an abstraction, a literal live list kube-
proxy programs into every node's packet handling:

```
NAME                      TYPE        CLUSTER-IP    EXTERNAL-IP   PORT(S)   AGE
services-demo-clusterip   ClusterIP   10.96.3.130   <none>        80/TCP    8s

NAME                            ADDRESSTYPE   PORTS   ENDPOINTS                            AGE
services-demo-clusterip-4frlk   IPv4          80      10.244.2.53,10.244.1.8,10.244.2.54   8s
```

```
$ kubectl get pods -l app=services-demo -o wide
NAME                                    READY   STATUS    RESTARTS   AGE   IP            NODE
services-demo-backend-b848b94c9-8bs8v   1/1     Running   0          9s    10.244.2.54   k8s-lab-default-worker2
services-demo-backend-b848b94c9-jg8hg   1/1     Running   0          9s    10.244.1.8    k8s-lab-default-worker
services-demo-backend-b848b94c9-ktbs9   1/1     Running   0          9s    10.244.2.53   k8s-lab-default-worker2
```

Same three addresses, same order - if a Pod were replaced right now, the
EndpointSlice would update within moments and the ClusterIP itself
wouldn't change at all.

### CoreDNS: turning Service names into addresses

**Why**: a ClusterIP is stable, but still just a number - CoreDNS is
what makes `services-demo-clusterip` (or the fully-qualified
`services-demo-clusterip.default.svc.cluster.local`) resolve to it, so
nothing in-cluster needs to know actual IPs at all. CoreDNS runs as an
ordinary Deployment in `kube-system` (chapter 1 showed it in the static
pod vs. controller-managed distinction - CoreDNS is controller-managed,
not static), configured via a Corefile that lives in the `coredns`
ConfigMap - the same ConfigMap mechanism chapter 4 covered, consumed by
a piece of cluster infrastructure rather than a user workload.

**Example**: resolve the Service by name from inside the cluster, then
look at where that configuration actually comes from:

```
kubectl run services-demo-dns-check --image=busybox:1.36 --restart=Never --rm -i --command -- nslookup services-demo-clusterip
kubectl get configmap coredns -n kube-system -o jsonpath='{.data.Corefile}'
```

**Expected output**: the fully-qualified name resolves to exactly the
ClusterIP from the previous subsection:

```
Server:    10.96.0.10
Address:   10.96.0.10:53

Name:  services-demo-clusterip.default.svc.cluster.local
Address: 10.96.3.130
```

And the Corefile actually driving that - an ordinary ConfigMap, editable
the same way any ConfigMap is, though CoreDNS won't pick up a change
until its Pods restart (`kubectl -n kube-system delete pod -l
k8s-app=kube-dns` is the fast, deterministic way to force that; the
`reload` plugin visible below also polls for changes periodically on its
own):

```
.:53 {
    errors
    health { lameduck 5s }
    ready
    kubernetes cluster.local in-addr.arpa ip6.arpa {
       pods insecure
       fallthrough in-addr.arpa ip6.arpa
       ttl 30
    }
    prometheus :9153
    forward . /etc/resolv.conf { max_concurrent 1000 }
    cache 30 { disable success cluster.local ; disable denial cluster.local }
    loop
    reload
    loadbalance
}
```

### NodePort: exposing a Service on every node's own IP

**Why**: `NodePort` builds on `ClusterIP` (every `NodePort` Service gets
a ClusterIP too) and additionally opens the same port on **every**
node's IP, cluster-wide, in a fixed range (default 30000-32767) -
useful when something outside the cluster needs to reach a Service
without a cloud load balancer or Ingress controller in front. In kind
specifically, that "every node's IP" is each node *container's* IP on
the Docker bridge network, not the Docker host - so `curl
localhost:<nodePort>` from the host does **not** work, a real point of
confusion coming from a VM-based cluster where the node IP and a
reachable host IP are the same thing. This repo's ingress hostPort setup
(DESIGN.md, "Ingress: hostPort + node pinning") exists specifically
because relying on NodePort reachability from the host doesn't work
here.

**Example**: `tutorial/examples/services-networking/nodeport-service.yaml`
exposes the same backend as a NodePort. Try reaching it from the host
directly (expected to fail), then two ways that actually work from
outside a Pod's own network namespace:

```
kubectl apply -f tutorial/examples/services-networking/nodeport-service.yaml
kubectl get svc services-demo-nodeport
curl -sS -m 3 localhost:<nodePort>                          # from the Docker host - expected to fail
kubectl port-forward svc/services-demo-nodeport 18080:80 &
curl -sS localhost:18080                                      # via port-forward - works
docker exec <a-node-container> curl -sS localhost:<nodePort>  # via the node container itself - works
```

**Expected output**: the direct host curl genuinely fails - not a typo,
not a firewall issue, just that `localhost:<nodePort>` on the Docker
host was never anything the NodePort setup touches:

```
NAME                     TYPE       CLUSTER-IP     EXTERNAL-IP   PORT(S)        AGE
services-demo-nodeport   NodePort   10.96.140.25   <none>        80:32136/TCP   0s

$ curl -sS -m 3 localhost:32136
curl: (7) Failed to connect to localhost:32136 after 0 ms: Could not connect to server
```

Both of the other two paths reach real nginx content - `port-forward`
tunnels straight to a Pod regardless of any port mapping, and the node
*container* really does have the NodePort open on its own loopback,
just not the Docker host's:

```
$ kubectl port-forward svc/services-demo-nodeport 18080:80 &
Forwarding from 127.0.0.1:18080 -> 80
$ curl -sS localhost:18080
<!DOCTYPE html>...<title>Welcome to nginx!</title>...

$ docker exec k8s-lab-default-worker2 curl -sS -m 3 localhost:32136
<!DOCTYPE html>...<title>Welcome to nginx!</title>...
```

### LoadBalancer: requesting a cloud load balancer kind can't provide

**Why**: `LoadBalancer` builds on `NodePort` the same way `NodePort`
builds on `ClusterIP` - it additionally asks whatever cloud provider
integration is running in the cluster to provision an external load
balancer and populate `status.loadBalancer`. kind has no such
integration by default (no MetalLB, no cloud controller manager), so
that provisioning step simply never happens - the Service object is
valid and functions exactly like a `NodePort` underneath, it just sits
waiting for an external IP that nothing will ever assign.

**Example**: this repo's own `ingress-nginx-controller` Service (applied
by every profile's `manifests.txt`) is already `type: LoadBalancer` -
real evidence already sitting in the cluster, not just this chapter's
own demo object:

```
kubectl get svc -n ingress-nginx ingress-nginx-controller
kubectl apply -f tutorial/examples/services-networking/loadbalancer-service.yaml
kubectl get svc services-demo-loadbalancer
```

**Expected output**: `ingress-nginx-controller` has sat `<pending>` for
this entire tutorial session (17h at time of capture) - it's not a
transient startup state, it's permanent in this environment. The demo
Service hits the identical state within seconds of being created, with
a NodePort auto-assigned underneath exactly like the previous
subsection:

```
NAME                       TYPE           CLUSTER-IP     EXTERNAL-IP   PORT(S)                      AGE
ingress-nginx-controller   LoadBalancer   10.96.198.99   <pending>     80:32579/TCP,443:31995/TCP   17h

NAME                         TYPE           CLUSTER-IP      EXTERNAL-IP   PORT(S)        AGE
services-demo-loadbalancer   LoadBalancer   10.96.211.147   <pending>     80:32718/TCP   12s
```

### Ingress: L7 routing on top of a Service

**Why**: a Service (any type above) is L4 - IPs and ports, no awareness
of HTTP paths or hostnames. Running one `LoadBalancer` or `NodePort` per
application doesn't scale past a handful of services, and doesn't give
you host/path-based routing at all. Ingress is a separate API for
exactly that: rules mapping hostnames/paths to backend Services, with
TLS termination, all fronted by a single entry point. Critically, an
`Ingress` **object** is inert on its own - it does nothing without a
running **Ingress Controller** watching for it (the same "the object is
just declared state, a controller does the work" pattern as everything
else in this tutorial). This repo already runs one: ingress-nginx,
applied via `manifests/ingress/ingress-nginx.yaml`, node-pinned per
DESIGN.md's "Ingress: hostPort + node pinning" so it's actually reachable
at `localhost:80` on the Docker host. `spec.ingressClassName` (not the
old `kubernetes.io/ingress.class` annotation, deprecated since 1.18/1.22
and no longer read) is what ties an `Ingress` object to a specific
controller when more than one might be running - here, `nginx`, matching
the `IngressClass` that manifest creates.

**Example**: `tutorial/examples/services-networking/ingress.yaml` routes
`/` to `services-demo-clusterip`:

```
kubectl apply -f tutorial/examples/services-networking/ingress.yaml
kubectl get ingress services-demo-ingress
curl -sS localhost/
```

**Expected output**: `CLASS` populates correctly from
`ingressClassName`, and the full path - Ingress -> ingress-nginx ->
ClusterIP Service -> Pod - actually works, real nginx content served
back through port 80 on the Docker host:

```
NAME                    CLASS   HOSTS   ADDRESS   PORTS   AGE
services-demo-ingress   nginx   *                 80      28s

$ curl -sS -m 5 localhost/
<!DOCTYPE html>...<title>Welcome to nginx!</title>...
```

`ADDRESS` stays blank even after nearly 30 seconds, and that's expected
here rather than something slow to propagate: ingress-nginx populates it
from its own controller Service's load-balancer status, and that Service
is the same one this chapter's LoadBalancer subsection just showed
sitting `<pending>` indefinitely. No cloud IP ever arrives for the
controller itself, so no `ADDRESS` ever arrives on any Ingress it's
serving, no matter how long you wait - worth knowing so a blank
`ADDRESS` column doesn't get mistaken for something broken when `curl`
already proves the routing itself works.
