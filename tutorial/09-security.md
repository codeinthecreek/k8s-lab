# 9. Security

Every request to the API server, from `kubectl` or from inside the
cluster, passes three checks in turn:

1. **Authentication**: who is making the request?
2. **Authorization**: is that identity allowed to do this?
3. **Admission control**: is this particular request acceptable as it
   stands, or should it be changed or rejected?

The three are independent. Passing one says nothing about the next. This
chapter takes them in order, starting with identities (ServiceAccounts,
then client certificates), then authorization with RBAC, then admission
with Pod Security Admission. It ends with NetworkPolicy, which isn't
part of the API's checks at all: it controls traffic between Pods, and
depends on the networking from chapter 5.

### ServiceAccounts: identity for talking to the API

**Why**: a program running in a Pod that talks to the API server needs
an identity, just as you do. That identity is a **ServiceAccount**. Every
namespace has one called `default`, and every Pod in earlier chapters
used it without you noticing.

A ServiceAccount proves who it is with a token. Since Kubernetes
**1.24**, creating a ServiceAccount no longer creates a long-lived token
stored in a Secret. Instead, `kubectl create token <name>` asks the API
server for a short-lived token (a JWT, JSON Web Token, valid for about
an hour by default). Older material that says to find a ServiceAccount's
token with `kubectl get secret` describes the behaviour before 1.24.

**Example**: create a ServiceAccount, get a token for it, and use the
token with `curl` instead of `kubectl`. Chapter 2 showed with `-v=8` that
`kubectl` is just an HTTPS client of the API server; here a different
client, with a different identity, makes the same kind of request:

```
kubectl apply -f tutorial/examples/security/serviceaccount.yaml
kubectl get secrets | grep security-demo-sa
TOKEN=$(kubectl create token security-demo-sa)
APISERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
curl -sS -k -H "Authorization: Bearer $TOKEN" "$APISERVER/api/v1/namespaces/default/pods" -o /dev/null -w '%{http_code}\n'
```

**Expected output**: there's no Secret for the ServiceAccount (there are
no Secrets in `default` at all, so `kubectl` says so), and the API
server accepts the token:

```
serviceaccount/security-demo-sa created
No resources found in default namespace.
403
```

The answer is `403 Forbidden`, not `401 Unauthorized`. A `401` would mean
the API server didn't know who was asking. A `403` means it did: the
token worked, so authentication succeeded. The ServiceAccount just
isn't allowed to list Pods yet, because nothing has given it any
permissions. That's authorization, the next section.

### RBAC: what an identity may do

**Why**: **RBAC** (role-based access control) is how Kubernetes decides
what an identity may do. A **Role** lists permissions: which verbs
(`get`, `list`, `create`, ...) on which resources. A **RoleBinding**
gives a Role's permissions to one or more identities.

RBAC only grants. There are no "deny" rules. An identity can do exactly
what the Roles bound to it allow, all of them added together, and
nothing else.

Each permission names a resource in a specific API group. A Role that
allows `pods` (in the core group) allows nothing on `deployments`
(in the `apps` group), even though you might think of both as
"workloads".

**Example**: let `security-demo-sa` read Pods, and nothing else. Then
use the same token for a request it's allowed to make and one it isn't:

```
kubectl apply -f tutorial/examples/security/rbac-role.yaml
kubectl apply -f tutorial/examples/security/rbac-rolebinding.yaml
curl -sS -k -H "Authorization: Bearer $TOKEN" "$APISERVER/api/v1/namespaces/default/pods" -o /dev/null -w '%{http_code}\n'
curl -sS -k -H "Authorization: Bearer $TOKEN" "$APISERVER/apis/apps/v1/namespaces/default/deployments"
```

**Expected output**: `200` for Pods, which the Role now allows. The
second `curl` prints the whole response instead of just the status
code, so you can see the error for Deployments. It's the same token
both times; only the resource is different:

```
role.rbac.authorization.k8s.io/security-demo-pod-reader created
rolebinding.rbac.authorization.k8s.io/security-demo-pod-reader-binding created
200
```

```
{
  "kind": "Status",
  "apiVersion": "v1",
  "metadata": {},
  "status": "Failure",
  "message": "deployments.apps is forbidden: User \"system:serviceaccount:default:security-demo-sa\" cannot list resource \"deployments\" in API group \"apps\" in the namespace \"default\"",
  "reason": "Forbidden",
  "details": {
    "group": "apps",
    "kind": "deployments"
  },
  "code": 403
}
```

