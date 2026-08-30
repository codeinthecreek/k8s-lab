# 12. From source code to a running workload

Chapters 1-11 all start from the same place: a manifest or an image
already exists, and the question is how the cluster behaves once it's
there. This chapter covers the seam before that - the part every prior
chapter quietly assumed was already handled: taking your own application
source code and getting it into something a Deployment can actually run.
That's a structurally different journey than "given a running cluster,
how does object X behave," which is why it gets its own chapter instead
of being folded into workloads, configuration, or networking - even
though by the end it leans directly on all three (chapters 3, 4, and 5).

The worked example: a minimal Python HTTP service
(`tutorial/examples/app-deployment/app/`), built into a container image,
pushed to a registry the cluster can actually reach, deployed with a
Deployment + Service + Ingress + ConfigMap, and updated with a real
rolling update triggered by a real source code change. This is
deliberately **not** a survey of container-build best practices -
multi-stage builds, distroless base images, layer-caching strategy - that
belongs to a different skill than "get code running on this cluster,"
which is all this chapter covers.

### The app and its Dockerfile

**Why**: the running example needs to be small enough that the Dockerfile
and the build/push/deploy mechanics stay the focus, not the app itself.
A single-file Python HTTP service using only the standard library
(`http.server`) means no dependency layer, no package manager, nothing to
debug except the one thing this chapter is actually about.

**Example**: `tutorial/examples/app-deployment/app/app.py`, as first
written:

```python
import http.server
import os

CODE_VERSION = "v1"
GREETING = os.environ.get("GREETING", "hello")


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.end_headers()
        body = f"{GREETING} from app-deployment-demo {CODE_VERSION}\n"
        self.wfile.write(body.encode())


if __name__ == "__main__":
    http.server.HTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
```

`GREETING` comes from an environment variable (chapter 4's ConfigMap
mechanism feeds it later in this chapter); `CODE_VERSION` is a plain
constant in the source - deliberately, so a real code change later means
editing this file, not just changing an env var.
`tutorial/examples/app-deployment/app/Dockerfile`:

```dockerfile
FROM python:3.13-slim
COPY app.py /app.py
EXPOSE 8080
CMD ["python3", "/app.py"]
```

```
docker build -t app-deployment-demo:v1 .
docker run --rm -d --name app-deployment-demo-smoketest -p 18080:8080 -e GREETING=hi app-deployment-demo:v1
curl -sS localhost:18080
docker rm -f app-deployment-demo-smoketest
```

**Expected output**: a plain-text response with the env var substituted
in, proving the image works before anything touches Kubernetes:

```
Successfully tagged app-deployment-demo:v1

hi from app-deployment-demo v1
```

### Getting a locally-built image into kind: a real registry, not `kind load docker-image`

**Why**: kind clusters run as Docker containers with their own
containerd, isolated from the Docker host's own image store - `docker
build` on the host doesn't make an image visible to a node's kubelet by
itself, and a kind cluster can't reach `localhost:<port>` on the host the
way a normal remote cluster reaches a registry (`localhost` inside a node
container means that container's own loopback, not the Docker host's -
the same distinction chapter 5 covers for NodePort). kind ships a
built-in shortcut for this, `kind load docker-image`, which imports an
image directly into every node's containerd content store with no
registry involved at all. It's genuinely useful for quick iteration, but
it has a real limitation worth knowing up front rather than discovering
later: it's a one-time content-store injection, not something a running
cluster can re-check or re-pull from, which breaks `imagePullPolicy:
Always` outright - shown below - and doesn't reflect how any real
non-kind cluster gets images at all. **A local registry container is the
version-current, closer-to-real-workflow answer**, and it's what kind's
own docs recommend: `lab-helpers/registry` runs a real `registry:3`
container on the `kind` Docker network, with containerd on every node
configured (via each profile's `cluster.yaml`) to redirect
`localhost:5001/<image>` pulls to it - see `lab-helpers/registry/README.md`
and DESIGN.md's "Local registry: containerd config_path patch" for the
full mechanics, including a real surprise hit while verifying this: kind's
own example script claims its containerd config patch is unnecessary on
node images from kind v0.27.0+, which turned out **not** to be true for
this repo's pinned `kindest/node:v1.36.1` - checked directly with `docker
exec <node> cat /etc/containerd/config.toml` rather than trusting the
comment.

**Example**: bring the registry up once (profile-independent, like
`lab-helpers/nfs-server`), wire up whichever profile you're using, then
build/tag/push exactly as you would against any real registry:

```
make registry-up
make registry-client-install PROFILE=default
docker tag app-deployment-demo:v1 localhost:5001/app-deployment-demo:v1
docker push localhost:5001/app-deployment-demo:v1
```

**Expected output**: a normal registry push - no kind-specific tooling
involved at this point, which is the point:

```
k8s-lab-registry started - run 'make registry-client-install PROFILE=x' before pulling from it on that profile
--- k8s-lab-default-worker ---
--- k8s-lab-default-control-plane ---
--- k8s-lab-default-worker2 ---
configmap/local-registry-hosting created

