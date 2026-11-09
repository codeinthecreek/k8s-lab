# gpu-real lab helper

Lab-only setup for tutorial chapter 17: a real GPU on a kind worker (cluster
`k8s-lab-gpu-real`, created with nvkind). Needs an NVIDIA driver and
nvidia-container-toolkit already installed. From the repo root:

```
lab-helpers/gpu-real/nvidia-docker-runtime.sh enable   # sudo, host-wide
make up PROFILE=gpu-real
eval "$(make -s gpu-real-env)"                         # helm state stays in .cache/
# ... chapter 17 (kubectl context: kind-k8s-lab-gpu-real) ...
make down PROFILE=gpu-real
lab-helpers/gpu-real/nvidia-docker-runtime.sh disable  # sudo, restores + verifies
make clean PROFILE=gpu-real                            # when done with the GPU chapters
```
While enabled, for every container on the host: nvidia is Docker's default
runtime (not `runc`), a bind mount at `/var/run/nvidia-container-devices/<index|all>`
requests a GPU, CDI is on, and Docker was restarted. `enable` refuses while any
container runs. `disable` (works with Docker stopped) restores both files from
`/var/backups/k8s-lab-gpu-real/` and checks `/etc/docker`, `/etc/nvidia-container-runtime`
and `/etc/cdi` against a sha256 record. `--help` lists every path written;
`make clean` removes only `.cache/` here.
