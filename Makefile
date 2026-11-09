# make up PROFILE=ha-control-plane   (defaults to PROFILE=default)
PROFILE ?= default

PROFILE_DIR  := kind/profiles/$(PROFILE)
CLUSTER_NAME := k8s-lab-$(PROFILE)
CONTEXT      := kind-$(CLUSTER_NAME)

# lab-helpers/nfs-server - see lab-helpers/nfs-server/README.md.
# For a PersistentVolume/PersistentVolumeClaim lab exercise.
# Profile-independent: the NFS server container isn't tied to any one
# kind cluster's lifecycle, just to the shared "kind" Docker network.
NFS_CONTAINER := k8s-lab-nfs-server
NFS_IMAGE     := itsthenetwork/nfs-server-alpine:latest
NFS_DATA_DIR  := lab-helpers/nfs-server/data

# lab-helpers/registry - see lab-helpers/registry/README.md.
# For tutorial chapter 13 (source code -> running workload). Same
# profile-independent shape as nfs-server: one registry container shared
# across profiles via the "kind" Docker network, published on the host so
# `docker build`/`push` from outside the cluster can reach it too. Every
# profile's cluster.yaml carries the containerd config_path patch this
# depends on (see DESIGN.md's "Local registry: containerd config_path
# patch") - it can't be added after cluster creation.
REGISTRY_CONTAINER := k8s-lab-registry
REGISTRY_IMAGE      := registry:3
REGISTRY_PORT        := 5001
REGISTRY_DATA_DIR   := lab-helpers/registry/data

# lab-helpers/gpu-real - PROFILE=gpu-real is a real GPU on a kind worker
# (tutorial ch. 17-18). It is created with nvkind, not `kind create cluster
# --config`, so it has no cluster.yaml: nvkind's default config (1
# control-plane + 1 worker with all GPUs; no GPU label) is used as-is.
# Host-side prerequisite, root-owned and never called from make:
# lab-helpers/gpu-real/nvidia-docker-runtime.sh (`up` only checks its `status`).
# nvkind has no tagged release (checked 2026-11-08): pinned by full commit.
# GPU_REAL_NODE_IMAGE is the same pin as every kind/profiles/*/cluster.yaml;
# bump all of them together (DESIGN.md "Node image pinning").
# Absolute path of the directory holding this Makefile (not the CWD, which
# `make -C` or a subdirectory run would change). Defined before any include.
MAKEFILE_DIR        := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))
GPU_REAL_DIR        := $(MAKEFILE_DIR)/lab-helpers/gpu-real
GPU_REAL_RUNTIME    := $(GPU_REAL_DIR)/nvidia-docker-runtime.sh
GPU_REAL_CACHE      := $(GPU_REAL_DIR)/.cache
GPU_REAL_NVKIND_SHA := c57050497cffee36f10c8b918d2727c4f26d886e
GPU_REAL_NODE_IMAGE := kindest/node:v1.36.1@sha256:3489c7674813ba5d8b1a9977baea8a6e553784dab7b84759d1014dbd78f7ebd5
# Everything go and helm would put in ~/go, ~/.cache or ~/.config goes under
# GPU_REAL_CACHE instead (gitignored). -modcacherw keeps the module cache
# deletable by `make clean`.
GPU_REAL_GOENV      := GOPATH=$(GPU_REAL_CACHE)/go GOBIN=$(GPU_REAL_CACHE)/bin GOMODCACHE=$(GPU_REAL_CACHE)/go/pkg/mod GOCACHE=$(GPU_REAL_CACHE)/gocache GOFLAGS=-modcacherw GOTOOLCHAIN=local

.PHONY: up down reset list-profiles kubeconfig status nfs-up nfs-down nfs-status nfs-client-install registry-up registry-down registry-status registry-client-install clean gpu-real-env

ifneq ($(PROFILE),gpu-real)
up:
	@if [ ! -f $(PROFILE_DIR)/cluster.yaml ]; then \
		echo "no such profile: $(PROFILE_DIR)/cluster.yaml not found" >&2; \
		exit 1; \
	fi
	kind create cluster --name $(CLUSTER_NAME) --config $(PROFILE_DIR)/cluster.yaml --wait 5m
	@echo "--- applying manifests from $(PROFILE_DIR)/manifests.txt ---"
	@while IFS= read -r manifest; do \
		case "$$manifest" in \
			""|"#"*) continue ;; \
		esac; \
		echo "kubectl apply -f $$manifest"; \
		kubectl --context $(CONTEXT) apply -f "$$manifest" || exit 1; \
	done < $(PROFILE_DIR)/manifests.txt
