#!/bin/bash
#
# Setup Tailscale Kubernetes Operator
# Configures Tailscale integration for secure cluster access
#
# Usage: ./scripts/setup-tailscale.sh
#
# Requires:
# - kubectl configured and connected to cluster
# - helm installed
# - Tailscale OAuth credentials (you'll be prompted)
#

set -e

# Colors for output
BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${BLUE}=====================================${NC}"
echo -e "${BLUE}Tailscale Kubernetes Operator Setup${NC}"
echo -e "${BLUE}=====================================${NC}\\n"

# Check prerequisites
echo -e "${YELLOW}Checking prerequisites...${NC}"

if ! command -v kubectl &> /dev/null; then
    echo -e "${RED}✗ kubectl not found${NC}"
    exit 1
fi

if ! command -v helm &> /dev/null; then
    echo -e "${RED}✗ helm not found${NC}"
    exit 1
fi

echo -e "${GREEN}✓${NC} kubectl configured"
echo -e "${GREEN}✓${NC} helm installed\\n"

# Prompt for credentials
echo -e "${YELLOW}Tailscale Credentials${NC}"
echo -e "${YELLOW}(Create these at https://login.tailscale.com/admin/settings/keys)${NC}\\n"

read -p "Enter OAuth Client ID: " CLIENT_ID
if [ -z "$CLIENT_ID" ]; then
    echo -e "${RED}✗ Client ID is required${NC}"
    exit 1
fi

read -sp "Enter OAuth Client Secret: " CLIENT_SECRET
echo ""
if [ -z "$CLIENT_SECRET" ]; then
    echo -e "${RED}✗ Client Secret is required${NC}"
    exit 1
fi

read -p "Enter Tailnet name (e.g., user.github): " TAILNET
if [ -z "$TAILNET" ]; then
    echo -e "${RED}✗ Tailnet name is required${NC}"
    exit 1
fi

echo ""
echo -e "${BLUE}Configuration:${NC}"
echo -e "  Tailnet: ${YELLOW}${TAILNET}${NC}"
echo -e "  Client ID: ${YELLOW}${CLIENT_ID:0:10}...${NC}"
echo ""

read -p "Proceed with installation? (y/n) " -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Cancelled."
    exit 1
fi

# Create namespace
echo -e "\\n${BLUE}Creating tailscale namespace...${NC}"
kubectl create namespace tailscale --dry-run=client -o yaml | kubectl apply -f -

# Create secret with OAuth credentials
echo -e "${BLUE}Creating OAuth secret...${NC}"
kubectl create secret generic tailscale-oauth \
    -n tailscale \
    --from-literal=client_id="$CLIENT_ID" \
    --from-literal=client_secret="$CLIENT_SECRET" \
    --dry-run=client -o yaml | kubectl apply -f -

echo -e "${GREEN}✓${NC} Secret created"

# Add Helm repository
echo -e "${BLUE}Adding Tailscale Helm repository...${NC}"
helm repo add tailscale https://pkgs.tailscale.com/helmcharts
helm repo update

# Install Tailscale operator
echo -e "${BLUE}Installing Tailscale operator...${NC}"
helm upgrade --install tailscale-operator tailscale/tailscale-operator \
    --namespace=tailscale \
    --wait \
    --set-string oauth.clientId="$CLIENT_ID" \
    --set-string oauth.clientSecret="$CLIENT_SECRET" \
    --set-string tailnet="$TAILNET"

echo -e "\\n${GREEN}✓ Tailscale operator installed${NC}"

# Wait for operator to be ready
echo -e "${BLUE}Waiting for operator to be ready...${NC}"
kubectl rollout status deployment/tailscale-operator -n tailscale --timeout=5m

echo -e "\\n${YELLOW}Verification:${NC}"
echo -e "Check Tailscale admin console for a machine named 'tailscale-operator'"
echo -e "with tag ${YELLOW}tag:k8s-operator${NC}"
echo ""
echo -e "Verify deployment:"
echo -e "  ${BLUE}kubectl get pods -n tailscale${NC}"
echo -e "  ${BLUE}kubectl get machines${NC} (Tailscale custom resource)"
echo ""
echo -e "${GREEN}✓ Setup complete!${NC}"
echo ""
echo -e "${YELLOW}Next steps:${NC}"
echo -e "1. Verify operator appears in your Tailscale admin console"
echo -e "2. Create Tailscale ingress for Forgejo:"
echo -e "   ${BLUE}kubectl apply -f apps/forgejo-tailscale-ingress.yaml${NC}"
echo -e "3. Access Forgejo at: ${YELLOW}http://forgejo.TAILNET_NAME${NC}"
echo ""
