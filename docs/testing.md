# Testing

Manual commands for bringing up each profile, smoke-testing ingress and
metrics against it, and tearing it down. This is what was actually run to
verify both profiles against real clusters - see `docs/findings.md` for
problems hit while doing this the first time.

All `kubectl` commands below use `--context` explicitly so it doesn't
matter which cluster is currently your default context.

## `default` profile

```bash
# Bring up
make up PROFILE=default

# Check nodes/pods
make status PROFILE=default

# Ingress test
kubectl --context kind-k8s-lab-default create deployment hello \
  --image=registry.k8s.io/e2e-test-images/agnhost:2.53 -- /agnhost netexec --http-port=8080
kubectl --context kind-k8s-lab-default expose deployment hello --port=80 --target-port=8080
kubectl --context kind-k8s-lab-default create ingress hello \
  --class=nginx --rule="hello.local/*=hello:80"

# give nginx a few seconds to pick up the config, then:
curl -H "Host: hello.local" http://localhost/
# expect: 200 with a JSON body from agnhost (a 503 right after creating the
# Ingress is normal - just retry after a few seconds)

# Metrics test (may return nothing for the first ~30-60s after cluster up)
kubectl --context kind-k8s-lab-default top nodes
kubectl --context kind-k8s-lab-default top pods -A

# Tear down (also removes the hello test resources, no separate cleanup needed)
make down PROFILE=default
```

## `ha-control-plane` profile

```bash
# Only one ingress-enabled profile can run at a time - bring default down first
# if it's still up:
make down PROFILE=default

# Bring up
make up PROFILE=ha-control-plane

# Check nodes/pods (expect 3 control-plane + 2 worker, all Ready)
make status PROFILE=ha-control-plane

# Confirm the Envoy load-balancer container exists
docker ps --filter "name=k8s-lab-ha-control-plane"

# Inspect Envoy's real (dynamic) config - NOT /etc/envoy/envoy.yaml, which is
# unused stock demo config in this image
docker exec k8s-lab-ha-control-plane-external-load-balancer cat /home/envoy/cds.yaml
docker exec k8s-lab-ha-control-plane-external-load-balancer cat /home/envoy/lds.yaml

# Ingress test (same pattern as default - ha-control-plane's ingress node is
# a worker, but it's still published on host 80/443)
kubectl --context kind-k8s-lab-ha-control-plane create deployment hello \
  --image=registry.k8s.io/e2e-test-images/agnhost:2.53 -- /agnhost netexec --http-port=8080
kubectl --context kind-k8s-lab-ha-control-plane expose deployment hello --port=80 --target-port=8080
kubectl --context kind-k8s-lab-ha-control-plane create ingress hello \
  --class=nginx --rule="hello.local/*=hello:80"
curl -H "Host: hello.local" http://localhost/

# Metrics test
kubectl --context kind-k8s-lab-ha-control-plane top nodes
kubectl --context kind-k8s-lab-ha-control-plane top pods -A

# Tear down
make down PROFILE=ha-control-plane
```

## Notes

- `curl localhost/` hits whichever ingress-enabled cluster is currently up -
  they share host ports 80/443 (see DESIGN.md's ingress section).
- `kubectl top` can return empty for the first ~30-60 seconds after a
  cluster comes up, while metrics-server does its first scrape. Not a
  failure - just retry.
- A `503` immediately after creating a new `Ingress` resource is normal
  propagation delay while nginx reloads its config - retry after a few
  seconds before assuming something is broken.
