#!/usr/bin/env bash
set -euo pipefail

# ArgoCD Structure Migration Script
# Migrates from flat applications/ directory to layered infrastructure/platform/apps structure
#
# Usage: ./scripts/migrate-argocd-structure.sh [--dry-run] [--commit]
#
# Options:
#   --dry-run   Show what would be done without making changes
#   --commit    Automatically commit changes after migration
#   --help      Show this help message

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

# Configuration
DRY_RUN=false
AUTO_COMMIT=false
REPO_URL="https://github.com/berleon/enty-ai-internal-infrastructure.git"

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --commit)
      AUTO_COMMIT=true
      shift
      ;;
    --help)
      head -n 15 "$0" | tail -n 11
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      echo "Use --help for usage information"
      exit 1
      ;;
  esac
done

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() {
  echo -e "${BLUE}ℹ${NC} $*"
}

log_success() {
  echo -e "${GREEN}✓${NC} $*"
}

log_warning() {
  echo -e "${YELLOW}⚠${NC} $*"
}

log_error() {
  echo -e "${RED}✗${NC} $*"
}

run_cmd() {
  if [[ "$DRY_RUN" == "true" ]]; then
    echo -e "${YELLOW}[DRY RUN]${NC} $*"
  else
    "$@"
  fi
}

# Validation
if [[ ! -d "argocd/applications" ]]; then
  log_error "argocd/applications directory not found"
  log_error "Run this script from the repository root"
  exit 1
fi

log_info "Starting ArgoCD structure migration"
log_info "Repository: $REPO_ROOT"
if [[ "$DRY_RUN" == "true" ]]; then
  log_warning "DRY RUN MODE - No changes will be made"
fi

# Step 1: Create backup
log_info "Creating backup of current structure..."
if [[ "$DRY_RUN" == "false" ]]; then
  cp -r argocd argocd.backup
  log_success "Backup created at argocd.backup/"
else
  log_warning "[DRY RUN] Would create backup at argocd.backup/"
fi

# Step 2: Create new directory structure
log_info "Creating new directory structure..."

declare -a DIRS=(
  # Infrastructure layer
  "argocd-new/infrastructure/argocd"
  "argocd-new/infrastructure/postgres-operator"
  "argocd-new/infrastructure/tailscale-operator/secrets/oauth"
  "argocd-new/infrastructure/tailscale-operator/secrets/namespace"

  # Platform layer
  "argocd-new/platform/postgres-cluster/cluster"
  "argocd-new/platform/postgres-cluster/secrets/credentials"
  "argocd-new/platform/postgres-cluster/secrets/role-secrets"
  "argocd-new/platform/backup/manifests"
  "argocd-new/platform/backup/secrets"
  "argocd-new/platform/shared-secrets/github"

  # Apps layer
  "argocd-new/apps/forgejo/secrets/oauth"
  "argocd-new/apps/forgejo/secrets/postgres"
  "argocd-new/apps/forgejo/ingress"
  "argocd-new/apps/authentik/secrets/app-config"
  "argocd-new/apps/authentik/secrets/postgres"
  "argocd-new/apps/authentik/ingress"

  # Keep install as-is
  "argocd-new/install/patches"
)

for dir in "${DIRS[@]}"; do
  run_cmd mkdir -p "$dir"
done

if [[ "$DRY_RUN" == "false" ]]; then
  log_success "Created new directory structure"
fi

# Step 3: Define file mappings
log_info "Preparing file migration mappings..."

# Infrastructure mappings
declare -A INFRA_MAPPINGS=(
  ["argocd/applications/argocd-config.yaml"]="argocd-new/infrastructure/argocd/application.yaml"
  ["argocd/applications/cloudnative-pg-operator.yaml"]="argocd-new/infrastructure/postgres-operator/application.yaml"
  ["argocd/applications/tailscale-operator.yaml"]="argocd-new/infrastructure/tailscale-operator/application.yaml"
)

# Platform mappings
declare -A PLATFORM_MAPPINGS=(
  ["argocd/applications/postgres-cluster.yaml"]="argocd-new/platform/postgres-cluster/application.yaml"
  ["argocd/applications/backup.yaml"]="argocd-new/platform/backup/application.yaml"
  ["argocd/applications/github-secrets.yaml"]="argocd-new/platform/shared-secrets/github/application.yaml"
)

# Apps mappings
declare -A APPS_MAPPINGS=(
  ["argocd/applications/forgejo.yaml"]="argocd-new/apps/forgejo/application.yaml"
  ["argocd/applications/authentik.yaml"]="argocd-new/apps/authentik/application.yaml"
)

