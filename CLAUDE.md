# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

---

## Overview

This repository contains infrastructure-as-code and deployment configuration for "Ironclad" - a self-hosted, private Kubernetes stack on Hetzner Cloud. It deploys:
- **Kubernetes cluster** on a single Hetzner Cloud node (Talos OS for immutable, auto-updating infrastructure)
- **Forgejo** (private Git server)
- **Forgejo Runners** (self-hosted CI/CD like GitHub Actions)
- **Argo CD** (GitOps configuration management with SOPS/KSOPS for encrypted secrets)
- **Tailscale** (private VPN mesh for secure access)
- **Automated S3 backups** of critical data

**Philosophy:** Infrastructure as Code (Terraform), GitOps (Argo CD), secure private networking (Tailscale), encrypted secrets in git (SOPS).

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
| **Configuration** | Argo CD + KSOPS | GitOps with automatic SOPS decryption |
| **Secrets** | SOPS + Age + Yubikey | Dual-key encryption (manual + automatic) |
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
        ↓                    ↓
Forgejo Runners      KSOPS decrypts secrets
(Docker builds)      using age key
        ↓
CronJob (Daily) → Backup to S3
```

### Critical Design Decisions

1. **Single Node** (not HA): Cheaper, simpler, sufficient for private infrastructure. Data persists via Hetzner Volumes.
2. **No Public Ports**: All access via Tailscale private VPN. SSH, API, Forgejo only accessible from your tailnet.
3. **Talos Auto-Updates**: Node reboots automatically, survives boot failures. Zero manual OS patching.
4. **GitOps Only (Argo CD)**: Config lives in this repo. If K8s dies, re-apply Argo CD and it rebuilds itself. **NEVER use `kubectl apply` directly** - it breaks GitOps.
5. **SOPS Dual-Key**: Yubikey for manual decryption, age key for automatic Argo CD decryption.

---

## Repository Structure

```
.
├── CLAUDE.md                      # This file - AI guidance
├── README.md                      # Full reference guide
├── QUICKSTART.md                  # 30-minute setup walkthrough
├── SETUP.md                       # Detailed setup phases
├── SOPS.md                        # SOPS encryption guide
├── .sops.yaml                     # SOPS encryption configuration
│
├── infra/                         # Terraform infrastructure
│   ├── main.tf                    # Talos K8s cluster on Hetzner
│   ├── variables.tf               # Input parameters
│   ├── outputs.tf                 # Cluster outputs (kubeconfig, etc.)
│   ├── backend.tf                 # State configuration
│   └── kube.tfvars.example        # Configuration template
│
├── argocd/                        # Argo CD GitOps configuration
│   ├── app-of-apps.yaml           # Root application (auto-discovers children)
│   ├── applications/              # Individual app manifests
│   │   ├── forgejo.yaml           # Forgejo Helm Application
│   │   ├── runner.yaml            # Forgejo Runner Application
│   │   ├── backup-resources.yaml  # Backup CronJob
│   │   ├── tailscale-operator.yaml# Tailscale VPN operator
│   │   ├── tailscale-oauth-secret.yaml      # Encrypted OAuth credentials
│   │   ├── s3-backup-credentials-secret.yaml# Encrypted S3 credentials
│   │   └── argocd-config.yaml     # Argo CD self-management
│   ├── config/                    # Argo CD configuration patches
│   │   ├── kustomization.yaml     # KSOPS patches for repo-server
│   │   └── patches/
│   │       └── repo-server-deployment.yaml
│   ├── install/                   # Argo CD installation Kustomization
│   │   ├── kustomization.yaml
│   │   └── patches/
│   └── resources/                 # Kustomize bases for secrets
│       └── tailscale-secrets/
│
├── apps/                          # Standalone app manifests
│   ├── forgejo.yaml
│   ├── runner.yaml
│   ├── backup.yaml
│   └── tailscale-secret.yaml      # Encrypted
│
├── kustomize/                     # Kustomize bases
│   └── tailscale/
│       └── tailscale-oauth-secret.yaml  # Encrypted
│
├── secrets/                       # Encrypted secrets storage
│   └── age-argocd.key.enc         # Age key backup (encrypted with Yubikey)
│
├── scripts/                       # Automation scripts
│   ├── setup-argocd.sh            # Main setup script (installs everything)
│   ├── setup-sops-argocd.sh       # SOPS initialization
│   ├── setup-tailscale.sh         # Tailscale setup
│   ├── control.sh                 # Cluster CLI (status, UI, backup)
│   ├── dashboard.py               # Python status dashboard
│   └── get-latest-docs.sh         # Download reference docs
│
├── docs/                          # Reference documentation (gitignored, downloaded)
│   ├── terraform-hetzner-readme.md
│   ├── forgejo-helm-README.md
│   └── kustomize-sops-README.md
│
└── .gitignore                     # Excludes secrets, state files
```

---

## Secrets Management (SOPS)

### Overview

Secrets are encrypted with SOPS using a **dual-key system**:
- **Yubikey (PGP)**: For manual decryption/editing by operators
- **Age key**: For automatic decryption by Argo CD in the cluster

### Key Locations

| Key | Location | Purpose |
|-----|----------|---------|
| **Age Public Key** | `.sops.yaml` | `age19lq4dtrxd5qdwkr63gpy2qfwnttu3nxlrp9rxmu659nkt4d8ld7skwj6x9` |
| **Age Private Key (encrypted)** | `secrets/age-argocd.key.enc` | Backup, encrypted with Yubikey |
| **Age Private Key (cluster)** | K8s Secret `sops-age` in `argocd` namespace | Used by KSOPS |
| **Yubikey Fingerprints** | `.sops.yaml` | PGP keys for manual decryption |

### Encrypted Secret Files

| File | Secret Name | Purpose |
|------|-------------|---------|
| `apps/tailscale-secret.yaml` | `tailscale-oauth` | Tailscale OAuth credentials |
| `argocd/applications/tailscale-oauth-secret.yaml` | `operator-oauth` | Tailscale operator |
| `argocd/applications/s3-backup-credentials-secret.yaml` | `s3-backup-credentials` | S3 backup auth |
| `kustomize/tailscale/tailscale-oauth-secret.yaml` | `tailscale-oauth` | Kustomize variant |

### Working with Encrypted Secrets

```bash
# Edit an encrypted secret (requires Yubikey)
sops argocd/applications/tailscale-oauth-secret.yaml