else
up:
	@if ! $(GPU_REAL_RUNTIME) status >/dev/null; then \
		echo "Docker is not set up for GPU kind nodes - run $(GPU_REAL_RUNTIME) enable first" >&2; \
		exit 1; \
	fi
	env $(GPU_REAL_GOENV) go install github.com/NVIDIA/nvkind/cmd/nvkind@$(GPU_REAL_NVKIND_SHA)
	$(GPU_REAL_CACHE)/bin/nvkind cluster create --name $(CLUSTER_NAME) --image $(GPU_REAL_NODE_IMAGE) --wait 5m
	@echo "--- up. To run helm against this cluster without touching ~/.config/helm or ~/.cache/helm:"
	@echo '    eval "$$(make -s gpu-real-env)"'
endif

down:
	kind delete cluster --name $(CLUSTER_NAME)

reset: down up

list-profiles:
	@ls kind/profiles

kubeconfig:
	kind export kubeconfig --name $(CLUSTER_NAME)

status:
	@if [ "$(origin PROFILE)" = "command line" ]; then \
		cluster="$(CLUSTER_NAME)"; \
	else \
		matches="$$(kind get clusters 2>/dev/null | grep '^k8s-lab-')"; \
		count="$$(printf '%s\n' "$$matches" | grep -c .)"; \
		if [ "$$count" -eq 0 ]; then \
			echo "no k8s-lab-* kind cluster is currently up" >&2; \
			exit 1; \
		elif [ "$$count" -gt 1 ]; then \
			echo "multiple k8s-lab-* clusters are up - pass PROFILE explicitly:" >&2; \
			printf '%s\n' "$$matches" | sed 's/^k8s-lab-/  /' >&2; \
			exit 1; \
		fi; \
		cluster="$$matches"; \
	fi; \
	if ! kind get clusters 2>/dev/null | grep -qx "$$cluster"; then \
		echo "cluster $$cluster is not up (context kind-$$cluster not found)" >&2; \
		exit 1; \
	fi; \
	echo "--- profile: $${cluster#k8s-lab-} (context kind-$$cluster) ---"; \
	kubectl --context kind-$$cluster get nodes -o wide; \
	kubectl --context kind-$$cluster get pods -A

# --- lab-helpers/nfs-server (NFS-backed PV/PVC lab exercise) --------------

nfs-up:
	@if [ -n "$$(docker ps -q -f name=^/$(NFS_CONTAINER)$$)" ]; then \
		echo "$(NFS_CONTAINER) already running"; \
		exit 0; \
	fi; \
	net="$$(docker network ls --filter name=^kind$$ --format '{{.Name}}')"; \
	if [ -z "$$net" ]; then \
		echo "no docker network named 'kind' found - bring a kind cluster up first (make up)" >&2; \
		exit 1; \
	fi; \
	if [ ! -d $(NFS_DATA_DIR) ]; then \
		echo "--- seeding $(NFS_DATA_DIR) ---"; \
		mkdir -p $(NFS_DATA_DIR); \
		echo "software" > $(NFS_DATA_DIR)/hello.txt; \
	fi; \
	if [ -n "$$(docker ps -aq -f name=^/$(NFS_CONTAINER)$$)" ]; then \
		echo "--- removing stopped $(NFS_CONTAINER) container ---"; \
		docker rm $(NFS_CONTAINER) >/dev/null; \
	fi; \
	echo "--- starting $(NFS_CONTAINER) on network $$net ---"; \
	docker run -d --privileged \
		--name $(NFS_CONTAINER) \
		--network "$$net" \
		-v $(CURDIR)/$(NFS_DATA_DIR):/nfsshare \
		-e SHARED_DIRECTORY=/nfsshare \
		$(NFS_IMAGE) >/dev/null; \
	echo "$(NFS_CONTAINER) started - see lab-helpers/nfs-server/README.md for the fsid=0 mount-path note"

