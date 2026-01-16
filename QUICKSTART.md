# Quick Start Guide

Get Ironclad running in ~30 minutes.

---

## 1. Prepare (5 minutes)

```bash
# Install dependencies
brew install terraform kubectl  # macOS
# OR on Linux: Download from official websites

# Create Hetzner API token
# Visit: https://hetzner.cloud → Console → Security → Tokens
# Create token: terraform-ironclad (Read & Write)
# Copy the token (paste it later)

# Install Python dependencies (for dashboard)
pip install kubernetes rich
```

---

## 2. Deploy Kubernetes (10 minutes)

```bash
cd infra

# Copy and configure
cp kube.tfvars.example kube.tfvars

# Edit kube.tfvars:
# - Replace hcloud_token with your actual token from step 1
# - Save file
nano kube.tfvars  # or your favorite editor

# Deploy
terraform init
terraform plan -var-file=kube.tfvars
terraform apply -var-file=kube.tfvars
# Type: yes when prompted
# Wait 5-10 minutes...

# Verify
export KUBECONFIG=~/.kube/config
kubectl get nodes
# Should show: 1 Ready control-plane node
```

---

## 3. Install Tailscale (5 minutes)

```bash
# Generate Tailscale OAuth credentials:
# Visit: https://login.tailscale.com/admin/settings/keys
# Create Auth Key: tag:k8s, Reusable, Ephemeral
# Copy the Client ID and Client Secret

# Install Tailscale Helm chart
helm repo add tailscale https://pkgs.tailscale.com/helmcharts
helm repo update
helm upgrade --install tailscale-operator tailscale/tailscale-operator \
  --namespace tailscale --create-namespace \
  --set-string oauth.clientId="PASTE_YOUR_CLIENT_ID" \
  --set-string oauth.clientSecret="PASTE_YOUR_CLIENT_SECRET"

# Verify
kubectl get pods -n tailscale
```

---

## 4. Install Argo CD (3 minutes)

```bash
# Install
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Wait for pods to start
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=argocd-server -n argocd --timeout=300s

# Access UI
../scripts/control.sh ui-argo
# Opens http://localhost:8080

# Get admin password
kubectl get secret -n argocd argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d
echo ""  # newline
```

---

## 5. Create Config Repository (2 minutes)

Create a **private GitHub/Codeberg repository** with this structure:

```
your-config-repo/
├── apps/
│   ├── forgejo.yaml
│   └── backup.yaml
└── README.md (optional)
```

**Copy files from this repo:**
- `apps/forgejo.yaml` → your-config-repo/apps/forgejo.yaml
- `apps/backup.yaml` → your-config-repo/apps/backup.yaml

**⚠️ SECURITY WARNING:**
> **CRITICAL:** The default password `ChangeMe123!` in `apps/forgejo.yaml` is insecure and MUST be changed before deployment. Failing to change default credentials exposes your infrastructure to unauthorized access.

**Edit the files:**

`apps/forgejo.yaml`:
- **[REQUIRED]** Change admin password in `gitea.admin.password` (default: `ChangeMe123!`)
- **[REQUIRED]** Change PostgreSQL password in `postgresql.auth.password`
- **[REQUIRED]** Update Tailscale domains (`DOMAIN`, `ROOT_URL`, `SSH_DOMAIN`) to match your tailnet

`apps/backup.yaml`:
- Fill S3 credentials (access-key, secret-key)
- Change bucket name to your actual S3 bucket

Push to GitHub/Codeberg.

---

## 6. Connect Argo CD to Config Repo (3 minutes)

```bash
# In Argo CD UI (http://localhost:8080):
# 1. Settings → Repositories → Connect Repo
# 2. Connection Method: HTTPS
# 3. URL: https://github.com/YOUR_USERNAME/YOUR_CONFIG_REPO
# 4. Skip verification (or provide credentials if private)
# 5. Click Connect

# Then create Application:
# 1. Create Application
# 2. Application Name: root
# 3. Project: default
# 4. Repository URL: https://github.com/YOUR_USERNAME/YOUR_CONFIG_REPO
# 5. Path: apps
# 6. Destination: https://kubernetes.default.svc (default cluster)
# 7. Sync Policy: Automatic, Prune, Self-heal
# 8. Click Create

# Wait for sync (1-2 minutes)
```

Or use kubectl:

```bash
kubectl apply -f - <<'EOF'
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/YOUR_USERNAME/YOUR_CONFIG_REPO
    path: apps
  destination:
    server: https://kubernetes.default.svc
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
EOF
```

---

## 7. Access Your Infrastructure

```bash
# Check status
../scripts/control.sh status

# Open Forgejo (private Git server)
../scripts/control.sh ui-git
# Should open: https://git-forge.tailnet-name.ts.net

# Open Argo CD
../scripts/control.sh ui-argo

# View all pods
../scripts/control.sh pods

# Check resource usage
../scripts/control.sh top
```

---

## 8. Verify Backups

```bash
# Create S3 credentials secret first:
kubectl create secret generic s3-credentials -n forgejo \
  --from-literal=access-key=YOUR_S3_ACCESS_KEY \
  --from-literal=secret-key=YOUR_S3_SECRET_KEY

# Trigger manual backup
../scripts/control.sh backup-now

# Watch backup progress
../scripts/control.sh logs-backup
```

---

## Done! 🎉

Your self-hosted infrastructure is live:
- **Kubernetes cluster** running on Hetzner
- **Forgejo** (private Git server)
- **Forgejo Runners** (self-hosted CI/CD)
- **Argo CD** (GitOps)
- **Daily backups** to S3
- **Tailscale VPN** (secure private access)

---

## Next Steps

1. **Configure Forgejo:**
   - Add users: Site Admin → Users
   - Create repositories
   - Enable Actions

2. **Set up CI/CD:**
   - Create `.forgejo/workflows/ci.yml` in your repos
   - Runners will auto-pick up jobs

3. **Monitor:**
   - Run `../scripts/control.sh status` daily
   - Check backup age

4. **Maintenance:**
   - Update versions in `apps/*.yaml` (Argo CD auto-syncs)
   - Scale nodes in `infra/kube.tfvars` (Terraform re-applies)

---

## Troubleshooting

**Pods stuck in pending/crashing?**
```bash
kubectl logs -n forgejo -l app=forgejo --tail=50
kubectl describe pod -n forgejo -l app=forgejo
```

**Can't access Forgejo via Tailscale?**
```bash
# Verify Tailscale is running
tailscale status

# Check ingress
kubectl get ingress -n forgejo

# Check DNS
dig git-forge.ts
```

**Backup failed?**
```bash
kubectl logs -n forgejo -l app=forgejo-backup --tail=100
```

For more help, see:
- `README.md` - Full reference guide
- `CLAUDE.md` - Architecture & design
- `TERRAFORM_SETUP.md` - Terraform details

---

**Total Setup Time:** ~30 minutes (first time)
**Cluster Uptime:** 99.9% (single node, no SLA)
**Monthly Cost:** ~€9 (cpx21) + backup storage

---

**Last Updated:** 2026-01-16
