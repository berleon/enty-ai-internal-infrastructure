# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

---

## Overview

This repository contains infrastructure-as-code and deployment configuration for "Ironclad" - a self-hosted, private Kubernetes stack on Hetzner Cloud. It deploys:
- **Kubernetes cluster** on a single Hetzner Cloud node (Talos OS for immutable, auto-updating infrastructure)
- **Forgejo** (private Git server)
- **Forgejo Runners** (self-hosted CI/CD like GitHub Actions)
- **Argo CD** (GitOps configuration management)
- **Automated S3 backups** of critical data

**Philosophy:** Infrastructure as Code (Terraform), GitOps (Argo CD), secure private networking (Tailscale).

---

## Project Architecture

### Stack Components

| Layer | Technology | Purpose |
|-------|-----------|---------|
| **Compute** | Hetzner Cloud (`cpx21` 3vCPU/4GB) | Cost-effective EU hosting (~€9/mo) in Nuremberg (nbg1) |
| **OS** | Talos Linux | Immutable, auto-updating, minimal attack surface |
| **Orchestration** | Kubernetes (via Talos) | Production-grade Kubernetes (not K3s) |
| **Networking** | Tailscale | Private VPN mesh, no open ports, auto-HTTPS |
| **Git Server** | Forgejo | Community fork of Gitea, stable, Actions-capable |
| **CI/CD** | Forgejo Runners | Docker-in-Docker builds via wrenix chart |
| **Configuration** | Argo CD | GitOps: cluster state matches git repo |
| **Storage** | Hetzner Volumes + S3 | Persistent storage + off-site backups |

### Data Flow

```
Your Laptop (Tailscale VPN)
        ↓
    MagicDNS
        ↓
K8s Ingress (Tailscale)
        ↓
Forgejo Pod → Argo CD monitors git config repo → Updates cluster
        ↓
Forgejo Runners (Docker builds) → Stores artifacts
        ↓
CronJob (Daily) → Backup to S3
```

### Critical Design Decisions

1. **Single Node** (not HA): Cheaper, simpler, sufficient for private infrastructure. Data persists via Hetzner Volumes.
2. **No Public Ports**: All access via Tailscale private VPN. SSH, API, Forgejo only accessible from your tailnet.
3. **MicroOS Auto-Updates**: Node reboots automatically, survives boot failures via Btrfs snapshots. Zero manual OS patching.
4. **Argo CD + GitHub/Codeberg**: Config lives in a **separate repo** (your "Backup Brain"). If K8s dies, re-apply the config repo to rebuild.

---

## Repository Structure

```
.
├── PLAN.md                      # Original implementation guide (see terraform-hetzner-readme.md for current module interface)
├── terraform-hetzner-readme.md  # Terraform module reference (AUTHORITATIVE - current interface)
├── CLAUDE.md                    # This file
├── infra/                       # (To be created) Terraform configs
│   ├── main.tf                  # K3s cluster on Hetzner
│   ├── kube.tfvars              # Cluster params (sensitive)
│   └── outputs.tf               # Outputs (node IP, kubeconfig)
├── apps/                        # (To be created) Argo CD app manifests
│   ├── forgejo.yaml             # Forgejo Helm Application
│   ├── runner.yaml              # Forgejo Runner Application
│   └── backup.yaml              # Backup CronJob
├── scripts/                     # (To be created) Helper scripts
│   ├── control.sh               # Control center (status, UI, backup)
│   └── dashboard.py             # Python status dashboard
└── .gitignore                   # (To be created) Exclude secrets
```

---

## Deployment Phases

### Phase 1: Infrastructure (Terraform)

**Goal:** Create K3s cluster on Hetzner Cloud with Talos OS.

**Prerequisites:**
- Hetzner Cloud account + API token
- Terraform >= 1.0
- `kubectl` locally
- Packer (for building Talos OS image)

**Important:** The module interface has evolved. Reference `terraform-hetzner-readme.md` in this repo for the current configuration format, not the original PLAN.md.

**Steps:**