The error says exactly what was missing: which identity, which verb,
which resource, in which API group and namespace.

A Role and a RoleBinding both belong to a namespace, here `default`, and
only grant permissions there. The next section covers the cluster-wide
versions.

### ClusterRole and ClusterRoleBinding

**Why**: a Role belongs to one namespace, so it can't grant anything in
other namespaces. A **ClusterRole** has the same kind of rules but
doesn't belong to any namespace. What it grants depends on how it's
bound:

- A **ClusterRoleBinding** grants the ClusterRole's permissions in every
  namespace.
- A RoleBinding can also point at a ClusterRole. Then the permissions
  apply only in the RoleBinding's own namespace, as if it were a Role.

The second way lets you define a set of permissions once and grant it
namespace by namespace. Kubernetes's built-in ClusterRoles `view`,
`edit` and `admin` are used like that.

You've been using a ClusterRoleBinding all along. Here is the one
kubeadm created for the cluster's admin:

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

It's an ordinary ClusterRoleBinding. It gives the built-in
`cluster-admin` ClusterRole, which allows everything, to the group
`kubeadm:cluster-admins`. The section on client certificates below shows
who is in that group. There's also an older ClusterRoleBinding called
`cluster-admin`, which gives the same ClusterRole to the group
`system:masters`.

**Example**: give `security-demo-sa` one more permission, reading
ConfigMaps, through a ClusterRole, but bind it with a RoleBinding in
`default`. Then try reading ConfigMaps in `default` and in another
namespace:

```
kubectl apply -f tutorial/examples/security/clusterrole-other-ns.yaml
kubectl apply -f tutorial/examples/security/clusterrole-cm-reader.yaml
kubectl apply -f tutorial/examples/security/clusterrole-rolebinding.yaml
curl -sS -k -H "Authorization: Bearer $TOKEN" "$APISERVER/api/v1/namespaces/default/configmaps" -o /dev/null -w '%{http_code}\n'
curl -sS -k -H "Authorization: Bearer $TOKEN" "$APISERVER/api/v1/namespaces/security-demo-clusterrole-other/configmaps" -o /dev/null -w '%{http_code}\n'
```

**Expected output**: `200` in `default`, where the RoleBinding is, and
`403` in the other namespace:

```
namespace/security-demo-clusterrole-other created
clusterrole.rbac.authorization.k8s.io/security-demo-cm-reader created
rolebinding.rbac.authorization.k8s.io/security-demo-cm-reader-binding created
200
403
```

With a ClusterRoleBinding to the same ClusterRole, both requests would
have returned `200`. The rules are the same either way; the binding
decides where they apply.

### Client certificates: the identity behind your `kubectl` commands

**Why**: a ServiceAccount token is one way to authenticate. Your own
`kubectl` commands have used another all along: a **client
certificate**, stored in `~/.kube/config` as `client-certificate-data`
and `client-key-data`.

Kubernetes has no database of users. When a request arrives with a
client certificate, the API server takes the identity straight from the
certificate's subject: the **CN** (common name) becomes the user name,
and each **O** (organization) becomes a group the user belongs to. So
the ClusterRoleBinding in the previous section, which grants
`cluster-admin` to the group `kubeadm:cluster-admins`, applies to anyone
whose certificate says `O=kubeadm:cluster-admins`.

**Example**: decode the admin certificate from your kubeconfig and show
its subject and issuer. `--minify` limits the output to the current
context, so `users[0]` is the user for this cluster even if your
kubeconfig has others:

```
kubectl config view --minify --raw -o jsonpath='{.users[0].user.client-certificate-data}' | base64 -d | openssl x509 -noout -subject -issuer
```

**Expected output** (on this cluster, kubeadm/Kubernetes v1.36.1):

```
subject=O=kubeadm:cluster-admins, CN=kubernetes-admin
issuer=CN=kubernetes
```

You've been running every `kubectl` command as the user
`kubernetes-admin`, in the group `kubeadm:cluster-admins`, which is why
you could do anything. (Older kubeadm versions put the admin certificate
in the group `system:masters` instead. That's what the older
`cluster-admin` ClusterRoleBinding is for.)

