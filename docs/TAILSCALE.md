# Tailscale Kubernetes Operator Setup Guide

The Tailscale Operator enables secure, private access to cluster resources via your Tailscale mesh network. It exposes Kubernetes Services to your tailnet without opening public ports.

---

## Prerequisites

Before installing the operator, configure your Tailscale tailnet:

### 1. Create ACL Tags (Required)

In **Tailscale Admin Console** → **ACLs**, add the following tag owners:

```yaml
"tagOwners": {
  "tag:k8s-operator": [],
  "tag:k8s": ["tag:k8s-operator"],
}
```

- `tag:k8s-operator`: Used by the operator itself for authentication
- `tag:k8s`: Default tag for Services exposed via Tailscale (you can create additional tags like `tag:k8s-ingress` for different service types)

### 2. Create OAuth Client

In **Tailscale Admin Console** → **Settings** → **API credentials** → **OAuth**:

1. Click **Create new client**
2. Configure:
   - **Scopes**: Select `Devices Core`, `Auth Keys`, `Services write`
   - **Tags**: Set to `tag:k8s-operator`
3. Click **Create client**
4. **Save your Client ID and Client Secret** - you'll need these

---

## Installation

The operator is installed via a Helm chart managed by Argo CD.

### Configuration File

See `argocd/applications/tailscale-operator.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: tailscale-operator
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://pkgs.tailscale.com/helmcharts
    chart: tailscale-operator
    targetRevision: v1.92.5  # Check for latest version
    helm:
      releaseName: tailscale-operator
      values: |
        replicaCount: 1
        resources:
          limits:
            cpu: 200m
            memory: 256Mi
          requests:
            cpu: 100m
            memory: 128Mi
  destination:
    server: https://kubernetes.default.svc
    namespace: tailscale
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

### OAuth Credentials Storage

The OAuth credentials are stored in an encrypted Kubernetes secret:

**Location**: `argocd/resources/tailscale-secrets/tailscale-oauth-secret.yaml`

**Update credentials**:

```bash
# Edit the encrypted secret (requires Yubikey)
sops argocd/resources/tailscale-secrets/tailscale-oauth-secret.yaml

# Update the client_id and client_secret fields with your OAuth credentials
# Save and exit - SOPS will re-encrypt automatically

# Commit and push
git add . && git commit -m "chore(tailscale): update OAuth credentials"
git push

# Argo CD will auto-sync and restart the operator
```

---

## Exposing Services to Your Tailnet

To expose a Kubernetes Service to your Tailscale network, add the Tailscale annotation:

### Basic Service Exposure

```yaml
apiVersion: v1
kind: Service
metadata:
  name: my-service
  namespace: my-namespace
  annotations:
    tailscale.com/expose: "true"
    tailscale.com/hostname: "my-service"  # Accessible as: my-service.YOUR_TAILNET_NAME
spec:
  type: ClusterIP
  selector:
    app: my-app
  ports:
    - name: http
      port: 80
      targetPort: 8080
      protocol: TCP
```

### Example: Forgejo Git Server

Location: `argocd/resources/forgejo-ingress/forgejo-tailscale-service.yaml`

```yaml
apiVersion: v1
kind: Service
metadata:
  name: forgejo-tailscale
  namespace: forgejo
  annotations:
    tailscale.com/expose: "true"
    tailscale.com/hostname: "forgejo"
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: forgejo
  ports:
    - name: http
      port: 80
      targetPort: 3000
      protocol: TCP
```

**Access**: `http://forgejo.YOUR_TAILNET_NAME` (only accessible from your Tailscale network)

---

## Verification

### Operator Status

Check that the operator is running and has joined your tailnet:

```bash
# View operator pod
kubectl get pods -n tailscale

# Check logs
kubectl logs -n tailscale -l app.kubernetes.io/name=operator --tail=20
```

### Tailnet Verification

In **Tailscale Admin Console** → **Machines**:
- Look for `tailscale-operator` device
- It should be tagged with `tag:k8s-operator`
- Status should show "Connected"

### Service Exposure

Check if your services are being exposed:

```bash
# List exposed services
kubectl get svc -A -o wide | grep -i tailscale

# Verify annotations
kubectl get svc NAMESPACE my-service -o yaml | grep tailscale.com
```

