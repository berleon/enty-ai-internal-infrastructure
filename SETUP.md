# Ironclad Cluster Setup Guide

After deploying infrastructure with Terraform, use these scripts to complete the cluster setup.

## Quick Start

```bash
# 1. Complete automated setup
./scripts/setup-cluster.sh

# OR manually:

# 1. Save kubeconfig
cd infra
terraform output -raw kubeconfig > ~/.kube/config
chmod 600 ~/.kube/config
cd ..

# 2. Install Argo CD
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# 3. Configure secrets
./scripts/setup-secrets.sh
```

## What Gets Set Up

### 1. Kubeconfig
Saves your cluster credentials locally so `kubectl` can connect.

```bash
terraform output -raw kubeconfig > ~/.kube/config
chmod 600 ~/.kube/config
```

### 2. Argo CD
GitOps engine that automatically deploys from your GitHub repository.

```bash
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
```

Access Argo CD UI:
```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
# https://localhost:8080
# Username: admin
# Password: kubectl get secret -n argocd argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
```

### 3. GitHub Repository Configuration
Tells Argo CD how to access your private GitHub repository.

```bash
# Using environment variable
export GITHUB_TOKEN=github_pat_...
./scripts/setup-secrets.sh

# OR manually
kubectl create secret generic your-username-repo \
  -n argocd \
  --from-literal=type=git \
  --from-literal=url=https://github.com/your-user/your-repo \
  --from-literal=password=YOUR_GITHUB_PAT \
  --from-literal=username=not_used
```

### 4. Application Secrets

#### S3 Backup Credentials
Required to enable daily Forgejo database backups to S3.

```bash
kubectl create secret generic s3-credentials \
  -n forgejo \
  --from-literal=access-key=YOUR_AWS_ACCESS_KEY \
  --from-literal=secret-key=YOUR_AWS_SECRET_KEY \
  --from-literal=bucket=my-backups-bucket \
  --from-literal=endpoint=https://s3.amazonaws.com
```

**Or skip if you don't use S3:**
- The backup CronJob will still be created but won't run
- You can add S3 credentials anytime

#### Forgejo Runner Token
Required to enable CI/CD runners (like GitHub Actions).

```bash
# 1. Get the token from Forgejo
# Access: kubectl port-forward svc/forgejo -n forgejo 3000:3000
# Then: Site Admin → Actions → Runners → Create Runner → Copy Token

# 2. Create the secret
kubectl create secret generic forgejo-runner-token \
  -n forgejo-runner \
  --from-literal=token=YOUR_REGISTRATION_TOKEN

# 3. Update apps/runner.yaml with the token and commit to GitHub
# (Argo CD will auto-deploy the runners)
```

### 5. Tailscale Integration (Recommended)
Secure, encrypted access to your cluster and Forgejo over Tailscale network.

#### Prerequisites
1. Create Tailscale OAuth credentials:
   - Go to: https://login.tailscale.com/admin/settings/keys
   - Create OAuth client with scopes: `Devices Core`, `Auth Keys`, `Services`
   - Tag it with `tag:k8s-operator`
   - Save **Client ID** and **Client Secret** (keep these private)

2. Configure Tailscale policy tags (in your Tailscale policy file):
   ```
   "tag:k8s-operator": ["group:owners"],
   "tag:k8s": ["group:owners"],
   ```

#### Installation
```bash
# Run interactive setup script (you'll be prompted for credentials locally)
./scripts/setup-tailscale.sh

# After operator is ready, expose Forgejo via Tailscale
kubectl apply -f apps/forgejo-tailscale-ingress.yaml
```

#### Access Forgejo via Tailscale
```bash
# After setup, Forgejo will be accessible at:
http://forgejo.YOUR_TAILNET_NAME

# Example: http://forgejo.user.github (if your tailnet is user.github)

# No port-forwarding needed - just connect to your Tailscale network from any device
```

#### Verification
```bash
# Check Tailscale operator status
kubectl get pods -n tailscale

# Verify operator appears in Tailscale admin console
# Should show a machine named "tailscale-operator" tagged with tag:k8s-operator

# Check Forgejo service on Tailscale
kubectl get service forgejo-tailscale -n forgejo
kubectl get proxy -n forgejo
```

