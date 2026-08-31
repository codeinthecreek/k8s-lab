# 4. Configuration and storage

None of this chapter means anything without chapter 3's Pods to attach
it to - a ConfigMap, Secret, or PersistentVolumeClaim is inert on its
own, the same way a CRD is inert without a controller (chapter 11).
This chapter covers the two ways a Pod pulls in something that isn't
baked into its container image: configuration data (ConfigMap, Secret)
and storage (Volumes, PersistentVolumes/Claims, StorageClass).

### ConfigMap: decoupling configuration from the image

**Why**: baking configuration into a container image means rebuilding
the image for every environment or config change. A ConfigMap holds
key-value data as its own API object, and a Pod pulls values from it at
start time - two ways: as environment variables (`envFrom`/`env`), or as
files in a mounted volume. These aren't equivalent for anything beyond a
single-line value: an env var is one string, full stop, while a mounted
ConfigMap volume gives you one file per key, updated atomically as a
whole (kubelet swaps a `..data` symlink rather than editing files in
place), which matters for any value that isn't guaranteed to be a single
line.

**Example**: `tutorial/examples/config-storage/configmap.yaml` defines
two keys - `greeting` (single line) and `motd` (deliberately
multi-line). `tutorial/examples/config-storage/configmap-pod.yaml`
consumes the same ConfigMap both ways at once, so the difference is
directly comparable:

```yaml
# configmap.yaml
data:
  greeting: "Hello from a ConfigMap"
  motd: |
    Line one of the message of the day.
    Line two of the message of the day.
```

```
kubectl apply -f tutorial/examples/config-storage/configmap.yaml
kubectl apply -f tutorial/examples/config-storage/configmap-pod.yaml
kubectl exec config-storage-demo-cm-pod -- env | grep -E '^(greeting|motd)='
kubectl exec config-storage-demo-cm-pod -- cat /etc/config/motd
kubectl exec config-storage-demo-cm-pod -- ls /etc/config
```

**Expected output**: the env var genuinely carries the multi-line value
- one variable, with a real embedded newline - which is legal but
actively misleading for line-based tooling. A naive `grep '^motd='`
only shows the first line, silently dropping the rest, because `grep`
matches per line and the continuation line doesn't start with `motd=`
at all:

```
greeting=Hello from a ConfigMap
motd=Line one of the message of the day.
```

The value is really both lines - confirmed with `grep -A1`:

```
motd=Line one of the message of the day.
Line two of the message of the day.
```

The mounted volume has no such ambiguity - one file per key, each with
clean, real newlines:

```
$ kubectl exec config-storage-demo-cm-pod -- cat /etc/config/motd
Line one of the message of the day.
Line two of the message of the day.

$ kubectl exec config-storage-demo-cm-pod -- ls /etc/config
greeting
motd
```

If something downstream parses `motd` from the environment expecting
one line - a log line, a shell variable it then reads on to something
else - the second line silently vanishes from its view. That's the
concrete cost of choosing env vars for anything that isn't guaranteed
single-line.

### Secret: the same mechanism, for values that shouldn't sit in plain files

**Why**: a Secret has the exact same shape and consumption model as a
ConfigMap (env or mounted volume) - the differences are about handling,
not structure. Kubernetes stores Secret values base64-encoded, which is
an encoding, not encryption - anyone who can `kubectl get secret -o
yaml` can trivially decode it, so a Secret's actual security value comes
from RBAC scoping who can read the object at all (chapter 9), not from
the encoding itself. `stringData` is a write-only convenience field for
authoring - you write plaintext, the apiserver base64-encodes it into
`.data` on write, and reading the object back always shows `.data`, never
`stringData`. Preferring a mounted volume over an env var matters more
here than for a ConfigMap: an env var is trivially readable via
`kubectl exec ... env`, process listings, and can end up in crash dumps
or child-process environments more easily than a file that requires an
explicit read.

**Example**: `tutorial/examples/config-storage/secret.yaml` and
`tutorial/examples/config-storage/secret-pod.yaml` mount a password as a
file rather than an env var:

```
kubectl apply -f tutorial/examples/config-storage/secret.yaml
kubectl get secret config-storage-demo-secret -o yaml
kubectl apply -f tutorial/examples/config-storage/secret-pod.yaml
kubectl exec config-storage-demo-secret-pod -- cat /etc/secret/password
```

**Expected output**: the object's real storage (`.data`) is base64, and
`stringData` genuinely isn't stored anywhere as its own field - it only
shows up, still in plaintext, inside kubectl's own bookkeeping
annotation:

```yaml
apiVersion: v1
data:
  password: czNjcjN0LWRlbW8tdmFsdWU=
kind: Secret
metadata:
  annotations:
    kubectl.kubernetes.io/last-applied-configuration: |
      {"apiVersion":"v1","kind":"Secret","metadata":{...},"stringData":{"password":"s3cr3t-demo-value"},"type":"Opaque"}
  ...
type: Opaque
```

