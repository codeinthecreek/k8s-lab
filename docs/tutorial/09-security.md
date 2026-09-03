# 9. Security

Every `kubectl` command and every in-cluster request this tutorial has
run so far went through the same three independent checks: who is this
(authentication - bearer tokens are one mechanism, not the only one),
are they allowed to do this specific thing (authorization), and does
this specific request get accepted as-is or modified/rejected
(admission control) - each stage entirely independent of the others, so
success at one says nothing about the next. This chapter covers
identity (ServiceAccounts and x509 client certificates), the
authorization layer (RBAC, namespaced and cluster-scoped), the
admission layer (Pod Security Admission and the admission-plugin flags
behind it), and NetworkPolicy - which depends on chapter 5's networking
model and needs its own CNI-enforcement caveat front and center.

### ServiceAccounts: identity for talking to the API

**Why**: every Pod runs as some identity when it talks to the API server
- by default, the `default` ServiceAccount in its namespace, used
implicitly and invisibly in every earlier chapter's Pods. Since
**1.24**, a ServiceAccount no longer gets an auto-generated long-lived
token Secret the moment it's created - `kubectl create token
<sa-name>` mints a short-lived JWT (JSON Web Token) on demand (default
~1h TTL) via the
TokenRequest API instead. Material written assuming "just `kubectl get
secret` to find the SA's token" predates this and no longer works that
way.

**Example**: create a ServiceAccount, mint a token for it, and use that
token directly against the API server - the same "kubectl is just an
HTTPS client" fact chapter 2's `-v=8` tracing made visible, now proven
by using `curl` instead of `kubectl` with a non-`kubectl` identity:

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

Both objects above were namespaced - the `Role` only exists inside
`default`, and the `RoleBinding` binding it to `security-demo-sa` lives
there too. The next subsection covers the cluster-scoped half of RBAC:
`ClusterRole` and `ClusterRoleBinding`.

### ClusterRole and ClusterRoleBinding: cluster-scoped rules, binding-scoped effect

**Why**: a `Role` only exists inside one namespace - there's no way to
write a single `Role` that grants a permission across every namespace.
A `ClusterRole` is the same rule syntax with no namespace of its own,
which makes it usable two different ways depending on what binds it: a
`ClusterRoleBinding` grants its rules everywhere, cluster-wide, while an
ordinary namespaced `RoleBinding` can *also* reference a `ClusterRole`
as its `roleRef` - and when it does, the grant is scoped down to just
that one namespace, exactly like binding a `Role` would be. This is the
standard way built-in ClusterRoles like `view`/`edit`/`admin` get reused
per-namespace without writing the same rules out as a `Role` in every
namespace that needs them.

This cluster's own kubeadm-generated admin identity is a live example of
the cluster-wide side of this, worth looking at before writing a new
one:

```
kubectl get clusterrolebinding kubeadm:cluster-admins -o yaml
```

**Expected output** (on this cluster, kubeadm/Kubernetes v1.36.1):

```
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: kubeadm:cluster-admins
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
- apiGroup: rbac.authorization.k8s.io
  kind: Group
  name: kubeadm:cluster-admins
