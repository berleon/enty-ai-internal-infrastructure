#!/bin/bash
set -euo pipefail

# Control Center Script for Ironclad Infrastructure
# Usage: ./control.sh [command]
# Commands: status, ui-argo, ui-git, backup-now, logs-backup, top, help

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"

# Configuration
KUBE_CTX="${KUBE_CTX:-}"
ARGO_NAMESPACE="argocd"
FORGEJO_NAMESPACE="forgejo"
ARGO_PORT="${ARGO_PORT:-8080}"

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

function log_info() {
  echo -e "${BLUE}ℹ${NC} $*"
}

function log_success() {
  echo -e "${GREEN}✓${NC} $*"
}

function log_warning() {
  echo -e "${YELLOW}⚠${NC} $*"
}

function log_error() {
  echo -e "${RED}✗${NC} $*"
}

function show_help() {
  cat <<EOF
Usage: ./control.sh [command]

Commands:
  status       Run the Python dashboard (health check)
  ui-argo      Open Argo CD UI (port-forward + browser)
  ui-git       Open Forgejo UI (Tailscale URL)
  backup-now   Trigger an immediate manual backup job
  logs-backup  Show logs from the last backup job
  top          Show real-time pod CPU/RAM usage
  pods         List all pods in all namespaces
  help         Show this help message

Examples:
  ./control.sh status      # Check cluster health
  ./control.sh ui-argo     # Open Argo CD dashboard
  ./control.sh backup-now  # Run backup immediately

Environment:
  KUBE_CTX     Kubernetes context (optional, uses current context if not set)
  ARGO_PORT    Port for Argo CD UI (default: 8080)

EOF
}

function check_kubectl() {
  if ! command -v kubectl &> /dev/null; then
    log_error "kubectl not found. Please install kubectl."
    exit 1
  fi
}

function get_kube_context_flag() {
  if [ -n "$KUBE_CTX" ]; then
    echo "--context=$KUBE_CTX"
  fi
}

function cmd_status() {
  log_info "Gathering cluster status..."
  python3 "$SCRIPT_DIR/dashboard.py"
}

function cmd_ui_argo() {
  check_kubectl
  local ctx_flag=$(get_kube_context_flag)

  log_info "Starting Argo CD port-forward..."
  log_warning "Press Ctrl+C to stop"

  # Try to open browser in background
  (
    sleep 2
    local url="http://localhost:$ARGO_PORT"
    log_success "Argo CD available at $url"
    if command -v open &> /dev/null; then
      open "$url"
    elif command -v xdg-open &> /dev/null; then
      xdg-open "$url"
    else
      log_warning "Could not open browser automatically. Visit $url manually."
    fi
  ) &

  kubectl port-forward $ctx_flag svc/argocd-server -n "$ARGO_NAMESPACE" "$ARGO_PORT:443"
}

function cmd_ui_git() {
  log_info "Opening Forgejo UI..."
  log_info "You should have Tailscale configured to access this URL"

  # Get Tailscale hostname from environment or use default
  local tailnet="${TAILSCALE_TAILNET:-ts}"
  local url="https://git-forge.$tailnet"

  log_success "Forgejo available at $url"

  if command -v open &> /dev/null; then
    open "$url"
  elif command -v xdg-open &> /dev/null; then
    xdg-open "$url"
  else
    log_warning "Could not open browser. Visit $url manually"
  fi
}

function cmd_backup_now() {
  check_kubectl
  local ctx_flag=$(get_kube_context_flag)

  log_info "Triggering manual backup job..."
  local job_name="manual-backup-$(date +%s)"

  kubectl create job $ctx_flag --from=cronjob/forgejo-backup-s3 "$job_name" -n "$FORGEJO_NAMESPACE"

  log_success "Backup job started: $job_name"
  log_info "Watch progress with:"
  log_info "  ./control.sh logs-backup"
  log_info "Or:"
  log_info "  kubectl logs -f -n $FORGEJO_NAMESPACE -l app=forgejo-backup --tail=50"
}

function cmd_logs_backup() {
  check_kubectl
  local ctx_flag=$(get_kube_context_flag)

  log_info "Finding last backup job..."

  # Find the most recent backup pod
  local last_pod=$(kubectl get pods $ctx_flag -n "$FORGEJO_NAMESPACE" \
    -l app=forgejo-backup \
    --sort-by=.metadata.creationTimestamp \
    -o name | tail -n 1)

  if [ -z "$last_pod" ]; then
    log_warning "No backup pods found."
    log_info "Check if the CronJob exists:"
    log_info "  kubectl get cronjob -n $FORGEJO_NAMESPACE"
    return 1
  fi

  log_success "Showing logs for $last_pod"
  kubectl logs $ctx_flag "$last_pod" -n "$FORGEJO_NAMESPACE" --all-containers --tail=100 -f
}

function cmd_top() {
  check_kubectl
  local ctx_flag=$(get_kube_context_flag)

  log_info "Showing real-time pod CPU/RAM usage (press Ctrl+C to exit)"
  log_warning "Note: metrics-server must be enabled for this to work"

  # Use watch if available, otherwise simple kubectl top
  if command -v watch &> /dev/null; then
    watch "kubectl top nodes $ctx_flag 2>/dev/null && echo '' && kubectl top pods $ctx_flag -A --sort-by=cpu 2>/dev/null | head -20"
  else
    kubectl top pods $ctx_flag -A --sort-by=cpu
  fi
}

function cmd_pods() {
  check_kubectl
  local ctx_flag=$(get_kube_context_flag)

  log_info "Listing all pods..."
  kubectl get pods $ctx_flag -A
}

# Main dispatch
case "${1:-help}" in
  status)
    cmd_status
    ;;
  ui-argo)
    cmd_ui_argo
    ;;
  ui-git)
    cmd_ui_git
    ;;
  backup-now)
    cmd_backup_now
    ;;
  logs-backup)
    cmd_logs_backup
    ;;
  top)
    cmd_top
    ;;
  pods)
    cmd_pods
    ;;
  help)
    show_help
    ;;
  *)
    log_error "Unknown command: $1"
    show_help
    exit 1
    ;;
esac