`czNjcjN0LWRlbW8tdmFsdWU=` is exactly `s3cr3t-demo-value` base64-decoded
- trivial to reverse, which is the whole point of "encoding, not
encryption." The mounted file gives the plaintext back directly, decoded
by kubelet at mount time, no manual decoding needed by whatever's
reading it:

```
$ kubectl exec config-storage-demo-secret-pod -- cat /etc/secret/password
s3cr3t-demo-value
```

### Volumes: Pod-scoped, ephemeral storage

**Why**: a `Volume` in the Pod spec (as opposed to a PersistentVolume,
next section) is scoped to the Pod's own lifetime, not any individual
container's - it starts empty when the Pod is scheduled and is deleted
for good only when the Pod object itself is. This is the mechanism
ConfigMap and Secret volume mounts (above) are actually built on, and
it's also how containers within the same Pod share files with each
other. The simplest kind, `emptyDir`, is just scratch space with nothing
backing it beyond the Pod's own lifetime.

**Example**: `tutorial/examples/config-storage/emptydir-pod.yaml` mounts
an `emptyDir` and just sleeps - nothing is written on start, so writing
happens via `kubectl exec` instead. That way a fresh Pod's volume being
genuinely empty is directly observable, rather than immediately
overwritten by a start command that would run again on every new Pod
regardless of whether the volume was actually fresh:

```
kubectl apply -f tutorial/examples/config-storage/emptydir-pod.yaml
kubectl exec config-storage-demo-emptydir-pod -- sh -c "echo scratch data > /scratch/note.txt"
kubectl exec config-storage-demo-emptydir-pod -- cat /scratch/note.txt
kubectl delete pod config-storage-demo-emptydir-pod
kubectl apply -f tutorial/examples/config-storage/emptydir-pod.yaml
kubectl exec config-storage-demo-emptydir-pod -- cat /scratch/note.txt
```

**Expected output**: the write succeeds and reads back fine - right up
until the Pod object is deleted and recreated, at which point the new
Pod's volume is a genuinely different, empty one:

```
$ kubectl exec config-storage-demo-emptydir-pod -- cat /scratch/note.txt
scratch data

$ kubectl delete pod config-storage-demo-emptydir-pod
pod "config-storage-demo-emptydir-pod" deleted from default namespace

$ kubectl apply -f tutorial/examples/config-storage/emptydir-pod.yaml
pod/config-storage-demo-emptydir-pod created

$ kubectl exec config-storage-demo-emptydir-pod -- cat /scratch/note.txt
cat: can't open '/scratch/note.txt': No such file or directory
command terminated with exit code 1
```

One real aside worth knowing, hit while verifying this: `kubectl delete
pod` on this example took the full default 30s termination grace period
to actually complete, rather than returning quickly. That's because this
container's process (a plain `sh -c "sleep 3600"`) never registers a
`SIGTERM` handler, and an unhandled `SIGTERM` sent to the process acting
as PID 1 of a container's PID namespace is ignored by the kernel rather
than taking its normal "terminate" default - kubelet has to wait out the
full grace period and send `SIGKILL` before the container actually
stops. A real application image that does its own signal handling
(nginx, for instance - chapter 3's crash demo used it precisely because
it *does* shut down cleanly on `SIGTERM`) doesn't hit this; a bare
shell script wrapped in `sh -c` is a common way to accidentally hit it.

### PersistentVolume and PersistentVolumeClaim: static binding

**Why**: a `Volume` disappears with its Pod - real persistent storage
needs to outlive any one Pod, and potentially be shared across nodes,
which is what PersistentVolume (PV) and PersistentVolumeClaim (PVC)
exist for. A PV represents an actual piece of storage, whatever's
actually backing it (a directory on a node's disk, a real NFS export,
a cloud disk); a PVC is a Pod-facing *request* for storage matching some
criteria, which the control plane binds to a matching PV. **Static
binding** means a human created the PV by hand
ahead of time, as opposed to a StorageClass provisioning one on demand
(next section). The detail that actually controls which path you get:
`storageClassName` on the PVC. Merely *omitting* the field is not the
same as setting it to an explicit empty string - the `DefaultStorageClass`
admission controller (apiserver logic that intercepts a request after
auth and before it's persisted, and can mutate or reject it; chapter 9
covers this stage properly) injects the cluster's default-annotated
StorageClass onto any PVC where the field is simply absent, silently
routing you into dynamic provisioning even when a static PV already
exists for you to bind to instead.