```

A plain `ClusterRoleBinding`, granting the built-in `cluster-admin`
`ClusterRole` to a `Group` subject, exactly like any other RBAC grant in
this chapter - nothing about it is magic. (There's a second,
older-style `ClusterRoleBinding` alongside it, `cluster-admin` bound to
the `system:masters` group, which the next subsection comes back to.)

**Example**: grant `security-demo-sa` a *new* permission - reading
ConfigMaps - using a `ClusterRole`, but bind it with a namespaced
`RoleBinding` instead of a `ClusterRoleBinding`, then check the same
identity against two different namespaces:

```
kubectl apply -f tutorial/examples/security/clusterrole-other-ns.yaml
kubectl apply -f tutorial/examples/security/clusterrole-cm-reader.yaml
kubectl apply -f tutorial/examples/security/clusterrole-rolebinding.yaml
curl -sS -k -H "Authorization: Bearer $TOKEN" "$APISERVER/api/v1/namespaces/default/configmaps" -o /dev/null -w '%{http_code}\n'
curl -sS -k -H "Authorization: Bearer $TOKEN" "$APISERVER/api/v1/namespaces/security-demo-clusterrole-other/configmaps" -o /dev/null -w '%{http_code}\n'
```

**Expected output**: `200` in `default`, where the `RoleBinding` lives,
`403` in the other namespace - the exact same `ClusterRole`, the exact
same identity, but the grant doesn't follow the identity cluster-wide
because it was bound with a `RoleBinding`, not a `ClusterRoleBinding`:

```
namespace/security-demo-clusterrole-other created
clusterrole.rbac.authorization.k8s.io/security-demo-cm-reader created
rolebinding.rbac.authorization.k8s.io/security-demo-cm-reader-binding created
200
403
```

A `ClusterRoleBinding` referencing this same `security-demo-cm-reader`
`ClusterRole` would have returned `200` for both namespaces - the rules
are identical either way, only the binding decides the blast radius.

### x509 client-certificate authentication: the identity behind every `kubectl` command so far

**Why**: the bearer token earlier in this chapter was one authentication
mechanism, deliberately swapped in with `curl` to make it visible. Every
plain `kubectl` command run in this entire tutorial has been
authenticating a completely different way the whole time, via the
`client-certificate-data`/`client-key-data` fields already sitting in
`~/.kube/config`. The apiserver's authenticator reads two fields off
that client certificate's subject and turns them directly into an
identity: the Subject **CN** becomes the username, and every Subject
**O** becomes a group membership - no lookup against any user database,
because there isn't one. This is also exactly what the previous
subsection's `kubeadm:cluster-admins` `ClusterRoleBinding` was waiting
for: a `Group` subject named `kubeadm:cluster-admins` only means
something because some certificate somewhere carries `O=kubeadm:cluster-admins`
in its subject.

**Example**: decode this cluster's own admin client certificate out of
the current kubeconfig and read its subject directly:

```
kubectl config view --raw -o jsonpath='{.users[0].user.client-certificate-data}' | base64 -d | openssl x509 -noout -subject -issuer
```

**Expected output** (on this cluster, kubeadm/Kubernetes v1.36.1):

```
subject=O=kubeadm:cluster-admins, CN=kubernetes-admin
issuer=CN=kubernetes
```

`CN=kubernetes-admin` is the username every prior chapter's `kubectl`
commands have been running as, and `O=kubeadm:cluster-admins` is the
group the earlier `ClusterRoleBinding` grants `cluster-admin` to - two
fields in a certificate subject, mapped straight into the RBAC model
this chapter has been building up. (Older kubeadm versions put this
same admin cert's `O` in the hardcoded `system:masters` group instead -
this cluster's second `cluster-admin` `ClusterRoleBinding`, seen in the
previous subsection's output, is that older path kept around
separately, not replaced.)

**Why the CA key matters**: `issuer=CN=kubernetes` names the cluster CA
that signed this cert - and that CA's *private* key (`ca.key` on the
control-plane node, never distributed to clients) is the actual root of
trust for every identity claim above. Anyone holding it can mint a new
client cert with any CN and any O they choose - `CN=attacker,
O=kubeadm:cluster-admins` would be accepted exactly as readily as the
real admin cert, because the apiserver has no way to distinguish
"legitimately issued" from "correctly signed by the CA it trusts." RBAC
decides what an identity can do; the CA key decides who gets to *become*
an identity at all, which is why guarding it matters more than any
individual RBAC grant in this chapter.

### Curling the API with a client certificate, the x509 counterpart to the bearer-token example

**Why**: the ServiceAccount subsection proved `kubectl` is just an HTTPS
client by swapping in a bearer token; the same trick works for x509 -
extract the three PEM values kubeconfig already carries
(`client-certificate-data`, `client-key-data`,
`certificate-authority-data`) and hand them to `curl` directly, no
`kubectl` or its credential-loading machinery involved at all.

**Example**: decode all three fields to files, then use them with
`curl --cert`/`--key`/`--cacert` in place of `-k` and a bearer token:

```
kubectl config view --raw -o jsonpath='{.users[0].user.client-certificate-data}' | base64 -d > /tmp/admin.crt
kubectl config view --raw -o jsonpath='{.users[0].user.client-key-data}' | base64 -d > /tmp/admin.key
kubectl config view --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d > /tmp/ca.crt
curl -sS --cert /tmp/admin.crt --key /tmp/admin.key --cacert /tmp/ca.crt "$APISERVER/api/v1/namespaces/default/pods" -o /dev/null -w '%{http_code}\n'
```

**Expected output**: `200` - a real, working request against the live
API server, authenticated entirely by the certificate's signature and
subject fields, with no bearer token and no `-k` skip-verification flag
needed since `--cacert` gives `curl` the actual cluster CA to validate
against:

```
200
```

### `kubectl proxy`: the same URL, a different auth path entirely

**Why**: every direct `curl` example in this chapter has required
manually solving two separate problems at once - proving identity
(`-H "Authorization: Bearer ..."` or `--cert`/`--key`) and establishing
TLS trust (`-k` to skip it, or `--cacert` to do it properly).
`kubectl proxy` collapses both into kubectl's own already-configured
kubeconfig: it opens a local, unauthenticated HTTP endpoint and forwards
every request to the real apiserver using whatever identity and TLS
trust `kubectl` itself already has configured. That makes it a
deliberately blunt diagnostic tool - if a direct `curl` against the API
is failing and it's unclear whether that's a TLS/connectivity problem or
an RBAC problem, routing the same request through `kubectl proxy`
instead answers the question: connectivity is no longer in play at all,
so anything that still fails there is genuinely RBAC, and anything that
now succeeds was never an RBAC problem in the first place.

**Example**: first, a direct `curl` against the real apiserver URL with
no cert flags and no `-k` - the kind of mistake that looks like the API
is unreachable:

```
curl -sS "$APISERVER/api/v1/namespaces/default/pods" -o /dev/null -w '%{http_code}\n'
```

**Expected output**: not an HTTP status code at all - `curl` refuses to
even complete the TLS handshake, because the apiserver's certificate is
signed by this cluster's own CA, which isn't in `curl`'s default trust
store:

```
curl: (60) SSL certificate OpenSSL verify result: unable to get local issuer certificate (20)
000
```

Now the same resource, through `kubectl proxy`, impersonating the
low-privilege `security-demo-sa` identity from earlier in this chapter
so the RBAC boundary stays visible instead of masked by admin
permissions:

```
kubectl proxy --as=system:serviceaccount:default:security-demo-sa --port=8765 &
curl -sS "http://127.0.0.1:8765/api/v1/namespaces/default/pods" -o /dev/null -w '%{http_code}\n'
curl -sS "http://127.0.0.1:8765/apis/apps/v1/namespaces/default/deployments" -o /dev/null -w '%{http_code}\n'
kill %1
```

**Expected output**: `200` for Pods - proving the connectivity failure
above was never about the API being unreachable, only about the direct
`curl` invocation's own missing TLS trust - and `403` for Deployments,
the exact same RBAC boundary from the ServiceAccount/RBAC subsections
earlier, now unambiguous because `kubectl proxy` already solved
connectivity:

```
Starting to serve on 127.0.0.1:8765
200
403
```

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

### Aside: admission-plugin flags only show additions to a compiled-in default set

PSA is one admission plugin among many, and it's already enabled by
default - nothing in the example above turned it on. `kube-apiserver`'s
`--enable-admission-plugins` flag doesn't take a full replacement list;
its own `--help` text says so explicitly: "admission plugins that should
be enabled **in addition to** default enabled ones." This cluster's own
static-pod manifest only sets `--enable-admission-plugins=NodeRestriction`
- everything else PSA relies on (`PodSecurity` itself, `ServiceAccount`,
`LimitRanger`, and a dozen more) is already running, compiled in, before
that flag is even evaluated:

```
docker exec k8s-lab-default-control-plane cat /etc/kubernetes/manifests/kube-apiserver.yaml | grep admission-plugins
```

```
    - --enable-admission-plugins=NodeRestriction