```bash
# 1. Set up Terraform directory
cd infra

# 2. Create kube.tfvars with your values
# See kube.tfvars.example for the current interface
cp kube.tfvars.example kube.tfvars
# Edit kube.tfvars with:
#   - hcloud_token: YOUR_HETZNER_API_TOKEN
#   - cluster_name: "ironclad-forge"
#   - control_plane_nodepools: One node cpx21 in nbg1 (Nuremberg, Germany)
#   - worker_nodepools: [] (empty for single-node setup)

# 3. Deploy
terraform init
terraform apply -var-file=kube.tfvars

# 4. Retrieve kubeconfig
terraform output -raw kubeconfig > ~/.kube/config
chmod 600 ~/.kube/config

# 5. Verify cluster is ready
kubectl get nodes
```

**Note:** The Packer build process creates a temporary server (may appear in us-east) to build the Talos image. The actual cluster node is created in the configured location (nbg1 = Nuremberg, Germany).

**Output:** Kubernetes cluster is running, accessible via SSH (use Terraform-provided IP).

---

### Phase 2: Tailscale VPN

**Goal:** Secure private access to K3s without opening firewall ports.

**Steps:**

```bash
# 1. Generate Tailscale Auth Key
# Go to: https://login.tailscale.com/admin/settings/keys
# Create: "tag:k8s" tag, Reusable, Ephemeral

# 2. Add Tailscale Helm repo
helm repo add tailscale https://pkgs.tailscale.com/helmcharts
helm repo update

# 3. Install Tailscale Operator
# Requires: OAuth Client ID & Secret from Tailscale admin console
helm upgrade --install tailscale-operator tailscale/tailscale-operator \
  --namespace tailscale --create-namespace \
  --set-string oauth.clientId="YOUR_OAUTH_CLIENT_ID" \
  --set-string oauth.clientSecret="YOUR_OAUTH_CLIENT_SECRET"

# 4. Verify
kubectl get nodes  # Should work via Tailscale IP
```

**After this phase:**
- Your laptop connects to K8s via Tailscale VPN
- K8s API is NOT exposed to the internet
- All pod traffic is encrypted and private

---

### Phase 3: Argo CD (GitOps)

**Goal:** Install GitOps engine that watches your config repo and auto-syncs changes.

**Steps:**

```bash
# 1. Create argocd namespace and install
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# 2. Access Argo UI (port-forward via Tailscale)
kubectl port-forward svc/argocd-server -n argocd 8080:443

# 3. Open https://localhost:8080
# Login with: admin / (get password from kubectl get secret argocd-initial-admin-secret)

# 4. Create your config repository on GitHub/Codeberg (PRIVATE)
# This repo holds: apps/forgejo.yaml, apps/runner.yaml, apps/backup.yaml
```

**Key:** This repo is your "Backup Brain". If K8s dies, you just re-deploy Argo and point it to this repo.

---

### Phase 4: Deploy Forgejo (App)

**Goal:** Install private Git server via Helm + Argo CD.

**File:** `apps/forgejo.yaml` (in your config repo)

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: forgejo
  namespace: argocd
spec:
  project: default
  source:
    repoURL: 'https://codeberg.org/forgejo/forgejo-helm'
    targetRevision: '9.0.0'
    chart: forgejo
    helm:
      values: |
        image:
          tag: 9.0.0
        persistence:
          enabled: true
          size: 50Gi
          storageClass: hcloud-volumes  # Hetzner persistent storage
        ingress:
          enabled: true
          className: tailscale          # Auto-HTTPS via Tailscale magic
          hosts:
            - host: git-forge
          annotations:
            tailscale.com/tags: "tag:k8s"
  destination:
    server: 'https://kubernetes.default.svc'
    namespace: forgejo
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

**Deploy via Argo:**
```bash
kubectl apply -f apps/forgejo.yaml
```

**Access:**
```
https://git-forge.tailnet-name.ts.net
```

---

### Phase 5: CI/CD Runners

**Goal:** Enable Docker builds in Forgejo (like GitHub Actions).

**File:** `apps/runner.yaml` (in your config repo)

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: forgejo-runner
  namespace: argocd
