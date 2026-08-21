# nfs-server lab helper

Lab-only infrastructure for a PersistentVolume/PersistentVolumeClaim
lab exercise built around a real NFS server. Not part of normal
`make up` - see the top-level README's "Lab helpers" section for how this
fits into the rest of the repo.

The exercise this is based on runs `nfs-kernel-server` on a dedicated VM.
This gives you the same thing - a real NFS server, not a `hostPath`
substitute - but as a container (`itsthenetwork/nfs-server-alpine`)
attached to the `kind` Docker network, so it's reachable by container name
from kind node containers via Docker's embedded DNS.

## Usage

From the repo root:

```
make nfs-up                              # start the NFS server container
make nfs-status                          # confirm it's running + show exports
make nfs-client-install PROFILE=default  # install nfs-common on that profile's nodes
make nfs-down                            # stop and remove the container (data/ persists)
```

`nfs-up` requires a kind cluster to already be up (any profile) - the
`kind` Docker network it attaches to only exists once at least one kind
cluster has been created.

## fsid=0: exports live at `/`, not `/nfsshare`

`itsthenetwork/nfs-server-alpine` exports the directory named by
`SHARED_DIRECTORY` (`/nfsshare` here, bind-mounted from `data/`) with
`fsid=0` set on it. NFSv4 treats the `fsid=0` export as the client's
mount root, so clients mount it at path `/`, **not** `/nfsshare`:

```
mount -t nfs k8s-lab-nfs-server:/ /mnt/nfstest      # correct
mount -t nfs k8s-lab-nfs-server:/nfsshare /mnt/nfstest   # wrong - will fail
```

This matters for the PV manifest that backs this (e.g. a `PVol.yaml`):
its `nfs.path` field must be `/`, with `nfs.server` set to
`k8s-lab-nfs-server`.

## Why nfs-client-install has to be re-run

The `kindest/node` image doesn't ship `nfs-common`, so kubelet can't run
`mount.nfs` and any Pod requesting the NFS volume fails to mount
(`mount.nfs: ... No such file or directory` - see
kubernetes-sigs/kind#1806). `make nfs-client-install PROFILE=x` installs
it into every running node container for that profile, but node
containers are ephemeral: recreating the profile (`make reset`, or
`down` + `up`) wipes the install along with the rest of the container.
Re-run `nfs-client-install` any time the target profile's nodes are
recreated, before trying the NFS-backed PV/PVC lab steps again.

## data/

`data/` is created on first `make nfs-up` and seeded with `hello.txt`
containing `software`, mirroring the original exercise's
`/opt/sfw/hello.txt` so the lab's verification steps (`ls -l /mnt/`, etc.)
have something to find. It's gitignored - lab-generated data, not repo
content.