# View decrypted content
sops -d argocd/applications/tailscale-oauth-secret.yaml

# Create new encrypted secret
sops -e plaintext-secret.yaml > encrypted-secret.yaml

# Encrypt in place
sops -e -i my-secret.yaml
```

### SOPS Configuration (.sops.yaml)

```yaml
creation_rules:
  - path_regex: '^(apps/.*-secret|kustomize/.*/.*-secret|argocd/applications/.*-secret)\.yaml$'
    key_groups:
      - age:
          - age19lq4dtrxd5qdwkr63gpy2qfwnttu3nxlrp9rxmu659nkt4d8ld7skwj6x9
        pgp:
          - 528CFD6EA653B5EC59B701F483219063F9FC4626  # Yubikey 1
          - EE213327AA06F51445BE63B5B4324BD440FD54E3  # Yubikey 2
    unencrypted_regex: "^(apiVersion|metadata|kind|type|namespace|name)$"
```

---

## Setup & Deployment

### Quick Start

```bash
# 1. Deploy Terraform infrastructure
cd infra
cp kube.tfvars.example kube.tfvars  # Edit with your Hetzner token
terraform init && terraform apply -var-file=kube.tfvars
terraform output -raw kubeconfig > ~/.kube/config

# 2. Setup Argo CD with SOPS (requires Yubikey for age key decryption)
./scripts/setup-argocd.sh

