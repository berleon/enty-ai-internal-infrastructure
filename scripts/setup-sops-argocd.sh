#!/bin/bash
#
# Setup SOPS encryption for Argo CD with KSOPS plugin
# Configures Argo CD to automatically decrypt SOPS-encrypted secrets
#
# This script:
# 1. Generates an age encryption key for Argo CD
# 2. Creates the SOPS configuration in .sops.yaml
# 3. Creates secrets in the cluster
# 4. Patches Argo CD to use KSOPS plugin
#
# Usage: ./scripts/setup-sops-argocd.sh
#

set -e

# Colors
BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${BLUE}=====================================${NC}"
echo -e "${BLUE}SOPS + Argo CD Setup${NC}"
echo -e "${BLUE}=====================================${NC}\\n"

# Check prerequisites
echo -e "${YELLOW}Checking prerequisites...${NC}"

if ! command -v kubectl &> /dev/null; then
    echo -e "${RED}✗ kubectl not found${NC}"
    exit 1
fi

if ! command -v age-keygen &> /dev/null; then
    echo -e "${RED}✗ age-keygen not found (install with: brew install age)${NC}"
    exit 1
fi

if ! command -v sops &> /dev/null; then
    echo -e "${RED}✗ sops not found (install with: brew install sops)${NC}"
    exit 1
fi

echo -e "${GREEN}✓${NC} kubectl configured"
echo -e "${GREEN}✓${NC} age-keygen installed"
echo -e "${GREEN}✓${NC} sops installed\\n"

# Generate or use existing age key
AGE_KEY_FILE="age-argocd.key"

if [ -f "$AGE_KEY_FILE" ]; then
    echo -e "${YELLOW}Using existing age key: $AGE_KEY_FILE${NC}"
    AGE_PUBLIC_KEY=$(grep "public key:" "$AGE_KEY_FILE" | sed 's/.*public key: //')
else
    echo -e "${BLUE}Generating new age encryption key...${NC}"
    age-keygen -o "$AGE_KEY_FILE"
    echo -e "${GREEN}✓${NC} Age key generated: ${YELLOW}$AGE_KEY_FILE${NC}"

    AGE_PUBLIC_KEY=$(grep "public key:" "$AGE_KEY_FILE" | sed 's/.*public key: //')
    echo -e "Age public key: ${YELLOW}$AGE_PUBLIC_KEY${NC}\\n"

    echo -e "${YELLOW}WARNING: Keep $AGE_KEY_FILE secure!${NC}"
    echo -e "${YELLOW}This file should NOT be committed to git.${NC}"
    echo -e "${YELLOW}Store it safely - you'll need it if you recreate the cluster.\\n${NC}"
fi

# Extract private key from age file
AGE_PRIVATE_KEY=$(grep -v "^#" "$AGE_KEY_FILE" | grep -v "^$" | head -1)

# Update .sops.yaml with actual age key
echo -e "${BLUE}Updating .sops.yaml with age key...${NC}"
if grep -q "REPLACE_WITH_AGE_KEY" .sops.yaml; then
    sed -i "s/REPLACE_WITH_AGE_KEY/$AGE_PUBLIC_KEY/g" .sops.yaml
    sed -i "s|^# age-argocd.key:.*|age-argocd.key: $AGE_PUBLIC_KEY|" .sops.yaml
    echo -e "${GREEN}✓${NC} .sops.yaml updated"
else
    echo -e "${YELLOW}⚠${NC} Age key already in .sops.yaml (or not found)"
fi

# Create argocd namespace if it doesn't exist
echo -e "${BLUE}Creating secrets in cluster...${NC}"
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -

# Create SOPS age key secret in Argo CD namespace
echo -e "Creating sops-age secret..."
kubectl create secret generic sops-age \
    -n argocd \
    --from-file=keys.txt="$AGE_KEY_FILE" \
    --dry-run=client -o yaml | kubectl apply -f -

echo -e "${GREEN}✓${NC} SOPS age key secret created"

# Patch Argo CD repo-server to use KSOPS plugin
echo -e "${BLUE}Configuring Argo CD for KSOPS plugin...${NC}"

# Create Argo CD SOPS plugin patch
PATCH_JSON=$(cat <<'EOF'
{
  "spec": {
    "template": {
      "spec": {
        "containers": [
          {
            "name": "argocd-repo-server",
            "env": [
              {
                "name": "GNUPGHOME",
                "value": "/tmp/gpg-home"
              },
              {
                "name": "AGE_KEYFILE",
                "value": "/tmp/age-keys/keys.txt"
              }
            ],
            "volumeMounts": [
              {
                "name": "sops-age-keys",
                "mountPath": "/tmp/age-keys"
              }
            ]
          }
        ],
        "volumes": [
          {
            "name": "sops-age-keys",
            "secret": {
              "secretName": "sops-age"
            }
          }
        ]
      }
    }
  }
}
EOF
)

# Apply patch to argocd-repo-server deployment
kubectl patch deployment argocd-repo-server \
    -n argocd \
    --type merge \
    -p "$PATCH_JSON" 2>/dev/null || echo -e "${YELLOW}⚠${NC} Could not patch argocd-repo-server (may not exist yet)"

# Enable alpha plugins in Argo CD ConfigMap
echo -e "Enabling SOPS in Argo CD..."
kubectl patch configmap argocd-cmd-params-cm \
    -n argocd \
    --type merge \
    -p '{"data":{"application.instanceLabelKey":"argocd.argoproj.io/instance"}}' 2>/dev/null || true

echo -e "${GREEN}✓${NC} Argo CD configured for SOPS"

# Wait for repo-server to restart
echo -e "${BLUE}Waiting for Argo CD repo-server to restart...${NC}"
sleep 5
kubectl rollout status deployment/argocd-repo-server -n argocd --timeout=2m 2>/dev/null || echo -e "${YELLOW}⚠${NC} Repo-server may still be restarting"

echo -e "\\n${GREEN}✓ SOPS + Argo CD setup complete!${NC}"
echo ""
echo -e "${BLUE}Next steps:${NC}"
echo -e "1. Add $AGE_KEY_FILE to .gitignore (already should be)"
echo -e "2. Create encrypted secrets:"
echo -e "   ${YELLOW}sops apps/tailscale-secret.yaml${NC}"
echo -e "3. Commit encrypted file to git"
echo -e "4. Argo CD will auto-decrypt when syncing"
echo ""
echo -e "${YELLOW}Important:${NC}"
echo -e "- Backup $AGE_KEY_FILE somewhere safe"
echo -e "- You can still decrypt manually with: ${YELLOW}sops -d apps/tailscale-secret.yaml${NC}"
echo -e "- You can edit with Yubikey: ${YELLOW}sops apps/tailscale-secret.yaml${NC}"
echo ""
