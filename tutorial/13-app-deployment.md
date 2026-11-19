# 13. From source code to a running workload

Chapters 1-12 all started with an image that already existed, such as
`nginx:1.27`, and looked at how the cluster runs it. This chapter covers
the step before that: taking your own source code and turning it into
something a Deployment can run. It gets its own chapter because it's a
different kind of task, although by the end it uses Deployments
(chapter 3), ConfigMaps (chapter 4) and Services and Ingress (chapter 5)
together.

The example is a small Python web service
(`tutorial/examples/app-deployment/app/`). We build it into a container
image, push the image to a registry the cluster can reach, deploy it,
and then change the source code and roll out the new version. This is
not a guide to building good container images (multi-stage builds,
minimal base images, layer caching); that's a separate skill.

### The app and its Dockerfile

**Why**: the app should be small enough that the build and deploy
steps stay the focus. It's a single Python file that uses only the
standard library (`http.server`), so there are no dependencies to
install.

**Example**: the first version of `app.py`. (The
[file in the repo](examples/app-deployment/app/app.py) is the later v2,
from the rolling-update section at the end of this chapter.)

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

`GREETING` comes from an environment variable, which a ConfigMap will
set later in this chapter. `CODE_VERSION` is written into the source on
purpose, so that changing it later means a real code change and a new
image, not just a different setting. The
[`Dockerfile`](examples/app-deployment/app/Dockerfile):

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

**Expected output**: the response includes the `GREETING` value passed
with `-e`. The image works before Kubernetes is involved:

```
Successfully tagged app-deployment-demo:v1

hi from app-deployment-demo v1
```

### Getting a locally-built image into kind: a real registry, not `kind load docker-image`

**Why**: an image you build with `docker build` lives in your host's
Docker image store. A kind node is a Docker container with its own
containerd and its own image store, so it can't see that image. Nor can
it reach a registry at `localhost:<port>` on your host: inside a node
container, `localhost` means the container itself, not the host (the
same distinction chapter 5 makes for NodePort).

kind has a shortcut, `kind load docker-image`, which copies an image
straight into every node's containerd, with no registry involved. It's
handy for quick experiments, but the image then has no registry behind
it, so the node can never re-check or re-pull it. That breaks
`imagePullPolicy: Always`, as the next section shows, and it isn't how
any real cluster gets images.

The better approach, and the one kind's documentation recommends, is a
local registry. `lab-helpers/registry` runs a `registry:3` container on
the `kind` Docker network, and each profile's `cluster.yaml` configures
containerd on every node to send pulls for `localhost:5001/<image>` to
that container. `lab-helpers/registry/README.md` and DESIGN.md's "Local
registry: containerd config_path patch" explain the details. One of
them surprised us: kind's example script says its containerd config
patch isn't needed on node images from kind v0.27.0 onwards, but it was
needed on this repo's `kindest/node:v1.36.1`, as `docker exec <node> cat
/etc/containerd/config.toml` showed.

**Example**: start the registry (once; it doesn't belong to any
profile, like `lab-helpers/nfs-server`), configure the profile you're
using, then tag and push the image as you would to any registry:

```
make registry-up
make registry-client-install PROFILE=default
docker tag app-deployment-demo:v1 localhost:5001/app-deployment-demo:v1
docker push localhost:5001/app-deployment-demo:v1
```

**Expected output**: an ordinary registry push, with nothing
kind-specific about it:

```
k8s-lab-registry started - run 'make registry-client-install PROFILE=x' before pulling from it on that profile
--- k8s-lab-default-worker ---
--- k8s-lab-default-control-plane ---
--- k8s-lab-default-worker2 ---
configmap/local-registry-hosting created