# Resource directory mappings (move entire directories)
declare -A RESOURCE_MAPPINGS=(
  # Infrastructure resources
  ["argocd/resources/tailscale-secrets"]="argocd-new/infrastructure/tailscale-operator/secrets/oauth"
  ["argocd/resources/tailscale-namespace"]="argocd-new/infrastructure/tailscale-operator/secrets/namespace"

  # Platform resources
  ["argocd/resources/postgres-cluster"]="argocd-new/platform/postgres-cluster/cluster"
  ["argocd/resources/postgres-credentials"]="argocd-new/platform/postgres-cluster/secrets/credentials"
  ["argocd/resources/postgres-role-secrets"]="argocd-new/platform/postgres-cluster/secrets/role-secrets"
  ["argocd/resources/backup"]="argocd-new/platform/backup/manifests"
  ["argocd/resources/s3-backup-secrets"]="argocd-new/platform/backup/secrets"
  ["argocd/resources/github-secrets"]="argocd-new/platform/shared-secrets/github"

  # Forgejo resources
  ["argocd/resources/forgejo-oauth-secret"]="argocd-new/apps/forgejo/secrets/oauth"
  ["argocd/resources/forgejo-postgres-secret"]="argocd-new/apps/forgejo/secrets/postgres"
  ["argocd/resources/forgejo-ingress"]="argocd-new/apps/forgejo/ingress"

  # Authentik resources
  ["argocd/resources/authentik-secrets"]="argocd-new/apps/authentik/secrets/app-config"
  ["argocd/resources/authentik-postgres-secret"]="argocd-new/apps/authentik/secrets/postgres"
  ["argocd/resources/authentik-ingress"]="argocd-new/apps/authentik/ingress"
)

# Secret application mappings
declare -A SECRET_APP_MAPPINGS=(
  # Infrastructure
  ["argocd/applications/tailscale-secrets.yaml"]="argocd-new/infrastructure/tailscale-operator/secrets/oauth/application.yaml"
  ["argocd/applications/tailscale-namespace.yaml"]="argocd-new/infrastructure/tailscale-operator/secrets/namespace/application.yaml"

  # Platform
  ["argocd/applications/postgres-credentials.yaml"]="argocd-new/platform/postgres-cluster/secrets/credentials/application.yaml"
  ["argocd/applications/postgres-role-secrets.yaml"]="argocd-new/platform/postgres-cluster/secrets/role-secrets/application.yaml"
  ["argocd/applications/s3-backup-secrets.yaml"]="argocd-new/platform/backup/secrets/application.yaml"

  # Forgejo
  ["argocd/applications/forgejo-oauth-secret.yaml"]="argocd-new/apps/forgejo/secrets/oauth/application.yaml"
  ["argocd/applications/forgejo-postgres-secret.yaml"]="argocd-new/apps/forgejo/secrets/postgres/application.yaml"
  ["argocd/applications/forgejo-tailscale-ingress.yaml"]="argocd-new/apps/forgejo/ingress/application.yaml"

  # Authentik
  ["argocd/applications/authentik-secrets.yaml"]="argocd-new/apps/authentik/secrets/app-config/application.yaml"
  ["argocd/applications/authentik-postgres-secret.yaml"]="argocd-new/apps/authentik/secrets/postgres/application.yaml"
  ["argocd/applications/authentik-tailscale-ingress.yaml"]="argocd-new/apps/authentik/ingress/application.yaml"
)

# Step 4: Move application files
log_info "Migrating application manifests..."

move_and_update() {
  local src="$1"
  local dst="$2"
  local old_path="$3"
  local new_path="$4"

  if [[ ! -f "$src" ]]; then
    log_warning "Source file not found: $src"
    return
  fi

  # Copy file
  run_cmd cp "$src" "$dst"

  # Update path if specified
  if [[ -n "$old_path" ]] && [[ -n "$new_path" ]] && [[ "$DRY_RUN" == "false" ]]; then
    sed -i "s|path: ${old_path}|path: ${new_path}|g" "$dst"
  fi

  log_success "Moved: $(basename "$src") → $dst"
}

# Move infrastructure apps
for src in "${!INFRA_MAPPINGS[@]}"; do
  move_and_update "$src" "${INFRA_MAPPINGS[$src]}" "" ""
done

# Move platform apps
for src in "${!PLATFORM_MAPPINGS[@]}"; do
  move_and_update "$src" "${PLATFORM_MAPPINGS[$src]}" "" ""
