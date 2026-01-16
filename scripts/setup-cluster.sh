#!/bin/bash
#
# Complete Cluster Setup for Ironclad
# Run this after terraform apply completes successfully
#
# This script:
# 1. Saves kubeconfig locally
# 2. Installs Argo CD
# 3. Configures GitHub repository access
# 4. Sets up secrets
#
# Usage: ./scripts/setup-cluster.sh
#

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}=====================================${NC}"
echo -e "${BLUE}Ironclad Cluster - Complete Setup${NC}"
echo -e "${BLUE}=====================================${NC}\n"

# ============================================
# Step 1: Save Kubeconfig
# ============================================
echo -e "${BLUE}Step 1: Saving kubeconfig${NC}"

if [ ! -f "infra/terraform.tfstate" ]; then
    echo -e "${RED}✗ terraform.tfstate not found${NC}"
    echo -e "${YELLOW}Please run: cd infra && terraform apply${NC}"
    exit 1
fi

cd infra
terraform output -raw kubeconfig > ~/.kube/config
chmod 600 ~/.kube/config
cd ..

echo -e "${GREEN}✓ Kubeconfig saved to ~/.kube/config${NC}\n"

# Verify connection
if ! kubectl cluster-info &> /dev/null; then
    echo -e "${RED}✗ Failed to connect to cluster${NC}"
    exit 1
fi

CLUSTER_INFO=$(kubectl cluster-info 2>/dev/null | head -1)
echo -e "${GREEN}✓ Connected to cluster: $CLUSTER_INFO${NC}\n"

# ============================================
# Step 2: Install Argo CD
# ============================================
echo -e "${BLUE}Step 2: Installing Argo CD${NC}"

if kubectl get namespace argocd &> /dev/null; then
    echo -e "${YELLOW}⊘ Argo CD already installed${NC}"
else
    kubectl create namespace argocd
    kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

    echo -e "${YELLOW}Waiting for Argo CD to be ready...${NC}"
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=argocd-server -n argocd --timeout=300s 2>/dev/null || true
    sleep 10
fi

echo -e "${GREEN}✓ Argo CD installed${NC}\n"

# ============================================
# Step 3: Configure GitHub Repository Access
# ============================================
echo -e "${BLUE}Step 3: Configuring GitHub Repository Access${NC}"

if [ -z "$GITHUB_TOKEN" ]; then
    echo -e "${YELLOW}GitHub Personal Access Token not set in environment${NC}"
    read -p "Enter your GitHub PAT (or press Enter to skip): " github_token
else
    github_token="$GITHUB_TOKEN"
fi

if [ -n "$github_token" ]; then
    # Extract repo URL from user input
    read -p "GitHub Repository URL (e.g., https://github.com/user/repo): " repo_url

    # Extract username from URL
    github_user=$(echo "$repo_url" | sed -E 's|.*github.com[:/]([^/]+)/.*|\1|')

    if [ -z "$github_user" ]; then
        echo -e "${RED}✗ Could not parse GitHub URL${NC}"
        exit 1
    fi

    # Create Argo CD repository secret
    kubectl create secret generic "$github_user-repo" \
        -n argocd \
        --from-literal=type=git \
        --from-literal=url="$repo_url" \
        --from-literal=password="$github_token" \
        --from-literal=username=not_used \
        --dry-run=client -o yaml | kubectl apply -f -

    echo -e "${GREEN}✓ GitHub repository configured${NC}\n"
else
    echo -e "${YELLOW}⊘ Skipping GitHub configuration${NC}"
    echo -e "${BLUE}To configure later:${NC}"
    echo -e "  export GITHUB_TOKEN=github_pat_..."
    echo -e "  ./scripts/setup-cluster.sh\n"
fi

# ============================================
# Step 4: Setup Secrets
# ============================================
echo -e "${BLUE}Step 4: Setting up cluster secrets${NC}"

read -p "Do you want to configure secrets now? (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    ./scripts/setup-secrets.sh
else
    echo -e "${YELLOW}⊘ Skipping secrets setup${NC}"
    echo -e "${BLUE}To setup secrets later:${NC}"
    echo -e "  ./scripts/setup-secrets.sh\n"
fi

# ============================================
# Summary and Next Steps
# ============================================
echo -e "${BLUE}=====================================${NC}"
echo -e "${GREEN}✓ Cluster Setup Complete!${NC}"
echo -e "${BLUE}=====================================${NC}\n"

# Get Argo CD password
ARGOCD_PASSWORD=$(kubectl get secret -n argocd argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d 2>/dev/null || echo "NOT_FOUND")

echo -e "${YELLOW}Access Argo CD:${NC}"
echo -e "  kubectl port-forward svc/argocd-server -n argocd 8080:443"
echo -e "  Username: admin"
echo -e "  Password: $ARGOCD_PASSWORD\n"

echo -e "${YELLOW}Monitor cluster:${NC}"
echo -e "  kubectl get all -A"
echo -e "  kubectl get applications -n argocd\n"

echo -e "${YELLOW}Access Forgejo (once deployed):${NC}"
echo -e "  kubectl port-forward svc/forgejo -n forgejo 3000:3000"
echo -e "  http://localhost:3000\n"

echo -e "${BLUE}Full documentation: cat CLAUDE.md${NC}\n"