The push refers to repository [localhost:5001/app-deployment-demo]
v1: digest: sha256:e6d5b562d2fa242d98e1fff13d484fbc3d19aa9831389f5bc8ab6fa14e96db93 size: 1366
```

Check that a Pod can pull it, not just that the push worked:

```
kubectl run registry-smoketest --image=localhost:5001/app-deployment-demo:v1 --restart=Never --port=8080 -- python3 /app.py
kubectl get pod registry-smoketest -o wide
```

```
NAME                 READY   STATUS    RESTARTS   AGE   IP           NODE
registry-smoketest   1/1     Running   0          8s    10.244.2.4   k8s-lab-default-worker2
```

The node pulled the image from the registry container over the `kind`
Docker network, just as a real cluster pulls from a real registry.

### imagePullPolicy: two ways it silently breaks

**Why**: `imagePullPolicy` decides whether the kubelet uses an image
that's already on the node or checks the registry first. Getting it
wrong fails in one of two opposite ways, and neither is obvious until
you look closely.

This matters more for images you build yourself than for public ones.
Nobody pushes different content under an existing public tag such as
`nginx:1.27`, but while you're developing, you may rebuild your own
image under the same tag many times.

**Example 1: `Always` with an image that was never pushed anywhere.**
`kind load docker-image` (the shortcut from the previous section) puts
the image on the node, with no registry behind it:

```
kind load docker-image app-deployment-demo:v1 --name k8s-lab-default
kubectl run pullpolicy-always-demo --image=app-deployment-demo:v1 --image-pull-policy=Always --restart=Never -- python3 /app.py
kubectl describe pod pullpolicy-always-demo
```

**Expected output**: the pull fails. An image name without a registry
defaults to `docker.io/library/<name>`, and Docker Hub has never heard
of this image. `Always` doesn't fall back to the copy on the node when
the registry check fails:

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

The image is on the node, because `kind load` put it there seconds
earlier, and the Pod fails anyway: with `Always`, the kubelet must reach
the registry first. That's the case for the local registry: a name like
`localhost:5001/...` has a registry that can answer.

**Example 2: `IfNotPresent` serving old code after a rebuild under the
same tag.** Pin a Pod to one node and let it pull the image from the
registry. Then rebuild the image with different content and push it
under the *same* tag. Forgetting to change the tag is a common mistake
during development:

```
kubectl run pullpolicy-ifnotpresent-demo --image=localhost:5001/app-deployment-demo:v1 --image-pull-policy=IfNotPresent --restart=Never --overrides='{"spec":{"nodeName":"k8s-lab-default-worker"}}' -- python3 /app.py
```

```
Normal  Pulling  5s  kubelet  Pulling image "localhost:5001/app-deployment-demo:v1"
Normal  Pulled   3s  kubelet  Successfully pulled image "localhost:5001/app-deployment-demo:v1" in 2.225s
```

Now edit `app.py` to add `(updated!)` to the response, rebuild, tag it
`v1` again and push. The registry now has a different image (a new
digest) under the same tag:

```
docker build -t app-deployment-demo:v1 .
docker tag app-deployment-demo:v1 localhost:5001/app-deployment-demo:v1
docker push localhost:5001/app-deployment-demo:v1
```

```
v1: digest: sha256:1870d79c0ba5e9f3e8e14eda98fde847ec641358bed3a7767f17e1c13453881e size: 1366
```

Delete the Pod and create it again, on the same node, still with
`IfNotPresent`:

```
kubectl delete pod pullpolicy-ifnotpresent-demo
kubectl run pullpolicy-ifnotpresent-demo --image=localhost:5001/app-deployment-demo:v1 --image-pull-policy=IfNotPresent --restart=Never --overrides='{"spec":{"nodeName":"k8s-lab-default-worker"}}' -- python3 /app.py
kubectl describe pod pullpolicy-ifnotpresent-demo
```

**Expected output**: the kubelet doesn't pull anything, and the Pod
serves the **old** code. The registry has new content under `v1`, but
this node never checks:

```
Normal  Pulled   4s  kubelet  Container image "localhost:5001/app-deployment-demo:v1" already present on machine and can be accessed by the pod
```

```
$ curl -sS <pod-ip>:8080
hello from app-deployment-demo v1
```

No `(updated!)`. `IfNotPresent` only checks whether the node has *an*
image with that name and tag, not whether it matches what the registry
has now. Once a node has pulled a tag, it won't pull it again until the
image is removed from the node some other way. Switching to `Always`
fixes this (checked separately, on the same cluster): both nodes picked
up the new digest. But `Always` needs a reachable registry, as Example 1
showed. Neither policy is safer in general; they fail in opposite
situations.

The real fix is to give every build a new tag, which is what the
rolling-update section below does.

### Deployment, Service, Ingress, ConfigMap: tying it together

**Why**: these are objects from earlier chapters: a Deployment
(chapter 3), a ConfigMap passed to the container with `envFrom`
(chapter 4), and a ClusterIP Service with an Ingress in front of it
(chapter 5). What's new is that the Deployment's `image:` is one we
built and pushed ourselves. It uses `IfNotPresent`, which is the right
choice once every build gets its own tag.

**Example**: the four manifests in `tutorial/examples/app-deployment/`.
The ConfigMap and the Deployment:

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

`service.yaml` is a plain ClusterIP Service that selects
`app: app-deployment-demo` and maps port 80 to 8080.

`ingress.yaml` routes `/app-deployment-demo` to it. That's a different
path from chapter 5's Ingress on `/`, so both can exist on the same
cluster. Because the app is served under a path prefix, the prefix has
to be removed before a request reaches it. ingress-nginx does that with
a regex `path` and its `rewrite-target` annotation (both specific to
ingress-nginx, not part of the core Ingress API): `(/|$)(.*)` captures
whatever follows `/app-deployment-demo` as `$2`, and
`rewrite-target: /$2` sends just that to the app. A request for
`/app-deployment-demo/foo` reaches the app as `/foo`:

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

**Expected output**: both replicas pull the image and run, on different
nodes, and a request through the Ingress and the Service gets the
greeting from the ConfigMap:

```
deployment "app-deployment-demo" successfully rolled out