The push refers to repository [localhost:5001/app-deployment-demo]
v1: digest: sha256:e6d5b562d2fa242d98e1fff13d484fbc3d19aa9831389f5bc8ab6fa14e96db93 size: 1366
```

Confirm a Pod can actually pull it - not just that the push succeeded:

```
kubectl run registry-smoketest --image=localhost:5001/app-deployment-demo:v1 --restart=Never --port=8080 -- python3 /app.py
kubectl get pod registry-smoketest -o wide
```

```
NAME                 READY   STATUS    RESTARTS   AGE   IP           NODE
registry-smoketest   1/1     Running   0          8s    10.244.2.4   k8s-lab-default-worker2
```

A real pull, end to end, through the registry container over the `kind`
Docker network - not a `kind load` shortcut standing in for one.

### imagePullPolicy: two ways it silently breaks

**Why**: `imagePullPolicy` decides whether kubelet trusts an
already-cached local image or re-checks the registry, and getting this
wrong fails in two opposite, both-silent-until-you-look-closely ways
depending on which policy you picked and where the image actually came
from. This matters far more for a locally-built/tagged image than a
public one, because a public image's tag (`nginx:1.27`) is conventionally
immutable - nobody re-pushes different content under an existing public
tag - while a locally-built image under active development gets rebuilt
under the *same* tag constantly, by design, during iteration.

**Example 1 - `Always` against an image that was never actually pushed
anywhere**: `kind load docker-image` (previous section's "shortcut," not
the registry) puts bits on the node without a registry backing the
reference at all:

```
kind load docker-image app-deployment-demo:v1 --name k8s-lab-default
kubectl run pullpolicy-always-demo --image=app-deployment-demo:v1 --image-pull-policy=Always --restart=Never -- python3 /app.py
kubectl describe pod pullpolicy-always-demo
```

**Expected output**: `Always` doesn't fall back to the already-present
local copy when its registry check fails - and an unqualified image name
defaults to `docker.io/library/<name>`, a registry that has no idea this
image exists:

```
Normal   Pulling    4s    kubelet   Pulling image "app-deployment-demo:v1"
Warning  Failed     2s    kubelet   Failed to pull image "app-deployment-demo:v1": failed to pull and unpack
image "docker.io/library/app-deployment-demo:v1": failed to resolve reference
"docker.io/library/app-deployment-demo:v1": pull access denied, repository does
not exist or may require authorization: server message: insufficient_scope:
authorization failed
Normal   BackOff    1s    kubelet   Back-off pulling image "app-deployment-demo:v1"
Warning  Failed     1s    kubelet   Error: ImagePullBackOff
```

The image is sitting right there in the node's containerd content store -
`kind load` put it there seconds earlier - and `Always` fails anyway,
because it never even checks the local cache once it decides a pull is
required. This is the concrete case for the registry approach above: a
`localhost:5001/...`-qualified image has somewhere real to answer that
check.

**Example 2 - `IfNotPresent` silently serving stale code after a
same-tag rebuild**: pin a Pod to one node, let it pull the registry-backed
image normally, then rebuild the image with different content but push
it under the exact same tag - a common real mistake during iteration,
forgetting to bump the tag:

```
kubectl run pullpolicy-ifnotpresent-demo --image=localhost:5001/app-deployment-demo:v1 --image-pull-policy=IfNotPresent --restart=Never --overrides='{"spec":{"nodeName":"k8s-lab-default-worker"}}' -- python3 /app.py
```

```
Normal  Pulling  5s  kubelet  Pulling image "localhost:5001/app-deployment-demo:v1"
Normal  Pulled   3s  kubelet  Successfully pulled image "localhost:5001/app-deployment-demo:v1" in 2.225s
```

Now edit `app.py` to add `(updated!)` to the response text, rebuild,
retag as the same `v1`, and push again - a genuinely different image
digest under an unchanged tag:

```
docker build -t app-deployment-demo:v1 .
docker tag app-deployment-demo:v1 localhost:5001/app-deployment-demo:v1
docker push localhost:5001/app-deployment-demo:v1
```

```
v1: digest: sha256:1870d79c0ba5e9f3e8e14eda98fde847ec641358bed3a7767f17e1c13453881e size: 1366
```

Delete and recreate the same demo Pod, pinned to the same node, still
`IfNotPresent`:

```
kubectl delete pod pullpolicy-ifnotpresent-demo
kubectl run pullpolicy-ifnotpresent-demo --image=localhost:5001/app-deployment-demo:v1 --image-pull-policy=IfNotPresent --restart=Never --overrides='{"spec":{"nodeName":"k8s-lab-default-worker"}}' -- python3 /app.py
kubectl describe pod pullpolicy-ifnotpresent-demo
```

**Expected output**: no pull attempted at all, and the Pod serves the
**old** content, silently - the registry has genuinely different bits
under `v1` now, and this node will never notice:

```
Normal  Pulled   4s  kubelet  Container image "localhost:5001/app-deployment-demo:v1" already present on machine and can be accessed by the pod
```

```
$ curl -sS <pod-ip>:8080
hello from app-deployment-demo v1
```

No `(updated!)`. `IfNotPresent` checks whether *a* local image matches
the reference string, not whether it matches what the registry currently
has behind that tag - so once a node has pulled a given tag once, that
node is done checking, forever, until the tag is deleted from its local
cache some other way. Switching that same Deployment back to `Always`
and rolling it (verified separately, same cluster) does pick up the new
digest correctly on both nodes - `Always` is the fix for exactly this
failure mode, at the cost of the registry-reachability requirement Example
1 showed. Neither policy is "safer" in general; they fail in opposite
directions depending on what's actually backing the image reference.

### Deployment, Service, Ingress, ConfigMap: tying it together

**Why**: none of this is new API surface - a Deployment (chapter 3), a
ConfigMap consumed via `envFrom` (chapter 4), a ClusterIP Service and an
Ingress routing to it (chapter 5). What's new is that the Deployment's
`image:` field now points at something *this repo* built and pushed,
rather than an upstream tag like `nginx:1.27`, and it uses the
`imagePullPolicy` lesson from above deliberately: `IfNotPresent`, which
is the right choice for a locally-built image that changes tag on every
real build (the "same-tag rebuild" trap above is specifically about
*not* bumping the tag - `IfNotPresent` is fine once tags are actually
unique per build, which the rolling-update section below does properly).

**Example**: `tutorial/examples/app-deployment/configmap.yaml`,
`deployment.yaml`, `service.yaml`, and `ingress.yaml`:

```yaml
# configmap.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-deployment-demo-config
data:
  GREETING: "hello"
