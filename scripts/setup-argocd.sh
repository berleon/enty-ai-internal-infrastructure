#!/bin/bash
#
# Setup Argo CD with SOPS/KSOPS for encrypted secrets management
#
# This script:
# 1. Installs Argo CD from upstream manifests
# 2. Decrypts age key from repo (requires Yubikey)
# 3. Creates sops-age secret in cluster
# 4. Patches repo-server with KSOPS support
# 5. Configures kustomize plugins
# 6. Bootstraps app-of-apps from git
#
# Usage: ./scripts/setup-argocd.sh
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Colors for output
BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Setting up Argo CD with SOPS/KSOPS${NC}"
echo -e "${BLUE}========================================${NC}\n"

# Step 1: Install Argo CD
echo -e "${YELLOW}Step 1: Installing Argo CD...${NC}"
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -

# Apply upstream Argo CD manifests
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Wait for Argo CD to be ready
echo -e "${YELLOW}Waiting for Argo CD pods to be ready...${NC}"
kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n argocd || true
kubectl wait --for=condition=available --timeout=300s deployment/argocd-repo-server -n argocd || true

echo -e "${GREEN}✓ Argo CD installed${NC}\n"

# Step 2: Decrypt age key from repo and create secret
echo -e "${YELLOW}Step 2: Creating sops-age secret from encrypted key in repo...${NC}"

AGE_KEY_ENCRYPTED="$REPO_ROOT/secrets/age-argocd.key.enc"

if [ ! -f "$AGE_KEY_ENCRYPTED" ]; then
    echo -e "${RED}✗ Encrypted age key not found at: $AGE_KEY_ENCRYPTED${NC}"
    echo -e "${YELLOW}Please ensure secrets/age-argocd.key.enc exists${NC}"
    exit 1
fi

# Decrypt age key using sops (requires Yubikey)
echo -e "${YELLOW}Decrypting age key (requires Yubikey)...${NC}"
TEMP_AGE_KEY=$(mktemp)
trap "rm -f $TEMP_AGE_KEY" EXIT

sops -d "$AGE_KEY_ENCRYPTED" > "$TEMP_AGE_KEY"

if [ ! -s "$TEMP_AGE_KEY" ]; then
    echo -e "${RED}✗ Failed to decrypt age key${NC}"
    exit 1
fi

# Create the secret from decrypted age key
kubectl create secret generic sops-age \
    --from-file=keys.txt="$TEMP_AGE_KEY" \
    -n argocd \
    --dry-run=client -o yaml | kubectl apply -f -

echo -e "${GREEN}✓ sops-age secret created${NC}\n"

# Step 3: Patch repo-server to install KSOPS
echo -e "${YELLOW}Step 3: Patching repo-server for KSOPS support...${NC}"

# Check if patches already exist (avoid duplicates)
EXISTING_VOLUMES=$(kubectl get deployment argocd-repo-server -n argocd -o jsonpath='{.spec.template.spec.volumes[*].name}' 2>/dev/null || echo "")

if [[ "$EXISTING_VOLUMES" == *"custom-tools"* ]]; then
    echo -e "${YELLOW}KSOPS patches already applied, skipping...${NC}"
else
    # Add the KSOPS init container and volume patches
    kubectl patch deployment argocd-repo-server -n argocd --type='json' -p='[
      {
        "op": "add",
        "path": "/spec/template/spec/volumes/-",
        "value": {
          "name": "custom-tools",
          "emptyDir": {}
        }
      },
      {
        "op": "add",
        "path": "/spec/template/spec/volumes/-",
        "value": {
          "name": "sops-age",
          "secret": {
            "secretName": "sops-age",
            "defaultMode": 292
          }
        }
      },
      {
        "op": "add",
        "path": "/spec/template/spec/initContainers/-",
        "value": {
          "name": "install-ksops",
          "image": "alpine:3.19",
          "command": ["/bin/sh", "-c"],
          "args": ["set -e; ARCH=$(uname -m); case $ARCH in x86_64) KSOPS_ARCH=x86_64; KUST_ARCH=amd64 ;; aarch64) KSOPS_ARCH=arm64; KUST_ARCH=arm64 ;; *) echo Unsupported: $ARCH; exit 1 ;; esac; echo Installing KSOPS/Kustomize for $ARCH...; wget -qO- https://github.com/viaduct-ai/kustomize-sops/releases/download/v4.4.0/ksops_4.4.0_Linux_${KSOPS_ARCH}.tar.gz | tar xz -C /custom-tools; wget -qO- https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2Fv5.4.1/kustomize_v5.4.1_linux_${KUST_ARCH}.tar.gz | tar xz -C /custom-tools; chmod +x /custom-tools/ksops /custom-tools/kustomize; echo Done."],
          "volumeMounts": [
            {
              "mountPath": "/custom-tools",
              "name": "custom-tools"
            }
          ]
        }
      },
      {
        "op": "add",
        "path": "/spec/template/spec/containers/0/env/-",
        "value": {
          "name": "AGE_KEYFILE",
          "value": "/.config/sops/age/keys.txt"
        }
      },
      {
        "op": "add",
        "path": "/spec/template/spec/containers/0/volumeMounts/-",
        "value": {
          "mountPath": "/usr/local/bin/kustomize",
          "name": "custom-tools",
          "subPath": "kustomize"
        }
      },
      {
        "op": "add",
        "path": "/spec/template/spec/containers/0/volumeMounts/-",
        "value": {
          "mountPath": "/usr/local/bin/ksops",
          "name": "custom-tools",
          "subPath": "ksops"
        }
      },
      {
        "op": "add",
        "path": "/spec/template/spec/containers/0/volumeMounts/-",
        "value": {
          "mountPath": "/.config/sops/age",
          "name": "sops-age"
        }
      }
    ]'
