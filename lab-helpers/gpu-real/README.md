# gpu-real lab helper

Lab-only setup for tutorial chapters 17 and 18: a real GPU on a kind worker (cluster
`k8s-lab-gpu-real`, created with nvkind). Needs an NVIDIA driver and
nvidia-container-toolkit already installed. From the repo root:

```
lab-helpers/gpu-real/nvidia-docker-runtime.sh enable   # sudo, host-wide
make up PROFILE=gpu-real
eval "$(make -s gpu-real-env)"                         # helm state stays in .cache/
# ... chapter 17 or 18 (kubectl context: kind-k8s-lab-gpu-real) ...
make down PROFILE=gpu-real
lab-helpers/gpu-real/nvidia-docker-runtime.sh disable  # sudo, restores + verifies
make clean PROFILE=gpu-real                            # when done with the GPU chapters
```

Chapter 18 starts from a fresh cluster, not from where chapter 17 ended. After
`make up` and the `eval` line above, from the repo root, this installs the device
plugin the way chapter 17's first section does (the label is the
stand-in for what NFD/GFD set on a real cluster; `runtimeClassName` selects the
`nvidia` RuntimeClass that nvkind registers):

```
kubectl label node k8s-lab-gpu-real-worker nvidia.com/gpu.present=true
helm repo add nvdp https://nvidia.github.io/k8s-device-plugin
helm repo update
helm install nvdp nvdp/nvidia-device-plugin --version 0.20.1 --namespace nvidia-device-plugin --create-namespace --set runtimeClassName=nvidia
kubectl wait --for=jsonpath='{.status.allocatable.nvidia\.com/gpu}'=1 node/k8s-lab-gpu-real-worker --timeout=180s
```

While enabled, for every container on the host: nvidia is Docker's default
runtime (not `runc`), a bind mount at `/var/run/nvidia-container-devices/<index|all>`
requests a GPU, CDI is on, and Docker was restarted. `enable` refuses while any
container runs. `disable` (works with Docker stopped) restores both files from
`/var/backups/k8s-lab-gpu-real/` and checks `/etc/docker`, `/etc/nvidia-container-runtime`
and `/etc/cdi` against a sha256 record. `--help` lists every path written;
`make clean` removes only `.cache/` here.