**Why the CA key matters**: the issuer, `CN=kubernetes`, is the
cluster's certificate authority (CA). The API server accepts any client
certificate the CA has signed. The CA's private key (`ca.key`, kept on
the control-plane node) is therefore what really controls who can
become who. Anyone who has it can sign a certificate with any name and
any group, for example `CN=attacker, O=kubeadm:cluster-admins`, and the
API server will accept it just like the real admin certificate. RBAC
decides what an identity can do; the CA key decides who can claim an
identity in the first place. Protecting it matters more than any single
RBAC rule.

### Using a client certificate with curl

**Why**: you can use the client certificate with `curl` too, the same
way you used the token. Your kubeconfig holds everything needed: the
certificate, its key, and the cluster's CA certificate
(`certificate-authority-data`), which lets `curl` check that it's
talking to the real API server.

**Example**: decode the three values to files, then pass them to `curl`
with `--cert`, `--key` and `--cacert`:

```
kubectl config view --minify --raw -o jsonpath='{.users[0].user.client-certificate-data}' | base64 -d > /tmp/admin.crt
kubectl config view --minify --raw -o jsonpath='{.users[0].user.client-key-data}' | base64 -d > /tmp/admin.key
kubectl config view --minify --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d > /tmp/ca.crt
curl -sS --cert /tmp/admin.crt --key /tmp/admin.key --cacert /tmp/ca.crt "$APISERVER/api/v1/namespaces/default/pods" -o /dev/null -w '%{http_code}\n'
```

**Expected output**: `200`. The certificate identified you as the admin.
And because `--cacert` told `curl` which CA to trust, it could check the
API server's certificate, so `-k` (skip the check) wasn't needed:

```
200
```

`/tmp/admin.key` is the cluster admin's private key. Delete the three
files when you're done with them:

```
rm /tmp/admin.crt /tmp/admin.key /tmp/ca.crt
```

### `kubectl proxy`: letting kubectl handle identity and TLS

**Why**: every `curl` so far had to handle two things: proving who you
are (a token, or `--cert` and `--key`), and trusting the API server's
certificate (`-k`, or `--cacert`). `kubectl proxy` handles both for you.
It listens on a local port, without TLS or authentication, and forwards
each request to the API server using your kubeconfig's identity and CA.

That makes it useful for troubleshooting. If a `curl` to the API server
fails and you can't tell whether the problem is the connection or
permissions, send the same request through `kubectl proxy`. The
connection is then taken care of, so if it still fails, the problem is
permissions.

**Example**: first, `curl` straight to the API server with no
certificate options and no `-k`. It looks as if the API server can't be
reached:

```
curl -sS "$APISERVER/api/v1/namespaces/default/pods" -o /dev/null -w '%{http_code}\n'
```

**Expected output**: no HTTP status at all (`000`). `curl` stops during
the TLS handshake, because the API server's certificate is signed by
the cluster's own CA, which `curl` doesn't know about:

```
curl: (60) SSL certificate OpenSSL verify result: unable to get local issuer certificate (20)
More details here: https://curl.se/docs/sslcerts.html

curl failed to verify the legitimacy of the server and therefore could not
establish a secure connection to it. To learn more about this situation and
how to fix it, please visit the webpage mentioned above.
000
```

Now the same requests through `kubectl proxy`. `--as` makes the proxy
act as `security-demo-sa` rather than as you, the admin, so RBAC still
limits what it can do:

```
kubectl proxy --as=system:serviceaccount:default:security-demo-sa --port=8765 &
curl -sS "http://127.0.0.1:8765/api/v1/namespaces/default/pods" -o /dev/null -w '%{http_code}\n'
curl -sS "http://127.0.0.1:8765/apis/apps/v1/namespaces/default/deployments" -o /dev/null -w '%{http_code}\n'
kill %1
```

**Expected output**: `200` for Pods, so the API server was reachable all
along; the earlier failure was only `curl` not trusting its
certificate. `403` for Deployments is the same RBAC limit as before:

```
Starting to serve on 127.0.0.1:8765
200
403
```

### Admission control: Pod Security Admission

**Why**: admission is the third check. A request can come from a known
identity, be allowed by RBAC, and still be rejected here.

One of the checks at this stage is **Pod Security Admission** (PSA). It
compares each new Pod against one of three predefined levels:
`privileged` (anything goes), `baseline` (blocks the most dangerous
settings) and `restricted` (requires a locked-down Pod: not running as
root, no extra Linux capabilities, and so on). You choose the level for
a namespace with a label, `pod-security.kubernetes.io/enforce=<level>`;
there's no separate object to create. PSA replaced PodSecurityPolicy,
which was removed in Kubernetes **1.25**.

