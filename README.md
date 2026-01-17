# Ironclad Infrastructure

Self-hosted, fully owned Kubernetes stack on Hetzner Cloud with GitOps management via Argo CD.

**Components:**
- Talos OS Kubernetes cluster
- Forgejo (private Git server)
- Argo CD (GitOps configuration management)
- Automated S3 backups

**Note:** Forgejo Runners (self-hosted CI/CD) are not yet configured in this repository.

---

## Quick Start

### Prerequisites

1. **Hetzner Cloud Account**
   - Sign up at https://hetzner.cloud
   - Generate API token in Console → Security → Tokens

2. **Local Tools**
   ```bash
   # macOS
   brew install terraform kubectl

   # Linux
   # Download from https://www.terraform.io/downloads
   # Download from https://kubernetes.io/docs/tasks/tools/
   ```

3. **Python (for dashboard)**
   ```bash
   pip install kubernetes rich
   ```

### Phase 1: Deploy Kubernetes Infrastructure

```bash
# 1. Navigate to infra directory
cd infra

# 2. Copy example tfvars and fill in your values
cp kube.tfvars.example kube.tfvars
# Edit kube.tfvars with your Hetzner token and desired configuration

# 3. Initialize Terraform
terraform init

# 4. (Optional) Use terraform.sh for encrypted vars (if kube.tfvars is SOPS-encrypted)
# The script automatically decrypts with SOPS, securely cleans up after
./terraform.sh plan
./terraform.sh apply

# OR: Use plain Terraform (if kube.tfvars is not encrypted)
terraform plan -var-file=kube.tfvars
terraform apply -var-file=kube.tfvars

# 5. Verify kubeconfig is written
export KUBECONFIG=~/.kube/config
kubectl cluster-info
kubectl get nodes

# 6. Get Talos kubeconfig for host access
./terraform.sh output -raw talosconfig > ~/.talos/config
talosctl dashboard  # View node metrics, memory, processes
```

**Estimated time:** 5-10 minutes for cluster creation

### Server Upgrades

To upgrade the node from CAX11 to CAX21 (or vice versa):

```bash
cd infra

# Plan the upgrade (view diff)
./terraform.sh plan

# Apply the upgrade (downtime ~5 minutes)
./terraform.sh apply

# Monitor cluster recovery
kubectl get nodes -w  # Wait for "Ready" status
```

**Note:** Talos automatically handles rebooting and recovery after server type change. No manual intervention needed.

### Phase 2: Install Tailscale (Secure VPN Access)

```bash
# 1. Generate Tailscale OAuth credentials
# Visit: https://login.tailscale.com/admin/settings/keys
# Create: Auth Key with tag "tag:k8s", Reusable, Ephemeral

# 2. Add Tailscale Helm repo
helm repo add tailscale https://pkgs.tailscale.com/helmcharts
helm repo update

# 3. Install Tailscale Operator
helm upgrade --install tailscale-operator tailscale/tailscale-operator \
  --namespace tailscale --create-namespace \
  --set-string oauth.clientId="YOUR_OAUTH_CLIENT_ID" \
  --set-string oauth.clientSecret="YOUR_OAUTH_CLIENT_SECRET"

# 4. Verify
kubectl get pods -n tailscale
```

### Phase 3: Install Argo CD (GitOps)

```bash
# 1. Create argocd namespace and install
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# 2. Port-forward and open UI
./scripts/control.sh ui-argo

# 3. Get admin password
kubectl get secret -n argocd argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d
```

### Phase 4: Deploy Applications

Create a **separate private GitHub/Codeberg repository** for your configuration. This is your "Backup Brain."

**In that config repo, create:**

```
apps/
├── forgejo.yaml       # Git server
└── backup.yaml        # Automated backups
```

Copy the YAML files from the `apps/` directory in this repo into your config repo.

**Note:** Runner configuration is not yet included; CI/CD runners must be set up separately.

**Then point Argo CD to your config repo:**