spec:
  project: default
  source:
    repoURL: 'oci://codeberg.org/wrenix/helm-charts'
    chart: forgejo-runner
    targetRevision: '0.6.0'
    helm:
      values: |
        runner:
          config:
            url: "http://forgejo-http.forgejo.svc.cluster.local:3000"
            token: "<YOUR_RUNNER_TOKEN>"  # Get from Forgejo Site Admin > Actions
            labels:
              - "ubuntu-latest:docker://node:20-bullseye"
        dind:
          enabled: true  # Docker-in-Docker for image builds
  destination:
    server: 'https://kubernetes.default.svc'
    namespace: forgejo-runner
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

**Steps:**
1. Log into Forgejo as admin
2. Go to `Site Admin > Actions > Runners > Create Runner`
3. Copy the registration token
4. Update `runner.yaml` with the token
5. Commit to config repo → Argo syncs it

---

### Phase 6: Automated Backups

**Goal:** Daily dumps of Forgejo database → S3 (off-site safety net).

**File:** `apps/backup.yaml` (in your config repo)

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: forgejo-backup-s3
  namespace: forgejo
spec:
  schedule: "0 3 * * *"  # 3 AM daily
  jobTemplate:
    spec:
      template:
        spec:
          volumes:
            - name: backup-dir
              emptyDir: {}
            - name: data
              persistentVolumeClaim:
                claimName: data-forgejo-0  # Check exact name with 'kubectl get pvc -n forgejo'
          initContainers:
            - name: dump
              image: codeberg.org/forgejo/forgejo:9.0.0
              command: ["/bin/sh", "-c"]
              args: ["forgejo dump -c /data/gitea/conf/app.ini -f /backup/dump.zip"]
              volumeMounts:
                - mountPath: /data
                  name: data
                - mountPath: /backup
                  name: backup-dir
          containers:
            - name: upload
              image: minio/mc
              command: ["/bin/sh", "-c"]
              args:
                - |
                  mc alias set s3 https://s3.amazonaws.com $ACCESS_KEY $SECRET_KEY
                  mc cp /backup/dump.zip s3/my-backup-bucket/forgejo-$(date +\%F).zip
              env:
                - name: ACCESS_KEY
                  valueFrom:
                    secretKeyRef:
                      name: s3-credentials
                      key: access-key
                - name: SECRET_KEY
                  valueFrom:
                    secretKeyRef:
                      name: s3-credentials
                      key: secret-key
              volumeMounts:
                - mountPath: /backup
                  name: backup-dir
          restartPolicy: OnFailure
```

**Pre-requisite:** Create S3 credentials secret:
```bash
kubectl create secret generic s3-credentials \
  -n forgejo \
  --from-literal=access-key=YOUR_S3_ACCESS_KEY \
  --from-literal=secret-key=YOUR_S3_SECRET_KEY
```

---

## Common Commands & Workflows

### Check Cluster Health

```bash
# Use the Python dashboard (see scripts/dashboard.py)
python3 scripts/dashboard.py

# Or use k9s (real-time TUI)
brew install k9s  # macOS
curl -sS https://webinstall.dev/k9s | bash  # Linux
k9s
```

### Access Argo CD UI

```bash
# Port-forward Argo CD server
kubectl port-forward svc/argocd-server -n argocd 8080:443

# Open https://localhost:8080
# Get admin password:
kubectl get secret -n argocd argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
```

### Access Forgejo

```bash
# Direct: https://git-forge.tailnet-name.ts.net (via Tailscale)
# Or port-forward:
kubectl port-forward svc/forgejo -n forgejo 3000:3000
# Then: http://localhost:3000
```

### Trigger Manual Backup

```bash
# Create a one-off backup job from the CronJob template
kubectl create job --from=cronjob/forgejo-backup-s3 manual-backup-$(date +%s) -n forgejo

# Watch progress
kubectl logs -f <backup-pod-name> -n forgejo --all-containers
```

### Check Backup Status

```bash
# Check when the backup CronJob last ran
kubectl get cronjob forgejo-backup-s3 -n forgejo

# View last backup logs
kubectl logs $(kubectl get pods -n forgejo -l job-name=forgejo-backup-s3 --sort-by=.metadata.creationTimestamp -o name | tail -n 1) -n forgejo --all-containers
```

### Update Forgejo Version

```bash
# 1. Edit apps/forgejo.yaml in your config repo
# Change: targetRevision: '9.0.0' -> '9.1.0' (or desired version)
#         image.tag: 9.0.0 -> 9.1.0