**Example**: the binding mechanics are the same regardless of what's
actually backing the storage, so start with the simplest possible
backend - a directory on a node's own filesystem - before bringing in a
real network filesystem. `tutorial/examples/config-storage/hostpath-pv.yaml`
uses a `hostPath` volume, pinned via `nodeAffinity` to one specific node
(a `hostPath` directory only exists on the one node it names, unlike NFS
below), and `tutorial/examples/config-storage/hostpath-pvc.yaml` again
sets `storageClassName: ""` explicitly:

```
kubectl apply -f tutorial/examples/config-storage/hostpath-pv.yaml
kubectl apply -f tutorial/examples/config-storage/hostpath-pvc.yaml
kubectl get pv config-storage-demo-hostpath-pv
kubectl get pvc config-storage-demo-hostpath-pvc
kubectl apply -f tutorial/examples/config-storage/hostpath-pod.yaml
kubectl exec config-storage-demo-hostpath-pod -- sh -c "echo written-by-pod > /mnt/hostpath/from-pod.txt; cat /mnt/hostpath/from-pod.txt"
```

**Expected output**: the PVC binds directly to the named PV, no
provisioner involved:

```
persistentvolume/config-storage-demo-hostpath-pv created
persistentvolumeclaim/config-storage-demo-hostpath-pvc created

NAME                               STATUS   VOLUME                            CAPACITY   ACCESS MODES   STORAGECLASS   AGE
config-storage-demo-hostpath-pvc   Bound    config-storage-demo-hostpath-pv   1Gi        RWO                           1s
```

And the write actually lands on the node's real filesystem, not just
inside the container - confirmed by reading the same path back on the
node itself (`docker exec k8s-lab-default-worker cat
/tmp/config-storage-demo-hostpath/from-pod.txt`) and finding the exact
file the Pod wrote:

```
$ kubectl exec config-storage-demo-hostpath-pod -- sh -c "echo written-by-pod > /mnt/hostpath/from-pod.txt; cat /mnt/hostpath/from-pod.txt"
written-by-pod
```

Same binding mechanics, no server to stand up - the only difference from
what follows is where the bytes actually live: one node's local disk
instead of a real shared export, which is also why the PV needed
`nodeAffinity` here and doesn't for NFS below.

Now the same PV/PVC binding against real shared storage: this repo's
`lab-helpers/nfs-server/` runs a real NFS server on the `kind` Docker
network specifically for this (`make nfs-up`, `make nfs-client-install
PROFILE=default` first - see
[lab-helpers/nfs-server/README.md](../../lab-helpers/nfs-server/README.md)
for the `fsid=0` mount-path gotcha this PV's `nfs.path: /` already
accounts for).
`tutorial/examples/config-storage/nfs-pv.yaml` and
`tutorial/examples/config-storage/nfs-pvc.yaml` both set
`storageClassName: ""` explicitly:

```
kubectl apply -f tutorial/examples/config-storage/nfs-pv.yaml
kubectl apply -f tutorial/examples/config-storage/nfs-pvc.yaml
kubectl get pv config-storage-demo-nfs-pv
kubectl get pvc config-storage-demo-nfs-pvc
kubectl apply -f tutorial/examples/config-storage/nfs-pod.yaml
kubectl exec config-storage-demo-nfs-pod -- sh -c "echo written-by-pod > /mnt/nfs/from-pod.txt; ls -la /mnt/nfs"
```

**Expected output**: the PVC binds directly to the named PV - no
dynamic provisioning involved, `VOLUME` names it explicitly:

```
persistentvolume/config-storage-demo-nfs-pv created
persistentvolumeclaim/config-storage-demo-nfs-pvc created

NAME                         CAPACITY   ACCESS MODES   RECLAIM POLICY   STATUS   CLAIM                                   STORAGECLASS   AGE
config-storage-demo-nfs-pv   1Gi        RWX            Retain           Bound    default/config-storage-demo-nfs-pvc                    4s

NAME                          STATUS   VOLUME                       CAPACITY   ACCESS MODES   STORAGECLASS   AGE
config-storage-demo-nfs-pvc   Bound    config-storage-demo-nfs-pv   1Gi        RWX                           4s
```

The Pod mounts it and writes to the real share immediately - no
`ContainerCreating` stall, and the pre-existing `hello.txt` from
`lab-helpers/nfs-server/`'s seeded `data/` directory is right there
alongside the new file, proof this is genuinely the same NFS export the
lab helper documents, not a lookalike:

```
pod/config-storage-demo-nfs-pod created

total 16
drwxr-xr-x    2 1000     985           4096 Aug 28 04:31 .
drwxr-xr-x    3 root     root          4096 Aug 28 04:31 ..
-rw-r--r--    1 root     root            15 Aug 28 04:31 from-pod.txt
-rw-r--r--    1 1000     985              9 Aug 21 02:08 hello.txt
```