---

## Troubleshooting

### Error: "requested tags [...] are invalid or not permitted"

**Cause**: The ACL tag doesn't exist in your tailnet or the operator doesn't have permission.

**Fix**:

```bash
# 1. Verify tags exist in your Tailscale ACLs
# Go to: Tailscale Admin Console → ACLs
# Ensure tag:k8s-operator and tag:k8s are defined

# 2. Restart the operator to pick up ACL changes
kubectl rollout restart deployment/operator -n tailscale

# 3. Check logs
kubectl logs -n tailscale -l app.kubernetes.io/name=operator --tail=50
```

### Service not accessible via Tailscale

**Cause**: Service annotation missing, pod not running, or operator error.

**Diagnose**:

```bash
# Check operator logs for errors
kubectl logs -n tailscale -l app.kubernetes.io/name=operator | grep -i "error\|failed"

# Verify service has correct annotations
kubectl get svc my-service -n my-namespace -o yaml | grep -A2 "annotations:"

# Check target pod is running
kubectl get pods -n my-namespace -l app=my-app

# Check for any operator errors specific to your service
kubectl logs -n tailscale -l app.kubernetes.io/name=operator | grep "my-service"
```

### Certificate Issues

The operator automatically provisions TLS certificates for Tailscale Ingress services:
- Valid for **90 days**
- Automatic renewal **2/3 through validity period**
- Renewal triggered on next traffic request

If a certificate expires:
```bash
# The next request to the service will trigger automatic renewal
# If renewal fails, restart the proxy:
kubectl rollout restart statefulset/<service-name> -n tailscale
```

### Pod Pending or CrashLoopBackOff

Check operator logs and ensure:
1. Resource requests are available on the node
2. OAuth credentials are valid
3. ACL tags are properly configured

```bash
# Check events
kubectl describe pod -n tailscale <pod-name>

# Check resource usage
kubectl top nodes
kubectl top pods -n tailscale
```

---

## Version Management

### Check Current Version

```bash
grep targetRevision argocd/applications/tailscale-operator.yaml
```

### Check Latest Available Version

```bash
# From Tailscale stable repo
curl -s https://api.github.com/repos/tailscale/tailscale/releases/latest | jq -r '.tag_name'

# Or check the Helm chart
curl -s https://pkgs.tailscale.com/helmcharts/index.yaml | grep 'appVersion' | head -1
```

### Update Operator

1. **Edit the application manifest**:

```bash
vim argocd/applications/tailscale-operator.yaml
# Update: targetRevision: vX.X.X
```

2. **Commit and push**:

```bash
git add . && git commit -m "chore(tailscale): upgrade operator to vX.X.X"
git push
```

3. **Argo CD auto-syncs** within ~3 minutes

---

## Advanced Configuration

### Custom Proxy Groups (for High Availability)

To run multiple replicas of the same proxy (for redundancy during upgrades):

```yaml
apiVersion: tailscale.com/v1alpha1
kind: ProxyGroup
metadata:
  name: ts-proxies
  namespace: tailscale
spec:
  type: egress
  replicas: 3
```

This creates a StatefulSet with 3 replicas, each as a separate tailnet device.

### Custom Hostnames for Services

Services can use custom hostnames instead of the default `service-name.tailnet`:

```yaml
annotations:
  tailscale.com/expose: "true"
  tailscale.com/hostname: "git.internal"  # Custom hostname
```

### Multiple Tags for Services

You can create additional tags for different service types:

```yaml
# In Tailscale ACLs:
"tagOwners": {
  "tag:k8s-operator": [],
  "tag:k8s": ["tag:k8s-operator"],
  "tag:k8s-ingress": ["tag:k8s-operator"],
  "tag:k8s-internal": ["tag:k8s-operator"],
}
```

Then use in service annotations or operator configuration.

---

## References

- **Tailscale Kubernetes Operator**: https://tailscale.com/kb/1236/kubernetes-operator
- **Tailscale ACLs**: https://tailscale.com/kb/1018/acls/
- **MagicDNS**: https://tailscale.com/kb/1081/magicdns/
- **Operator Resource Customization**: https://tailscale.com/kb/1236/kubernetes-operator#customization

---

**Last Updated**: 2026-01-16
