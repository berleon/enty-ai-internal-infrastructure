#!/bin/bash
#
# Download latest documentation from upstream projects
# Keeps reference docs up-to-date without committing them to git
#
# Usage: ./scripts/get-latest-docs.sh
#

set -e

# Colors for output
BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${BLUE}=====================================${NC}"
echo -e "${BLUE}Downloading Latest Documentation${NC}"
echo -e "${BLUE}=====================================${NC}\n"

DOCS_DIR="docs"
mkdir -p "$DOCS_DIR"

# Define documentation sources
declare -A DOCS=(
    ["forgejo-helm-README.md"]="https://code.forgejo.org/forgejo-helm/forgejo-helm/raw/branch/main/README.md"
    ["talos-os-quickstart.md"]="https://www.talos.dev/latest/introduction/quickstart/"
    ["kubernetes-security.md"]="https://kubernetes.io/docs/concepts/security/"
    ["kustomize-sops-README.md"]="https://raw.githubusercontent.com/viaduct-ai/kustomize-sops/refs/heads/master/README.md"
)

echo -e "${YELLOW}Documentation sources:${NC}\n"

# Download each doc
for filename in "${!DOCS[@]}"; do
    url="${DOCS[$filename]}"
    filepath="$DOCS_DIR/$filename"

    echo -ne "${BLUE}↓${NC} Downloading $filename... "

    if curl -sS -f -o "$filepath" "$url"; then
        filesize=$(wc -c < "$filepath")
        echo -e "${GREEN}✓${NC} ($(numfmt --to=iec-i --suffix=B $filesize 2>/dev/null || echo "$filesize bytes"))"
    else
        echo -e "${RED}✗ Failed${NC}"
        rm -f "$filepath"
    fi
done

echo -e "\n${GREEN}✓ Documentation downloaded to docs/${NC}\n"

# Summary
echo -e "${BLUE}Documentation available:${NC}"
for filename in "${!DOCS[@]}"; do
    if [ -f "$DOCS_DIR/$filename" ]; then
        lines=$(wc -l < "$DOCS_DIR/$filename")
        echo -e "  ${GREEN}✓${NC} $filename ($lines lines)"
    fi
done

echo -e "\n${YELLOW}Note: These files are gitignored and auto-updated${NC}"
echo -e "${YELLOW}To update: ./scripts/get-latest-docs.sh\n${NC}"