Now the failure mode the "Why" above described - apply
`tutorial/examples/config-storage/pvc-omitted-storageclassname.yaml`,
which requests `ReadWriteOnce` storage but never sets
`storageClassName` at all. A Pod referencing it
(`pvc-omitted-storageclassname-pod.yaml`) has to be applied too, not
just the PVC on its own - kind's default StorageClass uses
`volumeBindingMode: WaitForFirstConsumer`, meaning nothing gets
provisioned until something actually tries to consume the claim:

```
kubectl apply -f tutorial/examples/config-storage/pvc-omitted-storageclassname.yaml
kubectl apply -f tutorial/examples/config-storage/pvc-omitted-storageclassname-pod.yaml
kubectl get pvc config-storage-demo-omitted-scn-pvc
```

**Expected output**: bound, with a real dynamically-provisioned PV
(`pvc-<uid>`) and `STORAGECLASS: standard` - despite the source file
never mentioning a StorageClass at all:

```
persistentvolumeclaim/config-storage-demo-omitted-scn-pvc created
pod/config-storage-demo-omitted-scn-pod created

NAME                                   STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS   AGE
config-storage-demo-omitted-scn-pvc   Bound    pvc-a7c865a6-418c-424d-8c64-7f02069faecb   1Gi        RWO            standard       7s
```

Compare that `STORAGECLASS` column against the NFS example above, which
showed a blank `STORAGECLASS` column and a `VOLUME` naming the exact PV
by name - that blank/named-PV vs. `standard`/generated-PV-name contrast
*is* the observable difference between an explicit empty string and an
omitted field, not something you have to take on faith.

### StorageClass and dynamic provisioning

**Why**: hand-writing a PV for every PVC doesn't scale - a StorageClass
lets a PVC request storage from a *provisioner* instead, which creates a
matching PV on demand. kind ships a default StorageClass, `standard`,
backed by `rancher.io/local-path` (see this repo's
[DESIGN.md](../../DESIGN.md), "Storage" section) - a real dynamic
provisioner, but a deliberately minimal one: each volume is a directory
on whichever single node's filesystem the consuming Pod happens to land
on, with no replication. That constraint isn't just a performance
tradeoff - `local-path-provisioner` hard-rejects any access mode other
than `ReadWriteOnce` at the API level.

**Example**: request `ReadWriteMany` from the default StorageClass via
`tutorial/examples/config-storage/pvc-rwx-standard.yaml` (no
`storageClassName` override - it uses the default), with a consuming Pod
again required to trigger anything at all under
`WaitForFirstConsumer`:

```
kubectl apply -f tutorial/examples/config-storage/pvc-rwx-standard.yaml
kubectl apply -f tutorial/examples/config-storage/pvc-rwx-standard-pod.yaml
kubectl get pvc config-storage-demo-rwx-pvc
kubectl describe pvc config-storage-demo-rwx-pvc
```

**Expected output**: the PVC sits `Pending` - but *why* it's Pending
depends entirely on whether a Pod ever consumed it, which is worth
seeing both ways rather than assuming. Applying the PVC **alone**
produces no useful signal at all - just the generic
`WaitForFirstConsumer` message, forever, since nothing has triggered
provisioning yet:

```
NAME                          STATUS    STORAGECLASS   AGE
config-storage-demo-rwx-pvc   Pending   standard       20s

Events:
  Type    Reason                Age  From                          Message
  ----    ------                ---  ----                          -------
  Normal  WaitForFirstConsumer  20s  persistentvolume-controller   waiting for first consumer to be created before binding
```

Once the consuming Pod is applied too, the provisioner actually attempts
the volume and a real, genuinely informative error appears:

```
Events:
  Type     Reason                Age  From                                                                  Message
  ----     ------                ---  ----                                                                  -------
  Normal   WaitForFirstConsumer  20s  persistentvolume-controller                                           waiting for first consumer to be created before binding
  Normal   ExternalProvisioning  14s  persistentvolume-controller                                           Waiting for a volume to be created either by the external provisioner 'rancher.io/local-path' or manually by the system administrator...
  Normal   Provisioning          5s   rancher.io/local-path_local-path-provisioner-855c7b7774-pkjfx_...      External provisioner is provisioning volume for claim "default/config-storage-demo-rwx-pvc"
  Warning  ProvisioningFailed    5s   rancher.io/local-path_local-path-provisioner-855c7b7774-pkjfx_...      failed to provision volume with StorageClass "standard": NodePath only supports ReadWriteOnce and ReadWriteOncePod (1.22+) access modes
```

The Pod itself stays `Pending` too, with no events of its own - all the
useful information is on the PVC, not the Pod trying to use it. The
practical lesson: an unconsumed `WaitForFirstConsumer` PVC and a
genuinely rejected one look identical (`Pending`, generic message) until
something actually tries to schedule against them - if a PVC seems
stuck for no reason, checking whether anything currently references it
is as important as checking the PVC's own events.