NAME                                   READY   STATUS    RESTARTS   AGE   NODE
app-deployment-demo-79bb5b767b-ft8hq   1/1     Running   0          12s   k8s-lab-default-worker2
app-deployment-demo-79bb5b767b-r5qqm   1/1     Running   0          12s   k8s-lab-default-worker

hello from app-deployment-demo v1
```

If the first `curl` returns `503`, wait a few seconds and try again.
That happened here: `rollout status` had reported success, but
ingress-nginx hadn't yet picked up the new Pods. The delay is normal
(chapter 5 mentions the same kind of lag), not a bug.

Check that the ConfigMap's value reached the container; `envFrom`
doesn't report an error if it doesn't:

```
$ kubectl exec deploy/app-deployment-demo -- env | grep GREETING
GREETING=hello
```

### Rolling update: from a source change to a running rollout

**Why**: this is chapter 3's rolling update, started the way it starts
in practice: by changing source code. As in chapter 3, the checked-in
`deployment.yaml` stays at `:v1`. The update is made with `kubectl set
image`, pointing the Deployment at a newly built image with a new
tag.

**Example**: change the code, not just the version string. The response
now also includes the hostname of the Pod that served it:

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

Build, tag and push under a new tag, `v2`, which avoids the same-tag
problem from earlier. Then record a change cause and start the rollout,
as in chapter 3:

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

**Expected output**: the same rolling update as chapter 3's nginx
example. Pods are replaced one at a time, and the old ReplicaSet is
scaled to zero and kept:

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

Both revisions show the same change cause. Chapter 3 explains why: the
annotation is copied to whichever ReplicaSet is current when you set
it.

```
$ curl -sS localhost/app-deployment-demo/
hello from app-deployment-demo v2, served by app-deployment-demo-6658747867-7bcr7
$ curl -sS localhost/app-deployment-demo/
hello from app-deployment-demo v2, served by app-deployment-demo-6658747867-cmj6w
```

Both replicas answer, both run the new code, and each reports its own
hostname. The registry now has both tags:

```
$ curl -sS localhost:5001/v2/app-deployment-demo/tags/list
{"name":"app-deployment-demo","tags":["v1","v2"]}
```

### Teardown

**Why**: this chapter leaves two kinds of state behind: Kubernetes
objects in the cluster, and the `k8s-lab-registry` container on your
host, which doesn't belong to any cluster. Deleting the cluster doesn't
remove the registry, so it needs its own step.

**Example**: delete the app's objects, then stop the registry:

```
kubectl delete -f tutorial/examples/app-deployment/ingress.yaml
kubectl delete -f tutorial/examples/app-deployment/service.yaml
kubectl delete -f tutorial/examples/app-deployment/deployment.yaml
kubectl delete -f tutorial/examples/app-deployment/configmap.yaml
kubectl get deploy,svc,ingress,cm -l app=app-deployment-demo
make registry-down
docker ps -a --filter name=k8s-lab-registry
```

**Expected output**: the objects are gone, and the registry container
is stopped and removed. Its data directory, `lab-helpers/registry/data/`,
is kept, so `v1` and `v2` are still there after the next
`make registry-up`:

```
ingress.networking.k8s.io "app-deployment-demo" deleted from default namespace
service "app-deployment-demo" deleted from default namespace
deployment.apps "app-deployment-demo" deleted from default namespace
configmap "app-deployment-demo-config" deleted from default namespace

No resources found in default namespace.

k8s-lab-registry removed (lab-helpers/registry/data left in place)

CONTAINER ID   IMAGE     COMMAND   CREATED   STATUS    PORTS     NAMES
```

`make down PROFILE=default` (or your profile) deletes the cluster as
usual. Without `make registry-down`, the registry would keep running on
your host.
