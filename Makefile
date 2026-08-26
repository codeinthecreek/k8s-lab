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

.PHONY: up down reset list-profiles kubeconfig status nfs-up nfs-down nfs-status nfs-client-install

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