```

```yaml
# deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: app-deployment-demo
  labels:
    app: app-deployment-demo
spec:
  replicas: 2
  selector:
    matchLabels:
      app: app-deployment-demo
  template:
    metadata:
      labels:
        app: app-deployment-demo
    spec:
      containers:
      - name: app
        image: localhost:5001/app-deployment-demo:v1
        imagePullPolicy: IfNotPresent
        ports:
        - containerPort: 8080
        envFrom:
        - configMapRef:
            name: app-deployment-demo-config
```

`service.yaml` is a plain ClusterIP selecting `app: app-deployment-demo`
on port 80 -> 8080. `ingress.yaml` routes `/app-deployment-demo` to it
(a distinct path from chapter 5's own `/` demo Ingress, so both can exist
on the same cluster at once), using the same `rewrite-target` annotation
pattern needed whenever the Ingress path doesn't match what the backend
app itself expects to see:

```yaml
# ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: app-deployment-demo
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /$2
spec:
  ingressClassName: nginx
  rules:
  - http:
      paths:
      - path: /app-deployment-demo(/|$)(.*)
        pathType: ImplementationSpecific
        backend:
          service:
            name: app-deployment-demo
            port:
              number: 80
```

```
kubectl apply -f tutorial/examples/app-deployment/configmap.yaml
kubectl apply -f tutorial/examples/app-deployment/deployment.yaml
kubectl apply -f tutorial/examples/app-deployment/service.yaml
kubectl apply -f tutorial/examples/app-deployment/ingress.yaml
kubectl rollout status deployment/app-deployment-demo
kubectl get pods -l app=app-deployment-demo -o wide
curl -sS localhost/app-deployment-demo/
```

**Expected output**: both replicas pull cleanly (fresh nodes, so no
stale-cache surprise this time), land on different nodes, and the full
path - Ingress -> Service -> ConfigMap-fed env var - works end to end:

```
deployment "app-deployment-demo" successfully rolled out