```bash
# In Argo UI:
# 1. Settings > Repositories > Connect Repo
# 2. URL: https://github.com/YOUR_USERNAME/YOUR_CONFIG_REPO
# 3. Create Application pointing to that repo
#
# OR apply via kubectl:
kubectl apply -f - <<EOF
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

## File Structure

```
.
├── CLAUDE.md                      # Claude Code guidance (AI-friendly docs)
├── README.md                      # This file
├── PLAN.md                        # Original deployment plan
├── terraform-hetzner-readme.md    # Terraform module reference
├── .gitignore                     # Prevent committing secrets
│
├── infra/                         # Terraform infrastructure
│   ├── main.tf                    # Talos OS cluster definition
│   ├── variables.tf               # Input variables
│   ├── outputs.tf                 # Cluster outputs (IP, kubeconfig)
│   ├── backend.tf                 # State management config
│   ├── kube.tfvars.example        # Template for configuration
│   └── terraform.tflock           # Dependency lock file (commit this!)
│
├── apps/                          # Argo CD application manifests
│   ├── forgejo.yaml               # Git server (Helm chart)
│   └── backup.yaml                # Database backups to S3
│
└── scripts/                       # Helper scripts
    ├── control.sh                 # Control center (status, UI, backups)
    └── dashboard.py               # Python health dashboard
```

---

## Common Tasks

### Check Cluster Health

```bash
# Quick Python dashboard
./scripts/control.sh status

# Or use k9s (real-time TUI)
brew install k9s
k9s
```

### Open Argo CD UI

```bash
./scripts/control.sh ui-argo
# Opens http://localhost:8080
```

### Open Forgejo

```bash
./scripts/control.sh ui-git
# Opens https://git-forge.tailnet-name.ts.net (Tailscale)
```

### Trigger Manual Backup

```bash
./scripts/control.sh backup-now
./scripts/control.sh logs-backup  # Watch progress
```

### View All Pods

```bash
./scripts/control.sh pods
```

### Real-time Pod Metrics

```bash
./scripts/control.sh top
```

### Access Talos Host System (htop-like dashboard)

**Note:** Talos OS doesn't support SSH. Use `talosctl` instead.

```bash
# 1. Configure talosctl (one-time setup)
cd infra
mkdir -p ~/.talos
terraform output -raw talosconfig > ~/.talos/config

# 2. Access interactive dashboard (like htop)
talosctl dashboard

# 3. Other useful commands
talosctl memory           # Show memory usage
talosctl processes        # Show running processes
talosctl read /proc/meminfo  # Detailed memory stats
talosctl get members      # Cluster member info
```

**Keyboard shortcuts in dashboard:**
- `h/l` or `←/→` - Switch nodes (if multi-node)
- `j/k` or `↓/↑` - Scroll logs/processes
- `Ctrl-d/u` - Page down/up
- `q` - Quit

**For Terraform operations with encrypted tfvars:**
```bash
# Decrypt tfvars temporarily (requires Yubikey)
cd infra
sops -d kube.tfvars > kube.tfvars.decrypted
terraform plan -var-file=kube.tfvars.decrypted
rm kube.tfvars.decrypted

# Or decrypt in-place
sops -d -i kube.tfvars    # decrypt
terraform plan -var-file=kube.tfvars
sops -e -i kube.tfvars    # re-encrypt
```

---

## Configuration

### Updating Forgejo Version

1. Edit `apps/forgejo.yaml` in your config repo
2. Change `targetRevision` and `image.tag`
3. Commit and push
4. Argo CD auto-syncs (check UI or `kubectl`)

### Scaling to Multiple Nodes

Edit `infra/kube.tfvars`:

```hcl
control_plane_count = 3        # For HA
agent_node_pools = [
  {
    name              = "worker"
    server_type       = "cpx21"
    count             = 2
  }
]
```

Then: `terraform apply -var-file=kube.tfvars`

### Enabling Metrics/Monitoring

Metrics Server is enabled by default. For full monitoring:

```bash
# Install Prometheus (if you have RAM)
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm install prometheus prometheus-community/kube-prometheus-stack -n monitoring --create-namespace
```

---

## Troubleshooting

### K8s Cluster Won't Start

```bash
# Check Hetzner Cloud Console - is the node running?
# SSH to node (from Hetzner console)
ssh root@<NODE_IP>

