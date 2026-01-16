# SOPS + Argo CD Setup Guide

This guide explains how to use SOPS to encrypt secrets in git and have Argo CD automatically decrypt them during deployment.

## Overview

**SOPS** (Secrets Operations) is a tool for encrypting structured data files. In this setup:

- **Encryption Keys**: Your Yubikey GPG key + Age key for Argo CD
- **Encrypted Files**: Stored in git (safe, auditable)
- **Decryption**: You use Yubikey, Argo CD uses age key automatically
- **Same File**: Both keys can decrypt the same encrypted file

### Key Advantages

✅ Secrets in git (full GitOps)
✅ Manual decryption with Yubikey (you can read anytime)
✅ Automatic decryption in cluster (Argo CD doesn't need human intervention)
✅ Encrypted at rest in git
✅ Full audit trail

## Prerequisites

1. **SOPS installed**: `brew install sops`
2. **Age installed**: `brew install age`
3. **Yubikey configured** with GPG (you already have this)
4. **kubectl connected** to your cluster
5. **Argo CD running** in cluster

## Setup Steps

### 1. Generate Age Key for Argo CD

```bash
./scripts/setup-sops-argocd.sh
```

This script will:
- Generate an age encryption key (stored locally in `age-argocd.key`)
- Update `.sops.yaml` with both your Yubikey and age key
- Create the SOPS secret in your cluster
- Patch Argo CD to use the age key

**Important**: Backup `age-argocd.key` somewhere safe. If your cluster is destroyed, you'll need this key to decrypt future secrets.

#### Optional: Backup Age Key Encrypted in Git

For extra security, you can encrypt the age key backup with your Yubikey and store it in git:

```bash
# Create encrypted backup of the age key
sops secrets/age-argocd.key.enc

# Paste the contents of age-argocd.key into the editor and save
# SOPS will encrypt it with your Yubikey

# Verify it's encrypted
cat secrets/age-argocd.key.enc  # Should be unreadable

# Verify you can decrypt with Yubikey
sops -d secrets/age-argocd.key.enc  # Should show plaintext

# Commit to git
git add secrets/age-argocd.key.enc
git commit -m "chore: backup encrypted age key for SOPS"
git push
```

Now if your cluster is destroyed, you can restore from git:
```bash
sops -d secrets/age-argocd.key.enc > age-argocd.key
chmod 600 age-argocd.key
kubectl create secret generic sops-age -n argocd \
    --from-file=keys.txt=age-argocd.key
```

### 2. Encrypt Your First Secret

Create the Tailscale secret with your OAuth credentials:

```bash
# Edit with SOPS (uses Yubikey for signing)
sops apps/tailscale-secret.yaml
```

SOPS will open your editor. Replace the placeholder values with your actual OAuth credentials:

```yaml
apiVersion: v1
kind: Secret
metadata:
    name: tailscale-oauth
    namespace: tailscale
type: Opaque
stringData:
    client_id: your_oauth_client_id_here
    client_secret: your_oauth_client_secret_here
```

When you save and exit, SOPS automatically encrypts the file.

### 3. Verify Encryption

```bash
# File should be encrypted (binary/unreadable)
cat apps/tailscale-secret.yaml

# Decrypt to verify (uses Yubikey)
sops -d apps/tailscale-secret.yaml
```

### 4. Commit to Git

```bash
git add apps/tailscale-secret.yaml .sops.yaml
git commit -m "chore: add encrypted Tailscale secret"
git push origin main
```

### 5. Argo CD Automatically Decrypts

When Argo CD syncs:
1. Pulls encrypted YAML from git
2. Uses mounted age key to decrypt
3. Applies plaintext secret to cluster
4. You never see the secret plaintext in git

## Using SOPS

### Edit an Encrypted Secret

```bash
# Edit with Yubikey (automatic with your existing setup)
sops apps/tailscale-secret.yaml
```

### View Decrypted Secret

```bash
sops -d apps/tailscale-secret.yaml
```

### Rotate Age Key (Advanced)

If you want to change the age key:

```bash
# Generate new age key
age-keygen > age-argocd-new.key

# Re-encrypt all files with new key
sops updatekeys apps/*-secret.yaml

# Update cluster secret
kubectl create secret generic sops-age \
    -n argocd \
    --from-file=keys.txt="age-argocd-new.key" \
    --dry-run=client -o yaml | kubectl apply -f -

# Delete old key
rm age-argocd.key
mv age-argocd-new.key age-argocd.key
```

## Creating More Encrypted Secrets

For any new secret file you want to encrypt:

1. Create the YAML file with placeholders
2. Edit with SOPS: `sops apps/my-secret.yaml`
3. SOPS will automatically detect `.sops.yaml` config
4. Commit encrypted file to git

**Convention**: Name secret files as `*-secret.yaml` so they match the encryption rule in `.sops.yaml`.

## Troubleshooting

### "Key not found" error when decrypting

```bash
# Make sure Yubikey is connected
gpg --card-status

# Re-import key if needed
gpg --import <(gpg --export YOUR_KEY_ID)
```

### Argo CD can't decrypt (pod logs show errors)

```bash
# Check age secret exists
kubectl get secret sops-age -n argocd

# Check repo-server pod has volume mount
kubectl describe pod -n argocd -l app.kubernetes.io/name=argocd-repo-server

# Check repo-server logs
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-repo-server
```

### SOPS hangs or asks for passphrase

Make sure Yubikey is connected and GPG is configured:

```bash
gpg --card-status
```

## File Permissions

⚠️ **Important**: Add these to `.gitignore` (should already be):

```
age-*.key
gpg-home/
```

These files should NOT be committed to git.

## Architecture

```
Your Machine (with Yubikey)
    ↓
Edit encrypted secret: sops apps/tailscale-secret.yaml
    ↓
Git: encrypted YAML committed
    ↓
Argo CD: pulls encrypted file
    ↓
Argo CD repo-server: uses age key to decrypt
    ↓
Cluster: plaintext secret applied
    ↓
(Your Yubikey never needed in cluster)
```

## Security Notes

- ✅ Age key in cluster is read-only secret
- ✅ Yubikey private key never leaves Yubikey
- ✅ Secrets encrypted in git
- ✅ Both keys needed for maximum trust (you verify, Argo CD automates)
- ⚠️  Age key is the weak point - keep it safe

## Next Steps

1. Run setup script: `./scripts/setup-sops-argocd.sh`
2. Encrypt Tailscale secret: `sops apps/tailscale-secret.yaml`
3. Commit to git: `git push`
4. Apply Tailscale: `kubectl apply -f apps/forgejo-tailscale-ingress.yaml`

All done! Your secrets are now encrypted but Argo CD can still use them automatically.