NAME                                   READY   STATUS    RESTARTS   AGE   NODE
app-deployment-demo-79bb5b767b-ft8hq   1/1     Running   0          12s   k8s-lab-default-worker2
app-deployment-demo-79bb5b767b-r5qqm   1/1     Running   0          12s   k8s-lab-default-worker

hello from app-deployment-demo v1
```

The very first `curl` right after `rollout status` reported success
returned a `503` here, not the app's response - a real, reproducible
propagation gap between the Deployment being "rolled out" and
ingress-nginx's own endpoint list catching up, the same class of lag
chapter 5 touches on. A retry a few seconds later succeeded. Worth
expecting, not worth chasing as a bug.

Confirm the ConfigMap actually reached the container, rather than
assuming `envFrom` worked because nothing errored:

```
$ kubectl exec deploy/app-deployment-demo -- env | grep GREETING
GREETING=hello
```

### Rolling update: from a source change to a running rollout

**Why**: this is chapter 3's rolling-update mechanism, but started from
the actual place a rollout starts in practice - editing source, not
typing a new tag into a manifest. The Deployment's `image:` field
staying at `:v1` in the checked-in YAML above is deliberate, matching
this tutorial's existing convention (chapter 3's `deployment.yaml` never
gets edited either): the update happens via `kubectl set image` against
a newly-built, newly-tagged image, not by re-applying a hand-edited
manifest.

**Example**: a real code change - not just a version bump, an actual new
line of behavior (the response now includes the serving Pod's hostname):

```diff
--- app.py (v1)
+++ app.py (v2)
@@ -1,7 +1,8 @@
 import http.server
 import os
+import socket
 
-CODE_VERSION = "v1"
+CODE_VERSION = "v2"
 GREETING = os.environ.get("GREETING", "hello")
 
 
@@ -10,7 +11,7 @@
         self.send_response(200)
         self.send_header("Content-Type", "text/plain")
         self.end_headers()
-        body = f"{GREETING} from app-deployment-demo {CODE_VERSION}\n"
+        body = f"{GREETING} from app-deployment-demo {CODE_VERSION}, served by {socket.gethostname()}\n"
         self.wfile.write(body.encode())