nfs-down:
	@if [ -n "$$(docker ps -aq -f name=^/$(NFS_CONTAINER)$$)" ]; then \
		docker rm -f $(NFS_CONTAINER) >/dev/null; \
		echo "$(NFS_CONTAINER) removed ($(NFS_DATA_DIR) left in place)"; \
	else \
		echo "$(NFS_CONTAINER) not running"; \
	fi

nfs-status:
	@docker ps --filter "name=^/$(NFS_CONTAINER)$$" --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
	@if command -v showmount >/dev/null 2>&1; then \
		ip="$$(docker inspect $(NFS_CONTAINER) --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 2>/dev/null)"; \
		if [ -z "$$ip" ]; then \
			echo "$(NFS_CONTAINER) not running - nothing to show"; \
		else \
			echo "--- exports (via $$ip - container name doesn't resolve from the host) ---"; \
			if ! showmount -e "$$ip" 2>/dev/null; then \
				echo "showmount reported no exports - expected: this image runs NFSv4-only"; \
				echo "(rpc.mountd --no-nfs-version 2 --no-nfs-version 3), which never registers"; \
				echo "the legacy MOUNT protocol with rpcbind, so showmount can't work against"; \
				echo "it regardless of server health. Verify with an actual mount instead - see"; \
				echo "lab-helpers/nfs-server/README.md."; \
		 	fi; \
		fi; \
	else \
		echo "showmount not found on host - optional, part of nfs-common (Debian/Arch) - skipping export check"; \
	fi

nfs-client-install:
	@nodes="$$(kind get nodes --name $(CLUSTER_NAME) 2>/dev/null)"; \
	if [ -z "$$nodes" ]; then \
		echo "no nodes found for cluster $(CLUSTER_NAME) - is PROFILE=$(PROFILE) up?" >&2; \
		exit 1; \
	fi; \
	for node in $$nodes; do \
		echo "--- $$node ---"; \
		docker exec "$$node" sh -c ' \
			if command -v mount.nfs >/dev/null 2>&1; then \
				echo "nfs-common already installed"; \
			else \
				apt-get update -qq && apt-get install -y -qq nfs-common; \
			fi'; \
	done

# --- lab-helpers/registry (local image registry for tutorial ch. 13) -----

registry-up:
	@if [ -n "$$(docker ps -q -f name=^/$(REGISTRY_CONTAINER)$$)" ]; then \
		echo "$(REGISTRY_CONTAINER) already running"; \
		exit 0; \
	fi; \
	if [ ! -d $(REGISTRY_DATA_DIR) ]; then \
		mkdir -p $(REGISTRY_DATA_DIR); \
	fi; \
	if [ -n "$$(docker ps -aq -f name=^/$(REGISTRY_CONTAINER)$$)" ]; then \
		echo "--- removing stopped $(REGISTRY_CONTAINER) container ---"; \
		docker rm $(REGISTRY_CONTAINER) >/dev/null; \
	fi; \
	echo "--- starting $(REGISTRY_CONTAINER) on 127.0.0.1:$(REGISTRY_PORT) ---"; \
	docker run -d --restart=always \
		-p "127.0.0.1:$(REGISTRY_PORT):5000" \
		--network bridge \
		--name $(REGISTRY_CONTAINER) \
		-v $(CURDIR)/$(REGISTRY_DATA_DIR):/var/lib/registry \
		$(REGISTRY_IMAGE) >/dev/null; \
	echo "$(REGISTRY_CONTAINER) started - run 'make registry-client-install PROFILE=x' before pulling from it on that profile"

registry-down:
	@if [ -n "$$(docker ps -aq -f name=^/$(REGISTRY_CONTAINER)$$)" ]; then \
		docker rm -f $(REGISTRY_CONTAINER) >/dev/null; \
		echo "$(REGISTRY_CONTAINER) removed ($(REGISTRY_DATA_DIR) left in place)"; \
	else \
		echo "$(REGISTRY_CONTAINER) not running"; \
	fi

registry-status:
	@docker ps --filter "name=^/$(REGISTRY_CONTAINER)$$" --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
	@if [ -n "$$(docker ps -q -f name=^/$(REGISTRY_CONTAINER)$$)" ]; then \
		echo "--- repositories (via host-published port) ---"; \
		curl -sS "http://localhost:$(REGISTRY_PORT)/v2/_catalog" || true; \
		echo; \
	fi