#### Benefits
- ✅ Secure VPN access (encrypted end-to-end)
- ✅ No public exposure (not on the internet)
- ✅ Access from anywhere on your Tailnet
- ✅ Works from laptop, phone, tablet, etc.
- ✅ No need for port-forwarding
- ✅ No external firewall rules needed

## Deployment Flow

```
Terraform Apply (infra/)
    ↓
./scripts/setup-cluster.sh
    ├── Save kubeconfig
    ├── Install Argo CD
    ├── Configure GitHub access
    └── ./scripts/setup-secrets.sh
        ├── S3 credentials (optional)
        ├── Forgejo admin password
        └── Runner token (optional)
    ↓
./scripts/setup-tailscale.sh (RECOMMENDED)
    ├── Install Tailscale Kubernetes Operator
    └── Create Tailscale service for Forgejo
    ↓
Argo CD monitors your GitHub repo
    ↓
Push changes to apps/*.yaml
    ↓
Argo CD auto-deploys (every ~3 minutes)
    ↓
Access via Tailscale: http://forgejo.YOUR_TAILNET
```

## Environment Variables for Automation

For CI/CD pipelines or automated deployment:

```bash
# GitHub personal access token (required)
export GITHUB_TOKEN=github_pat_...

# AWS S3 credentials (optional)
export AWS_ACCESS_KEY=your_key
export AWS_SECRET_KEY=your_secret
export AWS_BUCKET=your-bucket

# Then run:
./scripts/setup-cluster.sh
```

## Secret Management Best Practices

### ✓ What to Do
- [ ] Create secrets via `kubectl` (not in git)
- [ ] Use `.gitignore` to exclude secret files
- [ ] Reference secrets from environment variables
- [ ] Rotate credentials every 90 days
- [ ] Use external secret storage (Vault, AWS Secrets Manager) for production

### ✗ What NOT to Do
- [ ] Commit secrets to git
- [ ] Share credentials in messages, logs, or files
- [ ] Use default passwords in production
- [ ] Store credentials in YAML files

## Troubleshooting

### Cluster won't connect
```bash
# Verify kubeconfig is set correctly
kubectl cluster-info

# Or explicitly set kubeconfig
export KUBECONFIG=$(pwd)/infra/kubeconfig.yaml
```

### Argo CD won't sync
```bash
# Check if GitHub secret is configured
kubectl describe secret your-username-repo -n argocd

# Check Argo CD repo server logs
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-repo-server
```

### Applications not deploying
```bash
# Check Argo CD applications
kubectl get applications -n argocd

# Describe specific app
kubectl describe application forgejo -n argocd

# Check if Argo CD can reach your repo
# (See Argo CD UI at https://localhost:8080)
```

### Forgejo not starting
```bash
# Check pod status
kubectl get pods -n forgejo

# View logs
kubectl logs -n forgejo -l app=forgejo

# Check storage
kubectl get pvc -n forgejo
```

## Next Steps

1. **Verify deployment:**
   ```bash
   kubectl get all -A
   kubectl get applications -n argocd
   ```

2. **Setup Tailscale for web access (RECOMMENDED):**
   ```bash
   # Run setup script (you'll be prompted for OAuth credentials)
   ./scripts/setup-tailscale.sh

   # Then expose Forgejo via Tailscale
   kubectl apply -f apps/forgejo-tailscale-ingress.yaml

   # Access at: http://forgejo.YOUR_TAILNET_NAME
   ```

3. **Alternative: Port-forward (if not using Tailscale):**
   ```bash
   kubectl port-forward svc/forgejo-http -n forgejo 3000:3000
   # http://localhost:3000
   ```

4. **Access Argo CD:**
   ```bash
   kubectl port-forward svc/argocd-server -n argocd 8080:443
   # https://localhost:8080
   ```

5. **First login to Forgejo:**
   ```bash
   # Username: administrator
   # Password: ChangeMe123! (⚠️ CHANGE THIS IMMEDIATELY!)
   ```

6. **Push changes to deploy:**
   ```bash
   # Edit apps/forgejo.yaml or apps/runner.yaml
   git push origin main
   # Argo CD will auto-sync in ~3 minutes
   ```

## See Also

- `CLAUDE.md` - Architecture and workflow guide
- `README.md` - Project overview
- `QUICKSTART.md` - 30-minute setup walkthrough