# 3. Access Argo CD
kubectl port-forward svc/argocd-server -n argocd 8080:443
# Open https://localhost:8080
```

### What setup-argocd.sh Does

1. Installs Argo CD from upstream manifests
2. Decrypts age key from `secrets/age-argocd.key.enc` (requires Yubikey)
3. Creates `sops-age` K8s secret for KSOPS
4. Patches repo-server with KSOPS plugin (viaductoss/ksops:v4.4.0)
5. Configures kustomize alpha plugins
6. Applies `app-of-apps.yaml` to bootstrap GitOps

### Emergency Manual Steps (Cluster Recovery ONLY)

**Use ONLY for disaster recovery when Argo CD is not working. Normal operations use GitOps above.**

```bash
# EMERGENCY: Create age secret when Argo CD pod can't decrypt
sops -d secrets/age-argocd.key.enc > /tmp/age.key
kubectl create secret generic sops-age -n argocd --from-file=keys.txt=/tmp/age.key
rm /tmp/age.key

# EMERGENCY: After Argo CD is ready, git push will sync everything else
# DO NOT use kubectl apply for normal operations
```

---

## Common Commands & Workflows

### Cluster Operations

```bash
# Status dashboard
./scripts/control.sh status

# Access Argo CD UI
./scripts/control.sh ui-argo
# Or manually:
kubectl port-forward svc/argocd-server -n argocd 8080:443

# Get Argo CD admin password
kubectl get secret -n argocd argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d

# Watch applications
kubectl get applications -n argocd -w

# Trigger manual backup
./scripts/control.sh backup-now

# View all pods
./scripts/control.sh pods
```

### GitOps Workflow (ONLY WAY TO CHANGE CONFIG)

```bash
# 1. Edit application manifest
vim argocd/applications/forgejo.yaml

# 2. Commit and push
git add . && git commit -m "Update Forgejo config" && git push

# 3. Argo CD auto-syncs within ~3 minutes
kubectl get applications -n argocd
```

**DO NOT use `kubectl apply`** - it breaks GitOps. If you use `kubectl apply`, Argo CD will detect a diff and constantly resync, and the next git commit will overwrite your manual changes.

### Updating Encrypted Secrets

```bash
# 1. Edit with Yubikey (SOPS auto-decrypts/re-encrypts)
sops argocd/applications/tailscale-oauth-secret.yaml

# 2. Commit
git add . && git commit -m "Update Tailscale credentials" && git push

# 3. KSOPS automatically decrypts during Argo CD sync
```

---

## Troubleshooting

### KSOPS Not Decrypting Secrets

```bash
# Check repo-server has KSOPS
kubectl exec -n argocd deployment/argocd-repo-server -- ls -la /usr/local/bin/ksops

# Check age secret exists
kubectl get secret sops-age -n argocd

# Check repo-server logs
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-repo-server --tail=100
```

### Secret Shows ENC[...] in Cluster

This means KSOPS didn't decrypt. Check:
1. `sops-age` secret exists in argocd namespace
2. repo-server has KSOPS volume mounts
3. AGE_KEYFILE environment variable is set
4. kustomize.buildOptions includes `--enable-alpha-plugins`

```bash
# Verify repo-server configuration
kubectl describe deployment argocd-repo-server -n argocd | grep -A5 "Environment"
kubectl describe deployment argocd-repo-server -n argocd | grep -A10 "Volumes"
```

### Argo CD Application Stuck

```bash
# Force sync
kubectl patch application <app-name> -n argocd --type=merge -p '{"operation":{"sync":{"force":true}}}'

# Check sync status
kubectl get application <app-name> -n argocd -o yaml | yq '.status'
```

### Can't Decrypt with Yubikey

```bash
# Ensure Yubikey is connected
gpg --card-status

