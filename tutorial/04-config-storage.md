# 4. Configuration and storage

A container image holds a program, but usually not its configuration
or its data. This chapter covers the two ways a Pod gets what isn't in
its image:

- **Configuration**: ConfigMaps and Secrets.
- **Storage**: volumes, PersistentVolumes and PersistentVolumeClaims,
  and StorageClasses.

None of these objects does anything until a Pod (chapter 3) uses
it.

### ConfigMap: configuration outside the image

**Why**: if configuration is built into the image, every change, and
every environment, needs a new image. A **ConfigMap** holds
configuration as key-value pairs in an API object of its own. A Pod can
use it in two ways:

- as **environment variables** (`envFrom` or `env`), or
- as **files**, by mounting the ConfigMap as a volume: one file per
  key.

For a value longer than one line, the two aren't equivalent. An
environment variable is a single string, and tools that read the
environment line by line handle it badly. A mounted file keeps the
value exactly as it is. When the ConfigMap changes, the kubelet updates
the mounted files all at once, by switching a `..data` symlink to a new
directory.

**Example**: [`configmap.yaml`](examples/config-storage/configmap.yaml)
has two keys: `greeting`, one line, and `motd`, two lines.
[`configmap-pod.yaml`](examples/config-storage/configmap-pod.yaml) uses
the ConfigMap both ways at once, so you can compare them:

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
```

When the Pod is running, look at its environment:

```
kubectl exec config-storage-demo-cm-pod -- env | grep -E '^(greeting|motd)='
```

**Expected output**: the `motd` environment variable does contain both
lines, with a newline in between. But `grep '^motd='` shows only the
first: `grep` works line by line, and the second line doesn't start
with `motd=`:

```
greeting=Hello from a ConfigMap
motd=Line one of the message of the day.
```

With `grep -A1`, which also prints the line after each match, you see
the second line too:

```
kubectl exec config-storage-demo-cm-pod -- env | grep -A1 '^motd='
```

```
motd=Line one of the message of the day.
Line two of the message of the day.
```

The mounted volume has one file per key, and the file has both
lines:

```
kubectl exec config-storage-demo-cm-pod -- cat /etc/config/motd
kubectl exec config-storage-demo-cm-pod -- ls /etc/config
```

```
Line one of the message of the day.
Line two of the message of the day.
greeting
motd
```

A program that reads `motd` from the environment and expects one line,
a log line or a shell script for example, never sees the second line.
For any value that might have more than one line, use a mounted
file.

### Secret: the same mechanism, for sensitive values

**Why**: a **Secret** works like a ConfigMap (environment variables or
mounted files), but is meant for passwords, keys and tokens. The
difference is in how it's handled, not how it's built:

- Secret values are stored **base64-encoded**. That's an encoding, not
  encryption: anyone who can read the Secret can decode it. What
  protects a Secret is RBAC, which controls who can read it (chapter 9).
- You can write values in plain text under `stringData`. The API server
  encodes them into `data`, and that's what you see when you read the
  Secret back.
- Prefer mounted files to environment variables even more than for a
  ConfigMap. Environment variables show up in `kubectl exec ... env`
  and process listings, are passed on to child processes and can end up
  in crash dumps. A file has to be read on purpose.

**Example**: [`secret.yaml`](examples/config-storage/secret.yaml) holds a
password, and [`secret-pod.yaml`](examples/config-storage/secret-pod.yaml)
mounts it as a file:

```
kubectl apply -f tutorial/examples/config-storage/secret.yaml
kubectl get secret config-storage-demo-secret -o yaml
```

**Expected output**: the stored value under `data` is base64. There's no
`stringData` field; the plain-text value only appears inside the
`last-applied-configuration` annotation that `kubectl apply` adds (see
chapter 2):

```yaml
secret/config-storage-demo-secret created
apiVersion: v1
data:
  password: czNjcjN0LWRlbW8tdmFsdWU=