PSA only looks at the Pod's spec. It can't know what the container
image does once it runs. So a Pod can pass `restricted` and still fail
to start, because the image expects to run as root. In practice, using
`restricted` usually means using images built to run as a non-root user,
not just adding a `securityContext` to an existing Pod.

**Example**: label a namespace `restricted`, then try to create a
privileged Pod in it:

```
kubectl apply -f tutorial/examples/security/restricted-namespace.yaml
kubectl apply -f tutorial/examples/security/admission-denied-pod.yaml
```

**Expected output**: the Pod is rejected and never created. The error
lists every rule it breaks:

```
namespace/security-demo-restricted created
Error from server (Forbidden): error when creating "tutorial/examples/security/admission-denied-pod.yaml": pods "security-demo-privileged-pod" is forbidden: violates PodSecurity "restricted:latest": privileged (container "nginx" must not set securityContext.privileged=true), allowPrivilegeEscalation != false (container "nginx" must set securityContext.allowPrivilegeEscalation=false), unrestricted capabilities (container "nginx" must set securityContext.capabilities.drop=["ALL"]), runAsNonRoot != true (pod or container "nginx" must set securityContext.runAsNonRoot=true), seccompProfile (pod or container "nginx" must set securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
```

Now a Pod that follows every `restricted` rule: it runs as user 1000,
can't gain privileges, drops all capabilities and uses the default
seccomp profile. It uses the same `nginx` image as earlier chapters:

```
kubectl apply -f tutorial/examples/security/admission-allowed-crash-pod.yaml
```

```
pod/security-demo-restricted-compliant-pod created
```

This time the Pod is created. Give it a minute (longer if `nginx:1.27`
still has to be pulled), then look at it and at the end of its log:

```
kubectl get pod security-demo-restricted-compliant-pod -n security-demo-restricted
kubectl logs security-demo-restricted-compliant-pod -n security-demo-restricted --tail=2
```

**Expected output**: the Pod keeps crashing. The `nginx` image needs to
create directories that only root can write to, and it's running as
user 1000:

```
NAME                                     READY   STATUS   RESTARTS      AGE
security-demo-restricted-compliant-pod   0/1     Error    2 (18s ago)   91s
2026/11/19 11:06:30 [emerg] 1#1: mkdir() "/var/cache/nginx/client_temp" failed (13: Permission denied)
nginx: [emerg] mkdir() "/var/cache/nginx/client_temp" failed (13: Permission denied)
```

Admission did its job: the Pod spec follows the rules. The image just
wasn't built to run as anyone but root, and admission can't check that.

### Aside: which admission plugins are running?

PSA is one of many **admission plugins** built into the API server. You
didn't have to turn it on. The API server's `--enable-admission-plugins`
flag only lists plugins to enable *in addition to* the default ones, so
it doesn't tell you everything that's running. On this cluster, it lists
only one:

```
docker exec k8s-lab-default-control-plane cat /etc/kubernetes/manifests/kube-apiserver.yaml | grep admission-plugins
```

```
    - --enable-admission-plugins=NodeRestriction
```

To see the default list, ask `kube-apiserver --help`. The binary isn't on
the node itself. The API server runs in its own container, so looking
for it on the node finds nothing:

```
docker exec k8s-lab-default-control-plane which kube-apiserver
```

prints nothing. Run it inside the API server's Pod instead:

```
kubectl exec -n kube-system kube-apiserver-k8s-lab-default-control-plane -- kube-apiserver --help 2>&1 | grep -A1 "^\s*--enable-admission-plugins"
```

```
      --enable-admission-plugins strings             admission plugins that should be enabled in addition to default enabled ones (NamespaceLifecycle, LimitRanger, ServiceAccount, TaintNodesByCondition, PodSecurity, Priority, DefaultTolerationSeconds, DefaultStorageClass, StorageObjectInUseProtection, PodGroupProtection, PersistentVolumeClaimResize, RuntimeClass, CertificateApproval, CertificateSigning, ClusterTrustBundleAttest, CertificateSubjectRestriction, DefaultIngressClass, PodTopologyLabels, PodGroupWorkloadExists, NodeDeclaredFeatureValidator, JobValidation, PodResizeValidator, MutatingAdmissionPolicy, MutatingAdmissionWebhook, ValidatingAdmissionPolicy, ValidatingAdmissionWebhook, ResourceQuota). ...
```

