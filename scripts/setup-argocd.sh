#!/bin/bash
#
# Setup Argo CD with SOPS/KSOPS for encrypted secrets management
#
# This script:
# 1. Decrypts age key from repo (requires Yubikey)
# 2. Creates sops-age secret in cluster
# 3. Installs Argo CD with KSOPS support via kustomize
# 4. Bootstraps app-of-apps from git
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

# Step 1: Create namespace and decrypt age key
echo -e "${YELLOW}Step 1: Creating namespace and sops-age secret...${NC}"
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -

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

# Step 2: Install Argo CD with KSOPS support using kustomize
echo -e "${YELLOW}Step 2: Installing Argo CD with KSOPS support...${NC}"

# Build and apply Argo CD with KSOPS patches from shared configuration
kustomize build "$REPO_ROOT/argocd/install" | kubectl apply -f -

# Wait for Argo CD to be ready
echo -e "${YELLOW}Waiting for Argo CD pods to be ready...${NC}"
kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n argocd || true
kubectl wait --for=condition=available --timeout=300s deployment/argocd-repo-server -n argocd || true

echo -e "${GREEN}✓ Argo CD installed with KSOPS${NC}\n"

# Step 3: Create GitHub repository secret (if needed)
echo -e "${YELLOW}Step 3: Setting up GitHub repository credentials...${NC}"

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

# Step 4: Bootstrap Argo CD from git
echo -e "${YELLOW}Step 4: Bootstrapping Argo CD from git repository...${NC}"

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

# Step 5: Display status
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
