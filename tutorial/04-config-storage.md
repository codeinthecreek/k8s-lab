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
kubectl exec config-storage-demo-cm-pod -- env | grep -E '^(greeting|motd)='
kubectl exec config-storage-demo-cm-pod -- cat /etc/config/motd
kubectl exec config-storage-demo-cm-pod -- ls /etc/config
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
motd=Line one of the message of the day.
Line two of the message of the day.
```

The mounted volume has one file per key, and the file has both
lines:

```
$ kubectl exec config-storage-demo-cm-pod -- cat /etc/config/motd
Line one of the message of the day.
Line two of the message of the day.

$ kubectl exec config-storage-demo-cm-pod -- ls /etc/config
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
kubectl apply -f tutorial/examples/config-storage/secret-pod.yaml
kubectl exec config-storage-demo-secret-pod -- cat /etc/secret/password
```

**Expected output**: the stored value under `data` is base64. There's no
`stringData` field; the plain-text value only appears inside the
`last-applied-configuration` annotation that `kubectl apply` adds (see
chapter 2):

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

`czNjcjN0LWRlbW8tdmFsdWU=` decodes to `s3cr3t-demo-value`
(`echo czNjcjN0LWRlbW8tdmFsdWU= | base64 -d`). The kubelet decodes the
value when it mounts the Secret, so the file in the Pod holds the
plain text:

```
$ kubectl exec config-storage-demo-secret-pod -- cat /etc/secret/password
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
kubectl exec config-storage-demo-emptydir-pod -- sh -c "echo scratch data > /scratch/note.txt"
kubectl exec config-storage-demo-emptydir-pod -- cat /scratch/note.txt
kubectl delete pod config-storage-demo-emptydir-pod
kubectl apply -f tutorial/examples/config-storage/emptydir-pod.yaml
kubectl exec config-storage-demo-emptydir-pod -- cat /scratch/note.txt
```

**Expected output**: the file is there until the Pod is deleted. The
new Pod gets a new, empty volume:

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

You may notice that `kubectl delete pod` takes about 30 seconds here.
The container's only process, `sleep`, started by `sh -c`, runs as
PID 1 and doesn't handle `SIGTERM`, the signal asking it to stop. The
kernel ignores unhandled signals for PID 1, so the kubelet waits out the
30-second grace period and then sends `SIGKILL`. Programs that handle
`SIGTERM`, such as nginx, stop straight away.

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
kubectl apply -f tutorial/examples/config-storage/hostpath-pod.yaml
kubectl exec config-storage-demo-hostpath-pod -- sh -c "echo written-by-pod > /mnt/hostpath/from-pod.txt; cat /mnt/hostpath/from-pod.txt"
```

**Expected output**: the PVC is bound to the PV, with no provisioner
involved:

```
persistentvolume/config-storage-demo-hostpath-pv created
persistentvolumeclaim/config-storage-demo-hostpath-pvc created

NAME                               STATUS   VOLUME                            CAPACITY   ACCESS MODES   STORAGECLASS   AGE
config-storage-demo-hostpath-pvc   Bound    config-storage-demo-hostpath-pv   1Gi        RWO                           1s
```

The file the Pod wrote is on the node's own filesystem. You can read it
there with `docker exec k8s-lab-default-worker cat
/tmp/config-storage-demo-hostpath/from-pod.txt`:

```
$ kubectl exec config-storage-demo-hostpath-pod -- sh -c "echo written-by-pod > /mnt/hostpath/from-pod.txt; cat /mnt/hostpath/from-pod.txt"
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
kubectl apply -f tutorial/examples/config-storage/nfs-pod.yaml
kubectl exec config-storage-demo-nfs-pod -- sh -c "echo written-by-pod > /mnt/nfs/from-pod.txt; ls -la /mnt/nfs"
```

**Expected output**: the PVC is bound to the named PV, shown under
`VOLUME`:

```
persistentvolume/config-storage-demo-nfs-pv created
persistentvolumeclaim/config-storage-demo-nfs-pvc created

NAME                         CAPACITY   ACCESS MODES   RECLAIM POLICY   STATUS   CLAIM                                   STORAGECLASS   AGE
config-storage-demo-nfs-pv   1Gi        RWX            Retain           Bound    default/config-storage-demo-nfs-pvc                    4s

NAME                          STATUS   VOLUME                       CAPACITY   ACCESS MODES   STORAGECLASS   AGE
config-storage-demo-nfs-pvc   Bound    config-storage-demo-nfs-pv   1Gi        RWX                           4s
```

The Pod mounts the share and writes to it. `hello.txt` was already
there: it's in `lab-helpers/nfs-server/data/`, the directory the NFS
server shares:

```
pod/config-storage-demo-nfs-pod created

total 16
drwxr-xr-x    2 1000     985           4096 Aug 28 04:31 .
drwxr-xr-x    3 root     root          4096 Aug 28 04:31 ..
-rw-r--r--    1 root     root            15 Aug 28 04:31 from-pod.txt
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

NAME                                   STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS   AGE
config-storage-demo-omitted-scn-pvc   Bound    pvc-a7c865a6-418c-424d-8c64-7f02069faecb   1Gi        RWO            standard       7s
```

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
Again, a Pod has to use the PVC before anything happens:

```
kubectl apply -f tutorial/examples/config-storage/pvc-rwx-standard.yaml
kubectl apply -f tutorial/examples/config-storage/pvc-rwx-standard-pod.yaml
kubectl get pvc config-storage-demo-rwx-pvc
kubectl describe pvc config-storage-demo-rwx-pvc
```

**Expected output**: the PVC stays `Pending`. If you look at it before
any Pod uses it, all you see is the usual `WaitForFirstConsumer`
message, which never changes:

```
NAME                          STATUS    STORAGECLASS   AGE
config-storage-demo-rwx-pvc   Pending   standard       20s

Events:
  Type    Reason                Age  From                          Message
  ----    ------                ---  ----                          -------
  Normal  WaitForFirstConsumer  20s  persistentvolume-controller   waiting for first consumer to be created before binding
```

Once a Pod uses it, the provisioner tries to create the volume, and
the events show why it can't:

```
Events:
  Type     Reason                Age  From                                                                  Message
  ----     ------                ---  ----                                                                  -------
  Normal   WaitForFirstConsumer  20s  persistentvolume-controller                                           waiting for first consumer to be created before binding
  Normal   ExternalProvisioning  14s  persistentvolume-controller                                           Waiting for a volume to be created either by the external provisioner 'rancher.io/local-path' or manually by the system administrator...
  Normal   Provisioning          5s   rancher.io/local-path_local-path-provisioner-855c7b7774-pkjfx_...      External provisioner is provisioning volume for claim "default/config-storage-demo-rwx-pvc"
  Warning  ProvisioningFailed    5s   rancher.io/local-path_local-path-provisioner-855c7b7774-pkjfx_...      failed to provision volume with StorageClass "standard": NodePath only supports ReadWriteOnce and ReadWriteOncePod (1.22+) access modes
```

The Pod stays `Pending` as well, with no events of its own: the
explanation is on the PVC. So a PVC that's waiting for a Pod and a PVC
that can't be provisioned look the same until a Pod uses them. When a
PVC seems stuck, check whether any Pod uses it, as well as its
events.
