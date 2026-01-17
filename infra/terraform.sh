#!/bin/bash
# Secure Terraform wrapper that decrypts SOPS secrets and cleans up afterward
# Usage: ./terraform.sh plan
#        ./terraform.sh apply
#        ./terraform.sh destroy

set -euo pipefail

# Ensure we're in the right directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Create a secure temporary file with restrictive permissions (600: rw-------)
TEMP_VARS=$(mktemp --tmpdir kube.tfvars.XXXXXXXXXX)
chmod 600 "$TEMP_VARS"

# Cleanup function: runs on EXIT, INT, TERM, etc.
# Uses shred for secure wiping (overwrites data before deleting)
cleanup() {
    local exit_code=$?
    echo ""
    echo "🧹 Cleaning up temporary files..."

    # Try shred first (secure), fall back to rm
    if command -v shred &> /dev/null; then
        shred -vfz -n 3 "$TEMP_VARS" 2>/dev/null || true
    else
        rm -f "$TEMP_VARS"
    fi

    if [ $exit_code -ne 0 ]; then
        echo "⚠️  Terraform command failed with exit code $exit_code"
    fi

    return $exit_code
}

# Set trap to cleanup on any exit (error, signal, normal completion)
trap cleanup EXIT

# Verify kube.tfvars exists
if [ ! -f "kube.tfvars" ]; then
    echo "❌ Error: kube.tfvars not found in $(pwd)"
    exit 1
fi

# Decrypt SOPS file to temporary location
echo "🔓 Decrypting kube.tfvars..."
if ! sops -d kube.tfvars > "$TEMP_VARS"; then
    echo "❌ Error: Failed to decrypt kube.tfvars (Yubikey required?)"
    exit 1
fi

# Verify decryption worked
if [ ! -s "$TEMP_VARS" ]; then
    echo "❌ Error: Decrypted file is empty"
    exit 1
fi

# Run Terraform with decrypted vars file
echo "🏗️  Running terraform $@..."
echo ""
terraform "$@" -var-file="$TEMP_VARS"