kind: Secret
metadata:
  annotations:
    kubectl.kubernetes.io/last-applied-configuration: |
      {"apiVersion":"v1","kind":"Secret","metadata":{"annotations":{},"name":"config-storage-demo-secret","namespace":"default"},"stringData":{"password":"s3cr3t-demo-value"},"type":"Opaque"}
  creationTimestamp: "2026-11-19T11:51:51Z"
  name: config-storage-demo-secret
  namespace: default
  resourceVersion: "5508"
  uid: a6de3be2-dccb-4ef5-a0c7-364a2329e742
type: Opaque
```

So anyone who can run `kubectl apply` on a Secret's manifest leaves the
plain text in this annotation too, another reason to control who can
read Secrets. Decoding the stored value takes one command:

```
echo czNjcjN0LWRlbW8tdmFsdWU= | base64 -d
```

```
s3cr3t-demo-value
```

Now mount the Secret in a Pod. The kubelet decodes the value when it
mounts it, so the file in the Pod holds the plain text:

```
kubectl apply -f tutorial/examples/config-storage/secret-pod.yaml
```

When the Pod is running:

```
kubectl exec config-storage-demo-secret-pod -- cat /etc/secret/password
```

```
s3cr3t-demo-value
```

### Volumes: storage that lives with the Pod

**Why**: a **volume** in a Pod's spec (not to be confused with a
PersistentVolume, in the next section) belongs to the Pod. It's
created when the Pod starts, survives container restarts, and is
deleted with the Pod. Containers in the same Pod can share files
through one. ConfigMap and Secret mounts are volumes too. The simplest
kind is `emptyDir`: an empty directory, for scratch space.

**Example**: [`emptydir-pod.yaml`](examples/config-storage/emptydir-pod.yaml)
mounts an `emptyDir` at `/scratch` and does nothing else. Write a file
into it, delete the Pod, create it again, and look for the file:

```
kubectl apply -f tutorial/examples/config-storage/emptydir-pod.yaml
```

When the Pod is running, write a file and read it back:

```
kubectl exec config-storage-demo-emptydir-pod -- sh -c "echo scratch data > /scratch/note.txt"
kubectl exec config-storage-demo-emptydir-pod -- cat /scratch/note.txt
```

```
scratch data
```

Delete the Pod and create it again:

```
kubectl delete pod config-storage-demo-emptydir-pod
kubectl apply -f tutorial/examples/config-storage/emptydir-pod.yaml
```

```
pod "config-storage-demo-emptydir-pod" deleted from default namespace
pod/config-storage-demo-emptydir-pod created
```

The `delete` takes about 30 seconds. The container's only process,
`sleep`, started by `sh -c`, runs as PID 1 and doesn't handle
`SIGTERM`, the signal asking it to stop. The kernel ignores unhandled
signals for PID 1, so the kubelet waits out the 30-second grace period
and then sends `SIGKILL`. Programs that handle `SIGTERM`, such as
nginx, stop straight away.

When the new Pod is running, look for the file:

```
kubectl exec config-storage-demo-emptydir-pod -- cat /scratch/note.txt
```

**Expected output**: it's gone. The new Pod got a new, empty volume:

```
cat: can't open '/scratch/note.txt': No such file or directory
command terminated with exit code 1
```

### PersistentVolume and PersistentVolumeClaim: static binding

**Why**: data that has to outlive a Pod needs storage that exists
independently of it. That's two objects:

- A **PersistentVolume** (PV) is a piece of storage: a directory on a
  node, an NFS share, a cloud disk.
- A **PersistentVolumeClaim** (PVC) is a request for storage, with a
  size and an access mode. Kubernetes binds it to a PV that matches.
  Pods refer to the PVC, not the PV.

With **static** provisioning, an administrator creates the PVs in
advance. With **dynamic** provisioning (next section), a StorageClass
creates a PV for each PVC as needed.

A PVC's `storageClassName` decides which you get, and leaving it out
is not the same as setting it to `""`. `""` means "no StorageClass":
bind to an existing PV. If the field is missing, an admission plugin
called `DefaultStorageClass` fills in the cluster's default
StorageClass (admission plugins check or change requests before they're
stored; chapter 9 covers them). Then the PVC gets a new, dynamically
provisioned volume, even if a suitable PV already exists.

**Example**: start with the simplest kind of storage, a directory on a
node. [`hostpath-pv.yaml`](examples/config-storage/hostpath-pv.yaml)
uses a `hostPath` volume. Such a directory only exists on one node, so
the PV says which, with a `nodeAffinity` rule (chapter 7 covers node
affinity). [`hostpath-pvc.yaml`](examples/config-storage/hostpath-pvc.yaml)
sets `storageClassName: ""`:

```
kubectl apply -f tutorial/examples/config-storage/hostpath-pv.yaml
kubectl apply -f tutorial/examples/config-storage/hostpath-pvc.yaml
kubectl get pv config-storage-demo-hostpath-pv
kubectl get pvc config-storage-demo-hostpath-pvc
```

**Expected output**: the PVC is bound to the PV, with no provisioner
involved:

```
persistentvolume/config-storage-demo-hostpath-pv created
persistentvolumeclaim/config-storage-demo-hostpath-pvc created
NAME                              CAPACITY   ACCESS MODES   RECLAIM POLICY   STATUS   CLAIM                                      STORAGECLASS   VOLUMEATTRIBUTESCLASS   REASON   AGE
config-storage-demo-hostpath-pv   1Gi        RWO            Retain           Bound    default/config-storage-demo-hostpath-pvc                  <unset>                          0s
NAME                               STATUS   VOLUME                            CAPACITY   ACCESS MODES   STORAGECLASS   VOLUMEATTRIBUTESCLASS   AGE
config-storage-demo-hostpath-pvc   Bound    config-storage-demo-hostpath-pv   1Gi        RWO                           <unset>                 0s
```

Start a Pod that uses the PVC:

```
kubectl apply -f tutorial/examples/config-storage/hostpath-pod.yaml
```

When it's running, write a file through it, then read the same file on
the node itself:

```
kubectl exec config-storage-demo-hostpath-pod -- sh -c "echo written-by-pod > /mnt/hostpath/from-pod.txt; cat /mnt/hostpath/from-pod.txt"
docker exec k8s-lab-default-worker cat /tmp/config-storage-demo-hostpath/from-pod.txt
```

**Expected output**: the file the Pod wrote is on the node's own
filesystem:

```
written-by-pod
written-by-pod
```

The data is on one node's disk. That's why the PV needs `nodeAffinity`,
and why the NFS PV below doesn't.

Now the same thing with shared storage. This repo's
`lab-helpers/nfs-server/` runs an NFS server on the `kind` Docker
network. Start it, and install the NFS client on the nodes, with
`make nfs-up` and `make nfs-client-install PROFILE=default` (see
[lab-helpers/nfs-server/README.md](../lab-helpers/nfs-server/README.md),
which also explains why the PV uses `nfs.path: /`).
[`nfs-pv.yaml`](examples/config-storage/nfs-pv.yaml) and
[`nfs-pvc.yaml`](examples/config-storage/nfs-pvc.yaml) both set
`storageClassName: ""`:

```
kubectl apply -f tutorial/examples/config-storage/nfs-pv.yaml
kubectl apply -f tutorial/examples/config-storage/nfs-pvc.yaml
kubectl get pv config-storage-demo-nfs-pv
kubectl get pvc config-storage-demo-nfs-pvc
```

**Expected output**: the PVC is bound to the named PV, shown under
`VOLUME`:

```
persistentvolume/config-storage-demo-nfs-pv created
persistentvolumeclaim/config-storage-demo-nfs-pvc created
NAME                         CAPACITY   ACCESS MODES   RECLAIM POLICY   STATUS   CLAIM                                 STORAGECLASS   VOLUMEATTRIBUTESCLASS   REASON   AGE
config-storage-demo-nfs-pv   1Gi        RWX            Retain           Bound    default/config-storage-demo-nfs-pvc                  <unset>                          2s
NAME                          STATUS   VOLUME                       CAPACITY   ACCESS MODES   STORAGECLASS   VOLUMEATTRIBUTESCLASS   AGE
config-storage-demo-nfs-pvc   Bound    config-storage-demo-nfs-pv   1Gi        RWX                           <unset>                 2s
```

Start a Pod that uses it, and when it's running, write a file to the
share and list it:

```
kubectl apply -f tutorial/examples/config-storage/nfs-pod.yaml
kubectl exec config-storage-demo-nfs-pod -- sh -c "echo written-by-pod > /mnt/nfs/from-pod.txt; ls -la /mnt/nfs"
```

**Expected output**: `hello.txt` was already there: it's in
`lab-helpers/nfs-server/data/`, the directory the NFS server shares.
(The owner of that directory and `hello.txt` is shown as numbers: they
belong to whoever cloned this repo, a user the busybox container
doesn't know.)

```
pod/config-storage-demo-nfs-pod created
total 16
drwxr-xr-x    2 1000     985           4096 Aug 28 04:31 .
drwxr-xr-x    3 root     root          4096 Nov 19 11:52 ..
-rw-r--r--    1 root     root            15 Nov 19 11:53 from-pod.txt
-rw-r--r--    1 1000     985              9 Aug 21 02:08 hello.txt
```

Now what happens when `storageClassName` is left out.
[`pvc-omitted-storageclassname.yaml`](examples/config-storage/pvc-omitted-storageclassname.yaml)
asks for `ReadWriteOnce` storage and doesn't mention a StorageClass.
The PVC needs a Pod that uses it,
[`pvc-omitted-storageclassname-pod.yaml`](examples/config-storage/pvc-omitted-storageclassname-pod.yaml):
kind's default StorageClass uses `volumeBindingMode:
WaitForFirstConsumer`, so it doesn't create a volume until a Pod needs
one:

```
kubectl apply -f tutorial/examples/config-storage/pvc-omitted-storageclassname.yaml
kubectl apply -f tutorial/examples/config-storage/pvc-omitted-storageclassname-pod.yaml
kubectl get pvc config-storage-demo-omitted-scn-pvc
```

**Expected output**: the PVC is bound to a new PV named `pvc-<uid>`, and
`STORAGECLASS` is `standard`, although the file never mentions a
StorageClass:

```
persistentvolumeclaim/config-storage-demo-omitted-scn-pvc created
pod/config-storage-demo-omitted-scn-pod created
NAME                                  STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS   VOLUMEATTRIBUTESCLASS   AGE
config-storage-demo-omitted-scn-pvc   Bound    pvc-9e9f6c96-8cec-4734-97ba-0cde55eabff1   1Gi        RWO            standard       <unset>                 10s
```

(If it still says `Pending`, the Pod hasn't been scheduled yet; look
again a few seconds later.)

Compare that with the NFS PVC: there, `STORAGECLASS` was empty and
`VOLUME` was the PV you created. That's the difference between `""`
and leaving the field out.

### StorageClass and dynamic provisioning

**Why**: writing a PV by hand for every PVC doesn't scale. A
**StorageClass** names a **provisioner**, a program that creates a PV
whenever a PVC asks for that class. kind comes with one StorageClass,
`standard`, which is the default. Its provisioner,
`rancher.io/local-path`, creates each volume as a directory on the node
where the Pod runs, with no replication (see [DESIGN.md](../DESIGN.md),
"Storage"). Because of that, it only supports `ReadWriteOnce` (one node
at a time) and refuses any other access mode.

**Example**: [`pvc-rwx-standard.yaml`](examples/config-storage/pvc-rwx-standard.yaml)
asks the default StorageClass for `ReadWriteMany` (many nodes at once).
Apply it on its own first:

```
kubectl apply -f tutorial/examples/config-storage/pvc-rwx-standard.yaml
kubectl get pvc config-storage-demo-rwx-pvc
kubectl describe pvc config-storage-demo-rwx-pvc
```

**Expected output**: the PVC is `Pending`, and all you see is the usual
`WaitForFirstConsumer` message, which never changes. The end of the
`describe` output:

```
persistentvolumeclaim/config-storage-demo-rwx-pvc created
NAME                          STATUS    VOLUME   CAPACITY   ACCESS MODES   STORAGECLASS   VOLUMEATTRIBUTESCLASS   AGE
config-storage-demo-rwx-pvc   Pending                                      standard       <unset>                 6s
...
Events:
  Type    Reason                Age   From                         Message
  ----    ------                ----  ----                         -------
  Normal  WaitForFirstConsumer  5s    persistentvolume-controller  waiting for first consumer to be created before binding
