# Configuration Reference

Detailed configuration guide for Ironclad infrastructure components.

---

## Table of Contents

1. [Terraform Configuration](#terraform-configuration)
2. [Forgejo Configuration](#forgejo-configuration)
3. [Forgejo Runners Configuration](#forgejo-runners-configuration)
4. [Backup Configuration](#backup-configuration)
5. [Tailscale Configuration](#tailscale-configuration)
6. [Argo CD Configuration](#argo-cd-configuration)

---

## Terraform Configuration

### File: `infra/kube.tfvars`

All infrastructure parameters:

```hcl
# Required
hcloud_token = "YOUR_API_TOKEN"

# Cluster naming
cluster_name = "ironclad-forge"

# Kubernetes version (default: 1.30)
kubernetes_version = "1.30"

# Control plane nodes
control_plane_count = 1              # 1 for single-node, 3+ for HA
control_plane_server_type = "cpx21"  # See server type reference below

# Worker nodes (empty for single-node)
agent_node_pools = []

# Operating system (auto-updates)
image = "openSUSE MicroOS"

# Load balancer (disable if using Tailscale)
enable_klipper_metal_lb = false

# Allow pods on control plane (required for single-node)
allow_scheduling_on_control_plane = true

# Metrics collection
enable_metrics_server = true

# Firewall
firewall_enabled = true

# Output kubeconfig location
kubeconfig_output_path = "~/.kube"
```

### Server Type Reference

**Cost-effective options for Hetzner Cloud:**

| Type | vCPU | RAM | SSD | Cost/mo | Best For |
|------|------|-----|-----|---------|----------|
| cpx11 | 2 | 2 GB | 40 GB | €5 | Testing only |
| cpx21 | 3 | 4 GB | 80 GB | €9 | **Single-node (recommended)** |
| cpx31 | 4 | 8 GB | 160 GB | €17 | Small HA clusters |
| cpx41 | 8 | 16 GB | 240 GB | €34 | Medium production |
| cax21 | 4 | 8 GB | 80 GB | €7 | ARM64 option |

**Upgrading server type:**

```bash
# Edit kube.tfvars
control_plane_server_type = "cpx31"

# Apply (may require node rebuild)
terraform apply -var-file=kube.tfvars
```

---

## Forgejo Configuration

### File: `apps/forgejo.yaml`

Key settings explained:

```yaml
# Deployment size
replicaCount: 1  # Single instance (HA requires multiple)

# Image version
image:
  tag: "9.0.0"  # Update to latest stable version

# Storage
persistence:
  size: 50Gi           # Database + repos
  storageClassName: hcloud-volumes

# PostgreSQL (embedded database)
postgresql:
  auth:
    password: "CHANGE_ME"  # Must change!
  primary:
    persistence:
      size: 10Gi       # Database volume

# Admin account
gitea:
  admin:
    username: admin          # Change if desired
    password: "CHANGE_ME"    # Must change!
    email: "admin@example.com"

  config:
    server:
      DOMAIN: "git-forge.ts"                    # Your Tailscale hostname
      ROOT_URL: "https://git-forge.ts/"         # Full URL
      HTTP_PORT: 3000
      SSH_PORT: 22

    service:
      ENABLE_REGISTRATION: false      # Only admin can create users
      ALLOW_ONLY_INTERNAL_REGISTRATION: true
```

### Updating Forgejo Version

```bash
# 1. Edit apps/forgejo.yaml in your config repo
# 2. Change targetRevision and image.tag:
targetRevision: '9.1.0'
image:
  tag: "9.1.0"

# 3. Commit and push
git add apps/forgejo.yaml
git commit -m "chore: upgrade Forgejo to 9.1.0"
git push

# 4. Argo CD will auto-sync within 3 minutes
# Monitor in: ../scripts/control.sh ui-argo
```

### Customizing Forgejo Settings

Additional Helm values available:

```yaml
gitea:
  config:
    # Security
    security:
      PASSWORD_HASH_ALGO: "pbkdf2"
      MIN_PASSWORD_LENGTH: 12

    # Features
    repository:
      AUTO_WATCH_NEW_REPOS: false
      DISABLE_STARS: false

    # Email (optional)
    mailer:
      ENABLED: false
      # If enabled, set SMTP details
```

For more options, see [Forgejo Helm Chart Values](https://codeberg.org/forgejo/forgejo-helm/src/branch/main/values.yaml)

---

## Forgejo Runners Configuration

### File: `apps/runner.yaml`

```yaml
# Number of runner instances
replicaCount: 1

# Docker image
image:
  tag: "latest"  # Always latest runner version

# Runner configuration
runner:
  config:
    url: "http://forgejo-http.forgejo.svc.cluster.local:3000"
    token: "REPLACE_ME"  # From Forgejo Site Admin → Actions

    # Job labels (what workflows can request)
    labels:
      - "ubuntu-latest:docker://node:20-bullseye"
      - "ubuntu-22.04:docker://node:20-bullseye"
      - "debian-latest:docker://debian:bookworm"

# Docker-in-Docker (for image builds)
dind:
  enabled: true  # Required for container image builds
  image:
    tag: "dind"

# Resources
resources:
  requests:
    cpu: "500m"
    memory: "512Mi"
  limits:
    cpu: "2000m"      # Max CPU for a single job
    memory: "2Gi"     # Max RAM for a single job
```

### Getting the Runner Token

**Method 1: Manual**

1. Login to Forgejo: https://git-forge.tailnet-name.ts.net
2. Site Admin → Actions → Runners
3. Click "Create Runner"
4. Copy the registration token
5. Update `apps/runner.yaml` with the token
6. Commit to config repo (Argo auto-syncs)

**Method 2: Using kubectl secret**

```bash
# Create secret with runner token
kubectl create secret generic forgejo-runner-token \
  -n forgejo-runner \
  --from-literal=token=YOUR_TOKEN_FROM_FORGEJO

# Then update apps/runner.yaml:
runner:
  config:
    url: "http://forgejo-http.forgejo.svc.cluster.local:3000"
    token:
      existingSecret: forgejo-runner-token
      key: token
```

### Writing Workflows

In your Forgejo repository, create `.forgejo/workflows/ci.yml`:

```yaml
name: CI
on:
  push:
    branches: [main, develop]
  pull_request:

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3

      - name: Setup Node
        uses: actions/setup-node@v3
        with:
          node-version: '20'

      - name: Install dependencies
        run: npm install

      - name: Run tests
        run: npm test

      - name: Build
        run: npm run build

      - name: Build Docker image
        run: docker build -t myapp:latest .
```

---

## Backup Configuration

### File: `apps/backup.yaml`

```yaml
# Schedule (cron syntax)
schedule: "0 3 * * *"  # 3 AM UTC daily

# Storage details
volumes:
  - name: forgejo-data
    persistentVolumeClaim:
      claimName: data-forgejo-0  # Check with: kubectl get pvc -n forgejo

# Dump container
initContainers:
  - name: dump
    image: codeberg.org/forgejo/forgejo:9.0.0
    # Creates /backup/dump.zip

# Upload container
containers:
  - name: upload
    image: minio/mc:latest
    env:
      - ACCESS_KEY: From S3 credentials secret
      - SECRET_KEY: From S3 credentials secret
```

### Setting Up S3 Credentials

**Create Kubernetes secret:**

```bash
kubectl create secret generic s3-credentials -n forgejo \
  --from-literal=access-key=YOUR_AWS_ACCESS_KEY \
  --from-literal=secret-key=YOUR_AWS_SECRET_KEY
```

**Or base64 encode manually:**

```bash
echo -n "YOUR_KEY" | base64
# Paste output into apps/backup.yaml stringData section
```

### S3 Configuration

**AWS S3:**
```bash
# Create bucket
aws s3 mb s3://my-forgejo-backups

# Set lifecycle (delete old backups after 90 days)
aws s3api put-bucket-lifecycle-configuration \
  --bucket my-forgejo-backups \
  --lifecycle-configuration '{
    "Rules": [
      {
        "ID": "delete-old-backups",
        "Status": "Enabled",
        "Prefix": "forgejo-",
        "Expiration": {"Days": 90}
      }
    ]
  }'
```

**MinIO (self-hosted S3):**
```yaml
# In backup.yaml, upload container:
args:
  - |
    mc alias set s3 https://minio.example.com:9000 $ACCESS_KEY $SECRET_KEY
    mc cp /backup/dump.zip s3/backups/forgejo-$(date +%Y-%m-%d).zip
```

### Restoring from Backup

```bash
# 1. Download backup from S3
aws s3 cp s3://my-forgejo-backups/forgejo-2026-01-16.zip ./dump.zip

# 2. Get Forgejo pod
kubectl get pods -n forgejo -l app=forgejo

# 3. Copy backup into pod
kubectl cp dump.zip forgejo/forgejo-0:/tmp/dump.zip -n forgejo

# 4. Restore (exec into pod)
kubectl exec -it forgejo-0 -n forgejo -- /bin/bash

# Inside pod:
forgejo restore -f /tmp/dump.zip -c /data/gitea/conf/app.ini
systemctl restart forgejo  # or restart pod
```

---

## Tailscale Configuration

### OAuth Setup

1. **Generate OAuth credentials:**
   - Visit: https://login.tailscale.com/admin/settings/keys
   - Create: OAuth Application
   - Scopes: devices, node:write
   - Save Client ID and Secret

2. **Update Helm values:**
   ```bash
   helm upgrade tailscale-operator tailscale/tailscale-operator \
     -n tailscale \
     --set-string oauth.clientId="YOUR_ID" \
     --set-string oauth.clientSecret="YOUR_SECRET"
   ```

3. **Verify:**
   ```bash
   tailscale status
   # Should show: Connected (your machine)
   dig git-forge.ts
   # Should resolve to 100.x.y.z
   ```

### DNS / MagicDNS

Tailscale automatically provides DNS:

| Service | DNS Name | URL |
|---------|----------|-----|
| Forgejo | git-forge | https://git-forge.tailnet-xxx.ts.net |
| Argo CD | (via port-forward) | http://localhost:8080 |

### Closing Firewall Ports

Once Tailscale is working, close all Hetzner ports:

```bash
# Edit infra/main.tf to close ports:
firewall_kube_api_in_port = null  # Close API
firewall_ssh_in_port = null       # Close SSH

# Apply
terraform apply -var-file=kube.tfvars
```

Access only via Tailscale VPN (more secure).

---

## Argo CD Configuration

### Helm Values

Install with custom settings:

```bash
helm upgrade --install argocd argo/argo-cd \
  -n argocd \
  --set-string server.insecure=true \
  --set-string server.extraArgs[0]="--insecure" \
  --set repoServer.replicas=2
```

### Adding Git Repositories

Via UI:
1. Settings → Repositories → Connect Repo
2. URL: https://github.com/yourname/config-repo
3. Type: git
4. Username/password (if private)

Via kubectl:
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: github-creds
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
type: Opaque
stringData:
  type: git
  url: https://github.com/yourname/config-repo
  password: YOUR_GITHUB_TOKEN
  username: yourname
```

### RBAC (Access Control)

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-rbac-cm
  namespace: argocd
data:
  policy.default: 'role:readonly'
  policy.csv: |
    p, role:admin, *, *, *, allow
    p, role:readonly, *, *, *, deny
    g, admin, role:admin
```

### Sync Waves (Deployment Order)

Control deployment order in app manifests:

```yaml
metadata:
  annotations:
    argocd.argoproj.io/sync-wave: "0"  # Deploy first
---
metadata:
  annotations:
    argocd.argoproj.io/sync-wave: "1"  # Deploy second
```

### Notifications

Configure Slack alerts:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: argocd-notifications-secret
  namespace: argocd
type: Opaque
data:
  slack-token: BASE64_ENCODED_TOKEN
```

---

## Environment Variables

### Terraform

```bash
export HCLOUD_TOKEN="your_token"
terraform apply -var-file=kube.tfvars
```

### Kubectl

```bash
export KUBECONFIG=~/.kube/config
kubectl get nodes
```

### Tailscale

```bash
tailscale status
tailscale list-devices
```

---

## Monitoring & Logging

### View Pod Logs

```bash
# Forgejo logs
kubectl logs -n forgejo -l app=forgejo --tail=50 -f

# Argo CD logs
kubectl logs -n argocd -l app=argocd-server --tail=50 -f

# Runner logs
kubectl logs -n forgejo-runner -l app=forgejo-runner --tail=50 -f
```

### Resource Usage

```bash
# Node resources
kubectl top nodes

# Pod resources
kubectl top pods -n forgejo
kubectl top pods -n argocd
```

### Events

```bash
# Recent events
kubectl get events -A --sort-by='.lastTimestamp' | tail -20

# Watch events
kubectl get events -A -w
```

---

## Troubleshooting Configuration

### Forgejo shows "500 Internal Server Error"

```bash
# Check database
kubectl logs -n forgejo deployment/forgejo-postgresql --tail=50

# Restart Forgejo
kubectl rollout restart deployment/forgejo -n forgejo
```

### Runners not picking up jobs

```bash
# Verify runner registration
kubectl logs -n forgejo-runner -l app=forgejo-runner --tail=50

# Check runner status in Forgejo UI:
# Site Admin → Actions → Runners
# Should show as "Online"
```

### Backups failing

```bash
# Check backup pod logs
kubectl logs -n forgejo -l app=forgejo-backup --tail=100

# Verify S3 credentials
kubectl get secret s3-credentials -n forgejo -o yaml

# Test S3 connectivity
kubectl run -it --rm s3-test --image=minio/mc -- \
  sh -c "mc alias set s3 https://s3.amazonaws.com $ACCESS_KEY $SECRET_KEY && mc ls s3/my-bucket"
```

---

**Last Updated:** 2026-01-16