fi

echo -e "${YELLOW}Waiting for repo-server to restart with KSOPS...${NC}"
kubectl rollout restart deployment/argocd-repo-server -n argocd
kubectl wait --for=condition=available --timeout=300s deployment/argocd-repo-server -n argocd || true

echo -e "${GREEN}✓ repo-server patched with KSOPS${NC}\n"

# Step 4: Enable kustomize plugins in Argo CD config
echo -e "${YELLOW}Step 4: Configuring Argo CD for kustomize plugins...${NC}"

# Note: kustomize.version causes a parsing bug in Argo CD 3.2.5, so we only set buildOptions
kubectl patch configmap argocd-cm -n argocd --type merge -p '{"data":{"kustomize.buildOptions":"--enable-alpha-plugins --enable-exec"}}' || true

echo -e "${GREEN}✓ Argo CD configuration updated${NC}\n"

# Step 5: Create GitHub repository secret (if needed)
echo -e "${YELLOW}Step 5: Setting up GitHub repository credentials...${NC}"

# Check if secret already exists
if kubectl get secret github-credentials -n argocd &>/dev/null; then
    echo -e "${YELLOW}GitHub credentials secret already exists, skipping...${NC}"
else
    echo -e "${YELLOW}Creating GitHub credentials secret...${NC}"

    # Check if github-credentials-secret.yaml exists and is encrypted
    GITHUB_SECRET_FILE="$REPO_ROOT/argocd/applications/github-credentials-secret.yaml"

    if [ -f "$GITHUB_SECRET_FILE" ]; then
        echo -e "${YELLOW}Decrypting and applying github-credentials-secret.yaml...${NC}"
        sops -d "$GITHUB_SECRET_FILE" | kubectl apply -f -
        echo -e "${GREEN}✓ GitHub credentials applied from encrypted file${NC}"
    else
        echo -e "${YELLOW}No encrypted github-credentials-secret.yaml found.${NC}"
        echo -e "${YELLOW}You may need to create one if your repo is private.${NC}"
        echo ""
        echo "To create encrypted GitHub credentials:"
        echo "  1. Create argocd/applications/github-credentials-secret.yaml with your token"
        echo "  2. Encrypt: sops -e -i argocd/applications/github-credentials-secret.yaml"
        echo "  3. Re-run this script"
    fi
fi
echo ""

# Step 6: Bootstrap Argo CD from git
echo -e "${YELLOW}Step 6: Bootstrapping Argo CD from git repository...${NC}"

# Apply the app-of-apps
kubectl apply -f "$REPO_ROOT/argocd/app-of-apps.yaml"

echo -e "${YELLOW}Waiting for app-of-apps to sync...${NC}"
sleep 10

# Check application status
for i in {1..30}; do
    HEALTH=$(kubectl get application app-of-apps -n argocd -o jsonpath='{.status.health.status}' 2>/dev/null || echo "Unknown")
    SYNC=$(kubectl get application app-of-apps -n argocd -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "Unknown")

    if [ "$HEALTH" = "Healthy" ] && [ "$SYNC" = "Synced" ]; then
        echo -e "${GREEN}✓ app-of-apps is Healthy and Synced${NC}"
        break
    fi

    echo "  Status: Health=$HEALTH, Sync=$SYNC ($i/30)"
    sleep 5
done

echo ""

# Step 7: Display status
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Setup Complete!${NC}"
echo -e "${BLUE}========================================${NC}\n"

echo -e "${GREEN}Argo CD Pods:${NC}"
kubectl get pods -n argocd

echo -e "\n${GREEN}Applications:${NC}"
kubectl get applications -n argocd 2>/dev/null || echo "No applications yet"

echo -e "\n${YELLOW}Access Argo CD:${NC}"
echo "  kubectl port-forward svc/argocd-server -n argocd 8080:443"
echo "  Then open: https://localhost:8080"

echo -e "\n${YELLOW}Get admin password:${NC}"
echo "  kubectl get secret -n argocd argocd-initial-admin-secret -o jsonpath=\"{.data.password}\" | base64 -d && echo"

echo -e "\n${YELLOW}Monitor applications:${NC}"
echo "  kubectl get applications -n argocd -w"
echo "  ./scripts/control.sh status"

echo -e "\n${GREEN}✓ Done!${NC}\n"