# 2. Commit and push
git add apps/forgejo.yaml
git commit -m "chore: upgrade Forgejo to 9.1.0"
git push

# 3. Argo CD auto-syncs (usually within a few minutes)
# Verify in Argo UI or via:
kubectl rollout status -n forgejo deployment/forgejo
```

### SSH Into Node (for debugging)

```bash
# Get node IP from Terraform output or Hetzner console
terraform output node_ip

# SSH (requires Tailscale for secure private connection, or use Hetzner Firewall rules)
ssh root@<node-ip>
```

### Scaling the Cluster

**To add worker nodes:**
1. Update `infra/kube.tfvars`: Add to `agent_node_pools`
2. Run `terraform apply -var-file=kube.tfvars`

**To enable pod autoscaling:**
```bash
# metrics-server is already enabled in kube.tfvars
# Add HorizontalPodAutoscaler to your app manifests
```

---

## Configuration & Secrets

### Environment Variables

Use these when creating resources:

| Variable | Where Used | Example |
|----------|-----------|---------|
| `HCLOUD_TOKEN` | Terraform | From Hetzner Cloud Console > API Tokens |
| `TAILSCALE_OAUTH_ID` | Tailscale Helm | From Tailscale Admin > Settings > OAuth Clients |
| `TAILSCALE_OAUTH_SECRET` | Tailscale Helm | From Tailscale Admin > Settings > OAuth Clients |
| `S3_ACCESS_KEY` | Backup Job | Your AWS/S3 provider credentials |
| `S3_SECRET_KEY` | Backup Job | Your AWS/S3 provider credentials |
| `FORGEJO_RUNNER_TOKEN` | Runner Helm | From Forgejo Site Admin > Actions > Runners |

### Secrets Management

**Recommended:**
1. Store secrets in a `.env` file locally (gitignored)
2. Use `source .env && terraform apply` or pass via `-var` flags
3. For K8s secrets, use `kubectl create secret` or store encrypted values in your config repo (e.g., Sealed Secrets)

**DO NOT commit:**
- `kube.tfvars` (contains Hetzner token)
- `.env` files
- Raw S3 credentials

---

## Troubleshooting

### K8s Cluster Won't Start

1. **Check Hetzner Cloud Console:** Is the node running? Has it rebooted?
2. **SSH to node:** `ssh root@<node-ip>`
3. **Check K3s status:** `systemctl status k3s`
4. **View logs:** `journalctl -u k3s -n 100`
5. **Terraform plan:** `terraform plan` to see if state is drift-prone

### Forgejo Pods Stuck in CrashLoopBackOff

```bash
# Check logs
kubectl logs -n forgejo -l app=forgejo --tail=50

# Common causes:
# - PVC not bound: kubectl get pvc -n forgejo
# - Database not initialized: Wait 2-3 mins after deployment
# - ConfigMap missing: Check Helm values in apps/forgejo.yaml
```

### Backup Job Failing

```bash
# Check the last backup pod
kubectl get pods -n forgejo -l job-name=forgejo-backup-s3 --sort-by=.metadata.creationTimestamp | tail -n 1

# View logs
kubectl logs <pod-name> -n forgejo --all-containers

# Common causes:
# - S3 credentials expired: Update secret
# - PVC name changed: Update apps/backup.yaml with correct claimName
# - S3 bucket doesn't exist: Create bucket manually
```

### Can't Access Forgejo via Tailscale

```bash
# 1. Verify Tailscale is running
tailscale status

# 2. Verify Ingress exists
kubectl get ingress -n forgejo

# 3. Check Tailscale Ingress controller logs
kubectl logs -n tailscale -l app=tailscale-operator --tail=50

# 4. Verify DNS (MagicDNS)
dig git-forge.ts
# Should resolve to a 100.x.y.z Tailscale IP