```

Build, tag, and push under a genuinely new tag this time - the fix for
the same-tag trap two sections back - then trigger the rollout the same
way chapter 3 does, annotating the change-cause first:

```
docker build -t app-deployment-demo:v2 .
docker tag app-deployment-demo:v2 localhost:5001/app-deployment-demo:v2
docker push localhost:5001/app-deployment-demo:v2
kubectl annotate deployment app-deployment-demo kubernetes.io/change-cause="bump app image to v2 (adds pod hostname to response)" --overwrite
kubectl set image deployment/app-deployment-demo app=localhost:5001/app-deployment-demo:v2
kubectl rollout status deployment/app-deployment-demo
kubectl get rs -l app=app-deployment-demo
kubectl rollout history deployment/app-deployment-demo
```

**Expected output**: a real rolling update, one pod at a time, the old
ReplicaSet scaled to zero and kept around rather than deleted - all
identical in shape to chapter 3's nginx-version-bump example, just
triggered by an actual code change and a freshly-pushed image this time:

```
v2: digest: sha256:245ce0c5f4f59a9208f5851fbb406c6c849649d7dc8c078b63faf72b4db16cc7 size: 1366

deployment "app-deployment-demo" successfully rolled out

NAME                             DESIRED   CURRENT   READY   AGE
app-deployment-demo-6658747867   2         2         2       8s
app-deployment-demo-79bb5b767b   0         0         0       70s

REVISION  CHANGE-CAUSE
1         bump app image to v2 (adds pod hostname to response)
2         bump app image to v2 (adds pod hostname to response)
```

Same "both revisions show the same change-cause text" quirk chapter 3
already flagged (the annotation lands on whichever ReplicaSet is current
at the moment it runs, not tied to a specific future revision) - not a
new surprise, just the same one showing up again in a different example.

```
$ curl -sS localhost/app-deployment-demo/
hello from app-deployment-demo v2, served by app-deployment-demo-6658747867-7bcr7
$ curl -sS localhost/app-deployment-demo/
hello from app-deployment-demo v2, served by app-deployment-demo-6658747867-cmj6w
```

Both replicas answering, both on the new code, both identifiable by
hostname - a source change, through a real build and push, landing on a
running cluster by the same rollout mechanism chapter 3 introduced with
a plain `nginx` version bump. The registry now holds both tags:

```
$ curl -sS localhost:5001/v2/app-deployment-demo/tags/list
{"name":"app-deployment-demo","tags":["v1","v2"]}
```

### Teardown

**Why**: unlike most of this tutorial's examples, this chapter leaves
two different kinds of real state behind - Kubernetes objects on the
cluster, and a Docker container (`k8s-lab-registry`) running on the
host, independent of any cluster. The registry isn't optional lab
scaffolding the way `lab-helpers/nfs-server` is for chapter 4 - it's a
step in the actual deployment workflow this chapter walked through
(build -> push -> deploy), which is exactly why it needs its own
explicit teardown rather than disappearing along with a `kind delete
cluster`.

**Example**: delete the app's Kubernetes objects first, then stop the
registry container:

```
kubectl delete -f tutorial/examples/app-deployment/ingress.yaml
kubectl delete -f tutorial/examples/app-deployment/service.yaml
kubectl delete -f tutorial/examples/app-deployment/deployment.yaml
kubectl delete -f tutorial/examples/app-deployment/configmap.yaml
kubectl get deploy,svc,ingress,cm -l app=app-deployment-demo
make registry-down
docker ps -a --filter name=k8s-lab-registry
```

**Expected output**: every object this chapter created is gone from the
cluster, and the registry container is stopped and removed (its
`lab-helpers/registry/data/` bind mount is left in place, so `v1` and
`v2` are still there on the next `make registry-up`):

```
ingress.networking.k8s.io "app-deployment-demo" deleted from default namespace
service "app-deployment-demo" deleted from default namespace
deployment.apps "app-deployment-demo" deleted from default namespace
configmap "app-deployment-demo-config" deleted from default namespace

No resources found in default namespace.

k8s-lab-registry removed (lab-helpers/registry/data left in place)

CONTAINER ID   IMAGE     COMMAND   CREATED   STATUS    PORTS     NAMES
```

`make down PROFILE=default` (or whichever profile was used) still
removes the cluster itself as usual - that part isn't different from any
other chapter. What's different here is that stopping there would leave
`k8s-lab-registry` running on the host indefinitely, since it was never
tied to the cluster's own lifecycle in the first place.
