# 8. Security

Every `kubectl` command and every in-cluster request this tutorial has
run so far went through the same three independent checks: who is this
(authentication), are they allowed to do this specific thing
(authorization), and does this specific request get accepted as-is or
modified/rejected (admission control) - each stage entirely independent
of the others, so success at one says nothing about the next. This
chapter covers identity (ServiceAccounts), the authorization layer
(RBAC), the admission layer (Pod Security Admission), and NetworkPolicy
- which depends on chapter 5's networking model and needs its own
CNI-enforcement caveat front and center.

### ServiceAccounts: identity for talking to the API

**Why**: every Pod runs as some identity when it talks to the API server
- by default, the `default` ServiceAccount in its namespace, used
implicitly and invisibly in every earlier chapter's Pods. Since
**1.24**, a ServiceAccount no longer gets an auto-generated long-lived
token Secret the moment it's created - `kubectl create token
<sa-name>` mints a short-lived JWT on demand (default ~1h TTL) via the
TokenRequest API instead. Material written assuming "just `kubectl get
secret` to find the SA's token" predates this and no longer works that
way.

**Example**: create a ServiceAccount, mint a token for it, and use that
token directly against the API server - the same "kubectl is just an
HTTPS client" fact chapter 2 established, now with a non-`kubectl`
identity:

```
kubectl apply -f tutorial/examples/security/serviceaccount.yaml
kubectl get secrets | grep security-demo-sa
TOKEN=$(kubectl create token security-demo-sa)
APISERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
curl -sS -k -H "Authorization: Bearer $TOKEN" "$APISERVER/api/v1/namespaces/default/pods" -o /dev/null -w '%{http_code}\n'
```

**Expected output**: no matching Secret at all - `kubectl get secrets |
grep` returns nothing - and the minted JWT is real enough to
authenticate against the API server directly, no `kubectl` credentials
involved:

```
serviceaccount/security-demo-sa created
(no secrets matched - expected since 1.24)
403
```

`403`, not `401` - the token is genuinely valid (authentication
succeeded), it just has no permissions yet (authorization hasn't granted
any). That distinction is the entire point of the next subsection.

### RBAC: authorization is purely additive

**Why**: RBAC grants permissions - there is no explicit "deny" rule.
Effective permissions for any identity are the union of every
Role/ClusterRole bound to it; if nothing grants a permission, it's
denied by default, but nothing can override a grant with a more
specific denial. Scoping is independent per API group **and** resource
type - a Role granting access to `pods` grants nothing at all on
`deployments.apps`, even though both are "workloads" conceptually. This
also demonstrates authentication and authorization as genuinely separate
stages: the token from the previous subsection is a perfectly valid,
authenticated identity with almost no permissions at all until RBAC
grants some.

**Example**: grant `security-demo-sa` read access to Pods only, then
test both an allowed request and a forbidden one with the same token:

```
kubectl apply -f tutorial/examples/security/rbac-role.yaml
kubectl apply -f tutorial/examples/security/rbac-rolebinding.yaml
curl -sS -k -H "Authorization: Bearer $TOKEN" "$APISERVER/api/v1/namespaces/default/pods" -o /dev/null -w '%{http_code}\n'
curl -sS -k -H "Authorization: Bearer $TOKEN" "$APISERVER/apis/apps/v1/namespaces/default/deployments" -o /dev/null -w '%{http_code}\n'
```

**Expected output**: `200` for Pods now that the Role grants it, `403`
for Deployments - same token, same authentication, two different
authorization outcomes because they're different resources in a
different API group entirely:

```
role.rbac.authorization.k8s.io/security-demo-pod-reader created
rolebinding.rbac.authorization.k8s.io/security-demo-pod-reader-binding created
200
```

```
{
  "kind": "Status",
  "status": "Failure",
  "message": "deployments.apps is forbidden: User \"system:serviceaccount:default:security-demo-sa\" cannot list resource \"deployments\" in API group \"apps\" in the namespace \"default\"",
  "reason": "Forbidden",
  "code": 403
}
403
```

The error message names the exact identity, verb, resource, and API
group that was missing - RBAC denials are specific, not a generic
"forbidden."

### Admission control: Pod Security Admission

**Why**: **PodSecurityPolicy was removed entirely in 1.25.** Its stable
replacement, Pod Security Admission (PSA), needs no object at all - just
a label on the namespace (`pod-security.kubernetes.io/enforce=<level>`,
one of `privileged`/`baseline`/`restricted`). Admission is the third
pipeline stage: a request can be fully authenticated and authorized and
still be rejected here, evaluated independently of both. And admission
succeeding is not the same as the Pod actually working - a stock image
built assuming root can pass `restricted` admission (which only checks
the Pod *spec*, not what the image does at runtime) and then crash-loop
immediately, because `restricted` in practice usually means choosing an
image actually built for rootless execution, not just adding a
`securityContext` block to an unmodified one.

**Example**: label a namespace `restricted`, then try a Pod that
violates it outright:

```
kubectl apply -f tutorial/examples/security/restricted-namespace.yaml
kubectl apply -f tutorial/examples/security/admission-denied-pod.yaml
```

**Expected output**: rejected outright - the Pod is never created, and
the error lists every specific requirement it violates, not just "denied":

```
namespace/security-demo-restricted created
Error from server (Forbidden): error when creating "tutorial/examples/security/admission-denied-pod.yaml": pods "security-demo-privileged-pod" is forbidden: violates PodSecurity "restricted:latest": privileged (container "nginx" must not set securityContext.privileged=true), allowPrivilegeEscalation != false (container "nginx" must set securityContext.allowPrivilegeEscalation=false), unrestricted capabilities (container "nginx" must set securityContext.capabilities.drop=["ALL"]), runAsNonRoot != true (pod or container "nginx" must set securityContext.runAsNonRoot=true), seccompProfile (pod or container "nginx" must set securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
```

Now a Pod that satisfies every `restricted` requirement on paper -
`runAsNonRoot`, no privilege escalation, all capabilities dropped,
`RuntimeDefault` seccomp - using the same stock `nginx` image every
prior chapter used unmodified:

```
kubectl apply -f tutorial/examples/security/admission-allowed-crash-pod.yaml
kubectl get pod security-demo-restricted-compliant-pod -n security-demo-restricted
kubectl logs security-demo-restricted-compliant-pod -n security-demo-restricted
```

**Expected output**: admission accepts it - the Pod object gets created,
unlike the privileged one - and then it crash-loops immediately, for a
completely mundane reason: the stock image bakes in root-owned
directories it can no longer write to as UID 1000:

```
pod/security-demo-restricted-compliant-pod created

NAME                                      READY   STATUS   RESTARTS     AGE
security-demo-restricted-compliant-pod   0/1     Error    1 (6s ago)   8s
```

```
2026/08/28 05:38:49 [emerg] 1#1: mkdir() "/var/cache/nginx/client_temp" failed (13: Permission denied)
nginx: [emerg] mkdir() "/var/cache/nginx/client_temp" failed (13: Permission denied)
```

Nothing about this is a `restricted`-policy bug - the Pod spec is fully
compliant, admission did its job correctly. The image just wasn't built
to run as anyone but root, which `restricted` admission has no way to
know or check.

### NetworkPolicy: accepted by the API regardless of whether anything enforces it

**Why**: a `NetworkPolicy` object is validated and stored by the
apiserver exactly like any other object (chapter 2) - the apiserver has
no way to know whether any CNI plugin actually implements
`NetworkPolicy` enforcement, so an unenforced policy isn't rejected or
flagged, it just silently does nothing. **Whether a given CNI enforces
NetworkPolicy at all is not something to take on faith - check it.**
This isn't a hypothetical caution: while verifying this exact chapter,
kindnetd (this repo's `default` profile CNI) turned out to genuinely
enforce `NetworkPolicy`, contradicting this repo's own `DESIGN.md`,
which - accurately, for a long time - documented kindnetd as *not*
enforcing it. kindnetd has since gained an embedded, nftables-based
enforcer (`kube-network-policies`, confirmed via kindnet's own pod logs -
see `docs/findings.md`, 2026-08-28 entry). `DESIGN.md` has been corrected
accordingly. The lesson generalizes past this one CNI: "minimal CNI, no
NetworkPolicy support" is exactly the kind of claim that ages badly
without a live check, which is the whole reason this tutorial insists on
verifying against a real cluster rather than writing from memory.

**Example**: on the `default` profile (kindnetd), deploy a target Pod, a
client that matches the policy's allowed label and one that doesn't,
confirm both can reach the target with no policy present, then apply a
policy that should block the non-matching one:

```
kubectl apply -f tutorial/examples/security/netpol-target-pod.yaml
kubectl apply -f tutorial/examples/security/netpol-client-allowed-pod.yaml
kubectl apply -f tutorial/examples/security/netpol-client-blocked-pod.yaml
TARGET_IP=$(kubectl get pod security-demo-target -o jsonpath='{.status.podIP}')
kubectl exec security-demo-client-blocked -- wget -qO- -T 5 "http://$TARGET_IP" | head -1   # baseline, no policy yet
kubectl apply -f tutorial/examples/security/networkpolicy.yaml
kubectl exec security-demo-client-blocked -- wget -qO- -T 5 "http://$TARGET_IP" | head -1   # after the policy
kubectl exec security-demo-client-allowed -- wget -qO- -T 5 "http://$TARGET_IP" | head -1
kubectl logs -n kube-system <a-kindnet-pod> | grep -i "network-polic"
```

**Expected output (default profile, kindnetd)**: reachable before the
policy, genuinely blocked after it - a real timeout, not an instant
refusal:

```
$ kubectl exec security-demo-client-blocked -- wget -qO- -T 5 "http://$TARGET_IP"   # before
<!DOCTYPE html>...

$ kubectl apply -f tutorial/examples/security/networkpolicy.yaml
networkpolicy.networking.k8s.io/security-demo-netpol created

$ kubectl exec security-demo-client-blocked -- wget -qO- -T 5 "http://$TARGET_IP"   # after
wget: download timed out
command terminated with exit code 1

$ kubectl exec security-demo-client-allowed -- wget -qO- -T 5 "http://$TARGET_IP"   # after, matching Pod
<!DOCTYPE html>...
```

And kindnet's own logs confirm the mechanism, not just the symptom:

```
"Starting controller" name="kube-network-policies"
"Waiting for the policy engine to become ready..."
"Policy engine is ready."
"Syncing nftables rules" logger="nftables-sync"
```

Now the same objects, on `calico` - not because it's the only CNI that
enforces `NetworkPolicy` anymore, but because independently confirming
enforcement on a second, purpose-built CNI is still worth doing rather
than assuming this repo's two profiles behave identically just because
one does:

```
kubectl delete -f tutorial/examples/security/networkpolicy.yaml -f tutorial/examples/security/netpol-target-pod.yaml -f tutorial/examples/security/netpol-client-allowed-pod.yaml -f tutorial/examples/security/netpol-client-blocked-pod.yaml
make down PROFILE=default
make up PROFILE=calico
kubectl apply -f tutorial/examples/security/netpol-target-pod.yaml
kubectl apply -f tutorial/examples/security/netpol-client-allowed-pod.yaml
kubectl apply -f tutorial/examples/security/netpol-client-blocked-pod.yaml
kubectl apply -f tutorial/examples/security/networkpolicy.yaml
TARGET_IP=$(kubectl get pod security-demo-target -o jsonpath='{.status.podIP}')
kubectl exec security-demo-client-allowed -- wget -qO- -T 5 "http://$TARGET_IP" | head -1
kubectl exec security-demo-client-blocked -- wget -qO- -T 5 "http://$TARGET_IP" | head -1
```

**Expected output (calico profile)**: the same real block/allow split as
kindnetd - same policy YAML, independently confirmed on a second CNI:

```
<!DOCTYPE html>...          # allowed client - succeeds

wget: download timed out
command terminated with exit code 1   # blocked client - fails
```

Two different CNIs, two independent NetworkPolicy implementations, the
same observed enforcement - worth having actually run both rather than
assumed either from documentation, given this chapter's own opening
example of what happens when that assumption goes unchecked.

Remember to switch back afterward if you're continuing through the rest
of this tutorial on `default`:

```
make down PROFILE=calico
make up PROFILE=default
```

Every denial this chapter produced on purpose - a forbidden RBAC verb,
a rejected `restricted` Pod, a dropped NetworkPolicy connection - looked
different from an ordinary bug: no crash, no bad config, just a request
that never got where it was going. Chapter 9 is about the general
version of that problem - reading `kubectl describe` events, apiserver
responses, and container logs to figure out *why* something isn't
happening, whether the cause is a security control like these or
something far more mundane.