`PodSecurity` is in the default list, along with `ServiceAccount`,
`LimitRanger`, `ResourceQuota` and many others. `docker exec` runs a
command on the node; `kubectl exec` runs it inside a container in a Pod.
Here, only the container has `kube-apiserver`.

### NetworkPolicy: controlling traffic between Pods

**Why**: by default, any Pod can connect to any other Pod. A
**NetworkPolicy** limits that: it selects some Pods and says which other
Pods may connect to them.

The API server stores a NetworkPolicy like any other object, but it
doesn't enforce it. The network plugin (CNI, chapter 5) does, if it
supports NetworkPolicy at all. If it doesn't, the policy is accepted
without any error or warning and has no effect. So don't assume either
way: test it.

This repo learned that the hard way. Its documentation used to say that
kindnetd, the CNI in the `default` profile, doesn't enforce
NetworkPolicy. Testing this chapter showed that it now does, with a
built-in enforcer called `kube-network-policies` (see
`docs/findings.md`, 2026-08-28).

**Example**: on the `default` profile, create a target Pod (nginx) and
two client Pods (busybox). The policy will allow one client, labelled
`role: frontend`, and not the other, labelled `role: other`:

```
kubectl apply -f tutorial/examples/security/netpol-target-pod.yaml
kubectl apply -f tutorial/examples/security/netpol-client-allowed-pod.yaml
kubectl apply -f tutorial/examples/security/netpol-client-blocked-pod.yaml
```

When all three are `Running` (`kubectl get pods`), check that the
second client can reach the target while there's no policy yet.
`head -1` keeps just the first line of nginx's welcome page:

```
TARGET_IP=$(kubectl get pod security-demo-target -o jsonpath='{.status.podIP}')
kubectl exec security-demo-client-blocked -- wget -qO- -T 5 "http://$TARGET_IP" | head -1
```

```
<!DOCTYPE html>
```

Now apply the policy and try both clients:

```
kubectl apply -f tutorial/examples/security/networkpolicy.yaml
kubectl exec security-demo-client-blocked -- wget -qO- -T 5 "http://$TARGET_IP" | head -1
kubectl exec security-demo-client-allowed -- wget -qO- -T 5 "http://$TARGET_IP" | head -1
```

**Expected output (default profile, kindnetd)**: the `role: other`
client is blocked and the `role: frontend` client still gets the page.
The blocked request times out after 5 seconds (`-T 5`) rather than
being refused, because its packets are dropped:

```
networkpolicy.networking.k8s.io/security-demo-netpol created
wget: download timed out
command terminated with exit code 1
<!DOCTYPE html>
```

kindnet's logs show the enforcer starting. `kubectl logs` on a
DaemonSet picks one of its Pods and says which:

```
kubectl logs -n kube-system daemonset/kindnet | grep -iE "kube-network-policies|policy engine|nftables"
```

```
Found 3 pods, using pod/kindnet-jspwg
I1119 11:04:21.862342       1 controller.go:173] "Starting controller" name="kube-network-policies"
I1119 11:04:21.862355       1 controller.go:178] "Waiting for the policy engine to become ready..."
I1119 11:04:22.362472       1 controller.go:185] "Policy engine is ready."
I1119 11:04:22.362577       1 controller.go:462] "Syncing nftables rules" logger="nftables-sync"
I1119 11:04:22.365643       1 controller.go:465] "Syncing nftables rules" logger="nftables-sync" elapsed="3.037843ms"
```

The `calico` profile uses Calico, a CNI built with NetworkPolicy in
mind. The same policy works there too, through a completely separate
implementation.

**Heads-up**: trying it means replacing the `default` cluster with a
`calico` one and back again, about 10 minutes in total. Most of that is
`make up PROFILE=calico`: the nodes can't become `Ready` until Calico is
installed, which happens after cluster creation, so `kind create
cluster` waits out its full 5-minute timeout. The expected output is
below if you'd rather not run it:

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

**Expected output (calico profile)**: the same result as with kindnetd.
The allowed client gets the page; the other one times out:

```
<!DOCTYPE html>
wget: download timed out
command terminated with exit code 1
```

To continue with the rest of the tutorial on `default`, switch back:

```
make down PROFILE=calico
make up PROFILE=default
```