# Re-import keys if needed
gpg --import <(gpg --export YOUR_KEY_ID)
```

---

## File Reference

### Critical Files

| File | Purpose |
|------|---------|
| `.sops.yaml` | SOPS encryption rules (age + PGP keys) |
| `secrets/age-argocd.key.enc` | Encrypted backup of cluster age key |
| `argocd/app-of-apps.yaml` | Root application for GitOps |
| `scripts/setup-argocd.sh` | Main setup script |
| `argocd/config/kustomization.yaml` | KSOPS patches for Argo CD |

### Application Manifests

| File | Deploys |
|------|---------|
| `argocd/applications/forgejo.yaml` | Forgejo Git server |
| `argocd/applications/runner.yaml` | Forgejo CI/CD runners |
| `argocd/applications/tailscale-operator.yaml` | Tailscale VPN operator |
| `argocd/applications/backup-resources.yaml` | S3 backup CronJob |

### Encrypted Secrets

| File | Contains |
|------|----------|
| `argocd/applications/tailscale-oauth-secret.yaml` | Tailscale OAuth client_id/secret |
| `argocd/applications/s3-backup-credentials-secret.yaml` | S3 access-key/secret-key |
| `apps/tailscale-secret.yaml` | Tailscale OAuth credentials |

---

## Environment Variables

| Variable | Where Used | Example |
|----------|-----------|---------|
| `HCLOUD_TOKEN` | Terraform | From Hetzner Cloud Console |
| `TAILSCALE_OAUTH_ID` | Encrypted in git | Set via sops |
| `TAILSCALE_OAUTH_SECRET` | Encrypted in git | Set via sops |
| `S3_ACCESS_KEY` | Encrypted in git | Set via sops |
| `S3_SECRET_KEY` | Encrypted in git | Set via sops |

---

## Security Notes

1. **Age key is the automation weak point** - Keep `secrets/age-argocd.key.enc` backup safe
2. **Yubikey private key never leaves Yubikey** - Only public key in `.sops.yaml`
3. **All secrets encrypted in git** - Full audit trail, safe to commit
4. **No public ports** - All access via Tailscale VPN
5. **Rotate credentials periodically** - Use `sops updatekeys` for age key rotation

---

## GitOps Philosophy & Anti-Patterns

### The Rule: Git is the Source of Truth

All cluster state must be in git. The workflow is:

```
Edit local file → git commit → git push → Argo CD syncs
```

### Anti-Pattern: Direct kubectl apply

❌ **DO NOT DO THIS:**
```bash
kubectl apply -f argocd/applications/forgejo.yaml
kubectl patch deployment forgejo -n forgejo --patch='...'
kubectl set image deployment/forgejo ...
```

**Why?** This breaks GitOps:
1. Cluster state no longer matches git
2. Argo CD detects a diff and constantly tries to fix it (thrashing)
3. Next `git push` overwrites your manual changes
4. No audit trail - who changed what, and when?
5. Disaster recovery fails: if cluster dies, git doesn't have the fix

✅ **DO THIS INSTEAD:**
1. Edit the file in git
2. `git commit` with a meaningful message
3. `git push`
4. Argo CD syncs automatically (watch: `kubectl get applications -n argocd -w`)

This ensures:
- Full audit trail in git
- Reproducible deployments
- Easy rollback with `git revert`
- Disaster recovery from git alone

### When Manual kubectl is Allowed

Only during **initial cluster setup** or **disaster recovery**:
1. `scripts/setup-argocd.sh` - bootstraps Argo CD itself
2. Emergency age key creation when Argo CD can't decrypt (see "Emergency Manual Steps")

After that, **always use git**.

---

## Further Reading

- **Terraform Module:** See `docs/terraform-hetzner-readme.md` for Talos/Hetzner config
- **SOPS Guide:** See `SOPS.md` for detailed encryption workflow
- **Argo CD:** https://argo-cd.readthedocs.io/
- **KSOPS:** https://github.com/viaduct-ai/kustomize-sops
- **Tailscale Setup Guide:** See `docs/TAILSCALE.md` for detailed operator setup
- **Tailscale Operator:** https://tailscale.com/kb/1236/tailscale-operator
- **Talos OS:** https://www.talos.dev/

---

**Last Updated:** 2026-01-16 - Added GitOps anti-patterns section