```

**A caution on where `--help` is actually reachable**: `kube-apiserver`
doesn't run as a process on the kind node's own root filesystem - it's
a separate static-pod container, so `docker exec` into the node
container itself can't find the binary at all:

```
docker exec k8s-lab-default-control-plane which kube-apiserver
```

produces no output - nothing is on `$PATH` there. Reaching `--help`
means going through the pod, not the node:

```
kubectl exec -n kube-system kube-apiserver-k8s-lab-default-control-plane -- kube-apiserver --help 2>&1 | grep -A1 "^\s*--enable-admission-plugins"
```

```
      --enable-admission-plugins strings             admission plugins that should be enabled in addition to default enabled ones (NamespaceLifecycle, LimitRanger, ServiceAccount, TaintNodesByCondition, PodSecurity, Priority, DefaultTolerationSeconds, DefaultStorageClass, StorageObjectInUseProtection, PodGroupProtection, PersistentVolumeClaimResize, RuntimeClass, CertificateApproval, CertificateSigning, ClusterTrustBundleAttest, CertificateSubjectRestriction, DefaultIngressClass, PodTopologyLabels, PodGroupWorkloadExists, NodeDeclaredFeatureValidator, JobValidation, PodResizeValidator, MutatingAdmissionPolicy, MutatingAdmissionWebhook, ValidatingAdmissionPolicy, ValidatingAdmissionWebhook, ResourceQuota). ...
```

`kubectl exec` reaches it because the binary lives inside the
apiserver's own container image, not on the node's filesystem -
`docker exec` into the node and `kubectl exec` into the pod are
answering fundamentally different "where does this run" questions, and
only one of them lands inside the container that actually has
`kube-apiserver` on its `$PATH`.

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
one does.

**Heads-up**: the block below tears down and rebuilds the cluster
(`default` -> `calico` -> back), which takes roughly 10 minutes round-trip
- mostly `calico`'s own `kind create cluster --wait 5m` genuinely
spending the full 5 minutes, since that profile disables kindnetd
entirely (`disableDefaultCNI: true`) and nodes can't report `Ready`
until Calico's manifest is applied afterward; skim to **Expected output
(calico profile)** below to see the result without running it yourself:

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