# 5. Clear local DNS cache (macOS)
sudo dscacheutil -flushcache
```

### Performance Issues

1. **Check node CPU/RAM:**
   ```bash
   kubectl top nodes
   kubectl top pods -A --sort-by=cpu | head -20
   ```

2. **If CPU-bound:** Consider upgrading node type in `kube.tfvars` (e.g., `cpx31`)
3. **If memory-bound:** Reduce pod requests, or add worker nodes

---

## Development Workflow

### Making Infrastructure Changes

```
1. Edit infra/kube.tfvars or Terraform files
2. Run: terraform plan -var-file=kube.tfvars
3. Review changes
4. Run: terraform apply -var-file=kube.tfvars
5. Verify: kubectl get nodes
```

### Making Application Changes

```
1. Edit apps/<app>.yaml in your config repo
2. Commit and push
3. Argo CD automatically syncs (check UI or kubectl)
4. Verify: kubectl get pods -n <app-namespace>
```

### Testing Locally Before Deploy

```bash
# Validate Helm chart (example for Forgejo)
helm template forgejo https://codeberg.org/forgejo/forgejo-helm \
  --version 9.0.0 \
  -f apps/forgejo-values.yaml \
  > /tmp/forgejo-rendered.yaml

# Then dry-run:
kubectl apply -f /tmp/forgejo-rendered.yaml --dry-run=client
```

---

## Important Gotchas & Best Practices

1. **MicroOS Reboots Automatically:** Don't panic when the node restarts. Btrfs snapshots rollback failed updates. Services come back up.

2. **Storage is Single Node:** If the Hetzner node dies permanently, you lose data unless your backup is up-to-date. Always verify backups are completing.

3. **Tailscale Network is Private:** You can optionally close all Hetzner Firewall ports for maximum security. Access via Tailscale only.

4. **Argo CD Config Repo is Critical:** Keep it in a private GitHub/Codeberg repo. This is your "Backup Brain"—if K8s dies, re-deploying Argo with this repo rebuilds everything.

5. **Use GitOps for Everything:** Commit changes to your config repo, let Argo sync. Don't manually `kubectl apply` (it defeats GitOps).

6. **Monitor Backups:** Use `python3 scripts/dashboard.py` daily. If backup is >24 hours old, investigate the CronJob logs immediately.

7. **Don't Skip Tailscale Updates:** Check your Tailscale admin console for any deprecations or security advisories related to the operator.

---

## Quick Reference: File Locations & URLs

| Item | Location | Access |
|------|----------|--------|
| **Terraform Config** | `infra/kube.tfvars` | Local file (gitignored) |
| **Argo CD UI** | `localhost:8080` (port-forward) | Secure private |
| **Forgejo** | `git-forge.tailnet-name.ts.net` | Tailscale VPN |
| **K8s API** | Via kubeconfig | Tailscale VPN |
| **Forgejo DB Backup** | S3 bucket | Off-site, encrypted |
| **Cluster Logs** | K8s cluster | `kubectl logs <pod>` |

---

## Further Reading

- **Terraform Module Docs:** See `terraform-hetzner-readme.md` (in this repo) - **AUTHORITATIVE** for current module interface (uses Talos OS, not MicroOS)
- **Hetzner Cloud Docs:** https://docs.hetzner.cloud/
- **K3s Docs:** https://docs.k3s.io/
- **Talos OS Docs:** https://www.talos.dev/ (modern immutable Kubernetes OS)
- **Forgejo Docs:** https://forgejo.org/docs/latest/
- **Argo CD Docs:** https://argo-cd.readthedocs.io/
- **Tailscale Operator:** https://tailscale.com/kb/1236/tailscale-operator

---

## Next Steps (After Initial Deployment)

1. **Secure Hetzner Firewall:** Close ports 22, 6443, 443, 80 if using Tailscale only
2. **Set Argo CD Sync Interval:** Configure in Argo UI (default is 3 mins, suitable for most cases)
3. **Enable Backup Verification:** Test restore process with a backup—don't assume it works
4. **Set Up Monitoring Alerts:** Forward CronJob failure notifications (e.g., via email or Slack)
5. **Document Your Tailscale Network:** Keep a private doc of DNS names, node IPs, etc.
6. **Rotate Credentials Periodically:** S3 keys, Hetzner tokens, Tailscale OAuth every 90 days

---

**Last Updated:** 2026-01-16