done

# Move apps
for src in "${!APPS_MAPPINGS[@]}"; do
  move_and_update "$src" "${APPS_MAPPINGS[$src]}" "" ""
done

# Step 5: Move resource directories
log_info "Migrating resource directories..."

for src in "${!RESOURCE_MAPPINGS[@]}"; do
  dst="${RESOURCE_MAPPINGS[$src]}"
  if [[ ! -d "$src" ]]; then
    log_warning "Source directory not found: $src"
    continue
  fi

  # Copy entire directory contents
  run_cmd cp -r "$src"/* "$dst/"
  log_success "Moved resources: $src → $dst"
done

# Step 6: Move and update secret applications
log_info "Migrating secret application manifests with path updates..."

for src in "${!SECRET_APP_MAPPINGS[@]}"; do
  dst="${SECRET_APP_MAPPINGS[$src]}"

  if [[ ! -f "$src" ]]; then
    log_warning "Source file not found: $src"
    continue
  fi

  # Extract old path from source file
  old_path=$(grep "path:" "$src" | head -1 | sed 's/.*path: //' | tr -d ' ')

  # Determine new path based on destination
  new_path=$(dirname "$dst" | sed 's|argocd-new/|argocd/|')

  move_and_update "$src" "$dst" "$old_path" "$new_path"
done

# Step 7: Copy install directory as-is
log_info "Copying install directory..."
run_cmd cp -r argocd/install/* argocd-new/install/
log_success "Copied install configuration"

# Step 8: Copy root files
log_info "Copying root ArgoCD files..."
if [[ -f "argocd/argocd-sops-plugin-patch.yaml" ]]; then
  run_cmd cp argocd/argocd-sops-plugin-patch.yaml argocd-new/
fi
log_success "Copied root files"

# Step 9: Create layered app-of-apps files
log_info "Creating layered app-of-apps manifests..."

# Infrastructure app-of-apps
cat > argocd-new/infrastructure/app-of-apps.yaml <<'EOF'
# Infrastructure Layer - Operators and Core Services
# Sync Wave: 0 (deploys first)
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: infrastructure
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "0"
spec:
  project: default
  source:
    repoURL: REPO_URL_PLACEHOLDER
    targetRevision: main
    path: argocd/infrastructure/
    directory:
      recurse: true
      exclude: 'app-of-apps.yaml'
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
EOF

# Platform app-of-apps
cat > argocd-new/platform/app-of-apps.yaml <<'EOF'
# Platform Layer - Shared Services
# Sync Wave: 1 (deploys after infrastructure)
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: platform
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "1"
spec:
  project: default
  source:
    repoURL: REPO_URL_PLACEHOLDER
    targetRevision: main
    path: argocd/platform/
    directory:
      recurse: true
      exclude: 'app-of-apps.yaml'
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
EOF

# Apps app-of-apps
cat > argocd-new/apps/app-of-apps.yaml <<'EOF'
# Apps Layer - User-Facing Applications
# Sync Wave: 2 (deploys after platform)
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: apps
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "2"
spec:
  project: default
  source:
    repoURL: REPO_URL_PLACEHOLDER
    targetRevision: main
    path: argocd/apps/
    directory:
      recurse: true
      exclude: 'app-of-apps.yaml'
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
EOF

# Update repo URLs in app-of-apps files
if [[ "$DRY_RUN" == "false" ]]; then
  sed -i "s|REPO_URL_PLACEHOLDER|${REPO_URL}|g" argocd-new/infrastructure/app-of-apps.yaml
  sed -i "s|REPO_URL_PLACEHOLDER|${REPO_URL}|g" argocd-new/platform/app-of-apps.yaml
  sed -i "s|REPO_URL_PLACEHOLDER|${REPO_URL}|g" argocd-new/apps/app-of-apps.yaml
fi

log_success "Created layered app-of-apps manifests"

# Step 10: Create new root app-of-apps
log_info "Creating new root app-of-apps.yaml..."

cat > argocd-new/app-of-apps.yaml <<EOF
# Root App of Apps - Layered GitOps Structure
#
# This deploys applications in 3 layers with explicit ordering:
#   1. Infrastructure (wave 0) - Operators (Tailscale, PostgreSQL, Argo CD config)
#   2. Platform (wave 1) - Shared services (PostgreSQL cluster, backups)
#   3. Apps (wave 2) - User applications (Forgejo, Authentik)
#
# Workflow:
#   1. Create new Application manifest in appropriate layer directory
#   2. Commit to git
#   3. Argo CD auto-discovers and deploys (within ~3 minutes)
#
# Structure:
#   argocd/infrastructure/  - Core operators and system config
#   argocd/platform/        - Shared platform services
#   argocd/apps/            - User-facing applications

apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: app-of-apps
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  sources:
    # Layer 1: Infrastructure (sync wave 0)
    - repoURL: ${REPO_URL}
      targetRevision: main
      path: argocd/infrastructure/
      directory:
        recurse: false
        include: 'app-of-apps.yaml'

    # Layer 2: Platform (sync wave 1)
    - repoURL: ${REPO_URL}
      targetRevision: main
      path: argocd/platform/
      directory:
        recurse: false
        include: 'app-of-apps.yaml'

    # Layer 3: Apps (sync wave 2)
    - repoURL: ${REPO_URL}
      targetRevision: main
      path: argocd/apps/
      directory:
        recurse: false
        include: 'app-of-apps.yaml'

  destination:
    server: https://kubernetes.default.svc
    namespace: argocd

  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
EOF

log_success "Created root app-of-apps.yaml"

# Step 11: Validation
log_info "Validating migration..."

VALIDATION_ERRORS=0

# Check all expected files exist
check_file() {
  local file="$1"
  if [[ ! -f "$file" ]]; then
    log_error "Missing expected file: $file"
    ((VALIDATION_ERRORS++))
  fi
}

# Validate infrastructure layer
check_file "argocd-new/infrastructure/app-of-apps.yaml"
check_file "argocd-new/infrastructure/argocd/application.yaml"
check_file "argocd-new/infrastructure/postgres-operator/application.yaml"
check_file "argocd-new/infrastructure/tailscale-operator/application.yaml"

# Validate platform layer
check_file "argocd-new/platform/app-of-apps.yaml"
check_file "argocd-new/platform/postgres-cluster/application.yaml"
check_file "argocd-new/platform/backup/application.yaml"

# Validate apps layer
check_file "argocd-new/apps/app-of-apps.yaml"
check_file "argocd-new/apps/forgejo/application.yaml"
check_file "argocd-new/apps/authentik/application.yaml"

# Validate root
check_file "argocd-new/app-of-apps.yaml"

if [[ $VALIDATION_ERRORS -eq 0 ]]; then
  log_success "Validation passed - all expected files present"
else
  log_error "Validation found $VALIDATION_ERRORS errors"
  if [[ "$DRY_RUN" == "false" ]]; then
    log_warning "Migration completed with errors - check argocd-new/ before applying"
  fi
fi

# Step 12: Show next steps
log_info ""
log_info "═══════════════════════════════════════════════════════════"
log_info "Migration complete!"
log_info "═══════════════════════════════════════════════════════════"
log_info ""

if [[ "$DRY_RUN" == "true" ]]; then
  log_warning "This was a DRY RUN - no changes were made"
  log_info "Run without --dry-run to perform actual migration"
  exit 0
fi

log_info "New structure created at: argocd-new/"
log_info "Original backed up at: argocd.backup/"
log_info ""
log_info "Next steps:"
log_info "  1. Review the new structure:"
log_info "     tree argocd-new/ -L 3"
log_info ""
log_info "  2. Apply the migration:"
log_info "     rm -rf argocd"
log_info "     mv argocd-new argocd"
log_info ""
log_info "  3. Commit the changes:"
log_info "     git add argocd"
log_info "     git commit -m 'refactor(argocd): restructure into layered infrastructure/platform/apps'"
log_info "     git push origin main"
log_info ""
log_info "  4. Watch Argo CD sync:"
log_info "     kubectl get applications -n argocd -w"
log_info ""
log_info "  5. Verify all applications are healthy:"
log_info "     ./scripts/control.sh status"
log_info ""

if [[ "$AUTO_COMMIT" == "true" ]]; then
  log_info "Auto-commit requested - applying changes and committing..."

  # Apply migration
  rm -rf argocd
  mv argocd-new argocd

  # Commit
  git add argocd
  git commit -m "refactor(argocd): restructure into layered infrastructure/platform/apps

- Organize applications into 3 layers: infrastructure, platform, apps
- Add sync wave ordering (infrastructure→platform→apps)
- Co-locate related resources with their applications
- Improve discoverability and maintainability

Migration performed by: scripts/migrate-argocd-structure.sh"

  log_success "Changes committed - ready to push!"
  log_info ""
  log_info "Final step:"
  log_info "  git push origin main"
else
  log_warning "Changes NOT committed - review before committing"
fi
