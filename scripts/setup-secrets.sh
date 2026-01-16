#!/bin/bash
#
# Setup Secrets for Ironclad Kubernetes Cluster
# This script creates Kubernetes secrets that should NOT be stored in git
#
# Usage: ./scripts/setup-secrets.sh
#

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}=====================================${NC}"
echo -e "${BLUE}Ironclad Cluster - Secrets Setup${NC}"
echo -e "${BLUE}=====================================${NC}\n"

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
    echo -e "${RED}✗ kubectl not found. Please install kubectl first.${NC}"
    exit 1
fi

# Check if we're connected to a cluster
if ! kubectl cluster-info &> /dev/null; then
    echo -e "${RED}✗ Not connected to a Kubernetes cluster${NC}"
    echo -e "${YELLOW}Please run: cd infra && terraform output -raw kubeconfig > ~/.kube/config${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Connected to cluster${NC}\n"

# ============================================
# S3 Backup Credentials
# ============================================
echo -e "${BLUE}1. S3 Backup Credentials${NC}"
echo -e "${YELLOW}Forgejo database backups will be uploaded to S3 daily (3 AM UTC)${NC}\n"

read -p "Do you want to configure S3 backups? (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    read -p "S3 Access Key: " s3_access_key
    read -s -p "S3 Secret Key: " s3_secret_key
    echo
    read -p "S3 Bucket Name (e.g., my-backups): " s3_bucket
    read -p "S3 Endpoint (default: https://s3.amazonaws.com): " s3_endpoint
    s3_endpoint=${s3_endpoint:-"https://s3.amazonaws.com"}

    # Create secret
    kubectl create secret generic s3-credentials \
        -n forgejo \
        --from-literal=access-key="$s3_access_key" \
        --from-literal=secret-key="$s3_secret_key" \
        --from-literal=bucket="$s3_bucket" \
        --from-literal=endpoint="$s3_endpoint" \
        --dry-run=client -o yaml | kubectl apply -f -

    echo -e "${GREEN}✓ S3 credentials configured${NC}\n"
else
    echo -e "${YELLOW}⊘ Skipping S3 backups (backups will not run)${NC}\n"
fi

# ============================================
# Forgejo Admin Password
# ============================================
echo -e "${BLUE}2. Forgejo Admin Password${NC}"
echo -e "${YELLOW}Default: ChangeMe123! (you MUST change this after first login)${NC}\n"

read -p "Do you want to set a custom admin password? (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    read -s -p "Forgejo Admin Password: " forgejo_password
    echo
    read -s -p "Confirm password: " forgejo_password_confirm
    echo

    if [ "$forgejo_password" != "$forgejo_password_confirm" ]; then
        echo -e "${RED}✗ Passwords don't match${NC}"
        exit 1
    fi
else
    forgejo_password="ChangeMe123!"
    echo -e "${YELLOW}⊘ Using default password: ChangeMe123!${NC}\n"
fi

# Update apps/forgejo.yaml with new password
if [ "$forgejo_password" != "ChangeMe123!" ]; then
    sed -i "s|password: \"ChangeMe123!\"|password: \"$forgejo_password\"|g" apps/forgejo.yaml
    echo -e "${GREEN}✓ Forgejo password updated in apps/forgejo.yaml${NC}\n"
fi

# ============================================
# Forgejo Runner Token
# ============================================
echo -e "${BLUE}3. Forgejo Runner Token${NC}"
echo -e "${YELLOW}Runners execute CI/CD jobs (like GitHub Actions)${NC}"
echo -e "${YELLOW}You'll get this token from Forgejo after it's deployed${NC}\n"

read -p "Do you have a Forgejo runner registration token? (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    read -p "Runner Registration Token: " runner_token

    # Create secret
    kubectl create secret generic forgejo-runner-token \
        -n forgejo-runner \
        --from-literal=token="$runner_token" \
        --dry-run=client -o yaml | kubectl apply -f -

    echo -e "${GREEN}✓ Runner token configured${NC}\n"
else
    echo -e "${YELLOW}⊘ Skipping runner setup for now${NC}"
    echo -e "${BLUE}To add runner token later:${NC}"
    echo -e "  1. Access Forgejo: kubectl port-forward svc/forgejo -n forgejo 3000:3000"
    echo -e "  2. Go to Site Admin → Actions → Runners → Create Runner"
    echo -e "  3. Run: kubectl create secret generic forgejo-runner-token -n forgejo-runner --from-literal=token=YOUR_TOKEN"
    echo -e "  4. Update apps/runner.yaml with the token and push to GitHub\n"
fi

# ============================================
# Summary
# ============================================
echo -e "${BLUE}=====================================${NC}"
echo -e "${GREEN}✓ Secrets Setup Complete!${NC}"
echo -e "${BLUE}=====================================${NC}\n"

echo -e "${YELLOW}Next steps:${NC}"
echo -e "  1. Check Forgejo deployment: kubectl get pods -n forgejo"
echo -e "  2. Access Forgejo UI: kubectl port-forward svc/forgejo -n forgejo 3000:3000"
echo -e "  3. Login: admin / $forgejo_password"
echo -e "  4. Change admin password immediately!"
echo -e "  5. Create CI/CD runner if needed\n"