```

Now start a Pod that uses it,
[`pvc-rwx-standard-pod.yaml`](examples/config-storage/pvc-rwx-standard-pod.yaml):

```
kubectl apply -f tutorial/examples/config-storage/pvc-rwx-standard-pod.yaml
kubectl describe pvc config-storage-demo-rwx-pvc
```

**Expected output**: the provisioner tries to create the volume, and the
events show why it can't:

```
pod/config-storage-demo-rwx-pod created
...
Events:
  Type     Reason                Age               From                                                                                                Message
  ----     ------                ----              ----                                                                                                -------
  Normal   WaitForFirstConsumer  15s               persistentvolume-controller                                                                         waiting for first consumer to be created before binding
  Normal   Provisioning          10s               rancher.io/local-path_local-path-provisioner-855c7b7774-bbjhp_891ef86b-48bb-4886-9eb6-b4888b61cd0d  External provisioner is provisioning volume for claim "default/config-storage-demo-rwx-pvc"
  Warning  ProvisioningFailed    10s               rancher.io/local-path_local-path-provisioner-855c7b7774-bbjhp_891ef86b-48bb-4886-9eb6-b4888b61cd0d  failed to provision volume with StorageClass "standard": NodePath only supports ReadWriteOnce and ReadWriteOncePod (1.22+) access modes
  Normal   ExternalProvisioning  6s (x2 over 10s)  persistentvolume-controller                                                                         Waiting for a volume to be created either by the external provisioner 'rancher.io/local-path' or manually by the system administrator. If volume creation is delayed, please verify that the provisioner is running and correctly registered.
```

The Pod stays `Pending` as well, with no events of its own: the
explanation is on the PVC. So a PVC that's waiting for a Pod and a PVC
that can't be provisioned look the same until a Pod uses them. When a
PVC seems stuck, check whether any Pod uses it, as well as its
events.

### Cleaning up

Every object in this chapter comes from a file in
`tutorial/examples/config-storage/`, so one command deletes them all.
It takes about 30 seconds, because of the `sleep` Pods. Then stop the
NFS server:

```
kubectl delete -f tutorial/examples/config-storage/
make nfs-down
```

The end of the output:

```
pod "config-storage-demo-secret-pod" deleted from default namespace
secret "config-storage-demo-secret" deleted from default namespace
k8s-lab-nfs-server removed (lab-helpers/nfs-server/data left in place)
```

The two PVs you created yourself are deleted too. The one the
provisioner created is deleted by the provisioner, a few seconds after
its PVC: the `standard` StorageClass's reclaim policy is `Delete`. The
files the Pods wrote stay where they were: `from-pod.txt` in
`lab-helpers/nfs-server/data/` (which git ignores), and in
`/tmp/config-storage-demo-hostpath/` on the worker node until the
cluster is deleted.