# Check Talos (requires talosctl)
talosctl -n <NODE_IP> version
talosctl -n <NODE_IP> logs kubelet
```

### Forgejo Pods Stuck in CrashLoopBackOff

```bash
kubectl logs -n forgejo -l app=forgejo --tail=50

# Common issues:
# - Database not ready (wait 2-3 mins)
# - PVC not bound: kubectl get pvc -n forgejo
# - Bad config: check apps/forgejo.yaml
```

### Backup Failing

```bash
kubectl logs -n forgejo -l app=forgejo-backup --tail=50

# Check:
# - S3 credentials in secret: kubectl get secret s3-credentials -n forgejo
# - PVC name: kubectl get pvc -n forgejo
# - S3 bucket exists and is accessible
```

### Can't Access via Tailscale

```bash
# Verify Tailscale is running
tailscale status

# Check Ingress controller
kubectl get ingress -n forgejo
kubectl logs -n tailscale -l app=tailscale-operator --tail=50

# Check DNS
dig git-forge.ts
# Should resolve to 100.x.y.z
```

---

## Security Notes

1. **Close Hetzner Firewall** (if using Tailscale only)
   - You can close ports 22, 6443, 80, 443 for maximum security
   - All access via Tailscale VPN (private mesh)

2. **Backup Strategy**
   - Daily database dumps to S3
   - Test restore process before relying on it!
   - Verify S3 bucket encryption

3. **Secret Management**
   - Never commit `kube.tfvars` (contains Hetzner token)
   - Use K8s secrets for S3 credentials, runner tokens
   - Rotate credentials every 90 days

4. **Node Security**
   - MicroOS auto-updates (zero manual maintenance)
   - Btrfs snapshots auto-rollback failed updates
   - SSH is not exposed to internet (Tailscale only)

---

## Maintenance

### Daily
```bash
./scripts/control.sh status
# Verify: green backup status, all pods running
```

### Weekly
```bash
k9s
# Check pod restart counts, CPU/RAM usage
```

### Monthly
1. Test backup restoration (S3 → local)
2. Rotate S3 credentials
3. Check Hetzner billing

### Quarterly
1. Talos OS updates automatically; verify with `talosctl version`
2. Update Forgejo: edit `apps/forgejo.yaml` → Argo syncs
3. Rotate Tailscale OAuth keys
4. Review firewall rules

---

## Advanced: Remote State Management

For production, use a remote Terraform state backend:

### S3 Backend

```hcl
# infra/backend.tf
terraform {
  backend "s3" {
    bucket         = "my-terraform-state"
    key            = "ironclad/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "terraform-locks"
  }
}
```

Then:
```bash
cd infra
terraform init  # Migrates state to S3
```

### Terraform Cloud

```hcl
# infra/backend.tf
terraform {
  cloud {
    organization = "my-org"
    workspaces {
      name = "ironclad"
    }
  }
}
```

---

## References

- [CLAUDE.md](CLAUDE.md) - Claude Code AI guidance
- [PLAN.md](PLAN.md) - Original implementation plan
- [terraform-hetzner-readme.md](terraform-hetzner-readme.md) - Terraform module docs
- [Talos OS Documentation](https://www.talos.dev/)
- [Forgejo Documentation](https://forgejo.org/docs/latest/)
- [Argo CD Documentation](https://argo-cd.readthedocs.io/)
- [Tailscale Kubernetes Operator](https://tailscale.com/kb/1236/tailscale-operator)

---

## Support

For issues with:
- **Terraform/Hetzner:** See `terraform-hetzner-readme.md` or https://github.com/hcloud-k8s/terraform-hcloud-kubernetes
- **Talos OS:** https://www.talos.dev/ or https://github.com/siderolabs/talos
- **Forgejo:** https://codeberg.org/forgejo/forgejo
- **Argo CD:** https://github.com/argoproj/argo-cd

---

**Last Updated:** 2026-01-16
