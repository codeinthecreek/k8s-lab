# make up PROFILE=ha-control-plane   (defaults to PROFILE=default)
PROFILE ?= default

PROFILE_DIR  := kind/profiles/$(PROFILE)
CLUSTER_NAME := k8s-lab-$(PROFILE)
CONTEXT      := kind-$(CLUSTER_NAME)

.PHONY: up down reset list-profiles kubeconfig status

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
	kubectl --context $(CONTEXT) get nodes -o wide
	kubectl --context $(CONTEXT) get pods -A