registry-client-install:
	@if [ -z "$$(docker ps -q -f name=^/$(REGISTRY_CONTAINER)$$)" ]; then \
		echo "$(REGISTRY_CONTAINER) not running - run 'make registry-up' first" >&2; \
		exit 1; \
	fi; \
	nodes="$$(kind get nodes --name $(CLUSTER_NAME) 2>/dev/null)"; \
	if [ -z "$$nodes" ]; then \
		echo "no nodes found for cluster $(CLUSTER_NAME) - is PROFILE=$(PROFILE) up?" >&2; \
		exit 1; \
	fi; \
	net="$$(docker network ls --filter name=^kind$$ --format '{{.Name}}')"; \
	if [ -z "$$net" ]; then \
		echo "no docker network named 'kind' found" >&2; \
		exit 1; \
	fi; \
	if [ "$$(docker inspect -f '{{json .NetworkSettings.Networks.kind}}' $(REGISTRY_CONTAINER))" = 'null' ]; then \
		echo "--- connecting $(REGISTRY_CONTAINER) to the kind network ---"; \
		docker network connect kind $(REGISTRY_CONTAINER); \
	fi; \
	registry_dir="/etc/containerd/certs.d/localhost:$(REGISTRY_PORT)"; \
	for node in $$nodes; do \
		echo "--- $$node ---"; \
		docker exec "$$node" mkdir -p "$$registry_dir"; \
		printf '[host."http://%s:5000"]\n' "$(REGISTRY_CONTAINER)" | docker exec -i "$$node" cp /dev/stdin "$$registry_dir/hosts.toml"; \
	done; \
	printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: local-registry-hosting\n  namespace: kube-public\ndata:\n  localRegistryHosting.v1: |\n    host: "localhost:%s"\n    help: "https://kind.sigs.k8s.io/docs/user/local-registry/"\n' "$(REGISTRY_PORT)" | kubectl --context $(CONTEXT) apply -f -

# --- lab-helpers/gpu-real (real GPU on a kind worker, tutorial ch. 17-18) ---

# Prints export lines; use as: eval "$(make -s gpu-real-env)". Read-only.
gpu-real-env:
	@echo 'export HELM_CONFIG_HOME=$(GPU_REAL_CACHE)/helm/config'
	@echo 'export HELM_CACHE_HOME=$(GPU_REAL_CACHE)/helm/cache'
	@echo 'export HELM_DATA_HOME=$(GPU_REAL_CACHE)/helm/data'
	@echo 'export HELM_REPOSITORY_CONFIG=$(GPU_REAL_CACHE)/helm/repositories.yaml'
	@echo 'export HELM_REPOSITORY_CACHE=$(GPU_REAL_CACHE)/helm/repository'

# Only PROFILE=gpu-real has anything to clean, and it removes only
# lab-helpers/gpu-real/.cache. No image is removed: the pinned kindest/node
# image is shared with the other profiles. The nvidia/ images used inside the
# cluster live in the nodes' containerd and go away with `make down`.
ifeq ($(PROFILE),gpu-real)
clean:
	@if kind get clusters 2>/dev/null | grep -qx $(CLUSTER_NAME); then \
		echo "cluster $(CLUSTER_NAME) exists - run 'make down PROFILE=gpu-real' first" >&2; \
		exit 1; \
	fi
	@root="$$(realpath -- '$(MAKEFILE_DIR)')" && cache="$$(realpath -m -- '$(GPU_REAL_CACHE)')" || exit 1; \
	if [ -z "$$root" ] || [ "$$root" = / ] || [ ! -f "$$root/Makefile" ] || [ ! -f "$$root/DESIGN.md" ] \
	   || [ "$$cache" != "$$root/lab-helpers/gpu-real/.cache" ]; then \
		echo "refusing to remove '$$cache': not <repo>/lab-helpers/gpu-real/.cache inside '$$root'" >&2; \
		exit 1; \
	fi; \
	echo "removing $$cache"; \
	rm -rf -- "$$cache"
else
clean:
	@echo "nothing to clean for PROFILE=$(PROFILE) (only PROFILE=gpu-real has a clean step)"
endif
