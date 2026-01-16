#!/bin/bash
# Configure Tailscale SSH forwarding for Forgejo
# This script configures the Tailscale proxy to forward SSH traffic to Forgejo

set -e

echo "🔍 Finding Tailscale SSH proxy pod..."

# Wait for the proxy pod to be ready
echo "⏳ Waiting for SSH proxy pod to be ready..."
kubectl wait --for=condition=ready pod \
  -l tailscale.com/parent-resource=forgejo-ssh-tailscale \
  -n tailscale \
  --timeout=60s

# Get the pod name
POD=$(kubectl get pod -n tailscale \
  -l tailscale.com/parent-resource=forgejo-ssh-tailscale \
  -o jsonpath='{.items[0].metadata.name}')

if [ -z "$POD" ]; then
  echo "❌ Error: Could not find Tailscale SSH proxy pod"
  exit 1
fi

echo "✅ Found proxy pod: $POD"

# Get the ClusterIP of the SSH service
CLUSTER_IP=$(kubectl get svc forgejo-ssh-tailscale -n forgejo -o jsonpath='{.spec.clusterIP}')

if [ -z "$CLUSTER_IP" ]; then
  echo "❌ Error: Could not get ClusterIP for forgejo-ssh-tailscale service"
  exit 1
fi

echo "📡 Service ClusterIP: $CLUSTER_IP"

# Configure Tailscale serve
echo "🔧 Configuring Tailscale TCP forwarding..."
kubectl exec -n tailscale "$POD" -- \
  tailscale serve --bg --tcp 22 "tcp://${CLUSTER_IP}:22"

# Verify configuration
echo ""
echo "✅ SSH forwarding configured successfully!"
echo ""
echo "📊 Current configuration:"
kubectl exec -n tailscale "$POD" -- tailscale serve status

echo ""
# Try to detect the Tailscale hostname from the service
TAILSCALE_HOSTNAME=$(kubectl get svc forgejo-ssh-tailscale -n forgejo -o jsonpath='{.metadata.annotations.tailscale\.com/hostname}' 2>/dev/null || echo "")

if [ -n "$TAILSCALE_HOSTNAME" ]; then
  # Try to get the full domain from the tailscale pod
  FULL_DOMAIN=$(kubectl exec -n tailscale "$POD" -- tailscale status --json 2>/dev/null | grep -o '"DNSName":"[^"]*"' | head -1 | cut -d'"' -f4 || echo "")

  if [ -n "$FULL_DOMAIN" ]; then
    # Remove trailing dot if present
    FULL_DOMAIN=${FULL_DOMAIN%.}
    echo "🎉 Done! SSH is now accessible at:"
    echo "   git@$FULL_DOMAIN"
    echo ""
    echo "Test with:"
    echo "   ssh -T git@$FULL_DOMAIN"
    echo "   git clone git@$FULL_DOMAIN:username/repo.git"
  else
    echo "🎉 Done! SSH is now accessible at:"
    echo "   git@$TAILSCALE_HOSTNAME.<YOUR-TAILNET>.ts.net"
    echo ""
    echo "⚠️  Note: Replace <YOUR-TAILNET> with your actual Tailscale tailnet ID"
  fi
else
  echo "🎉 Done! SSH should now be accessible via Tailscale"
  echo "⚠️  Could not detect hostname automatically"
  echo "   Check your Forgejo configuration for the SSH domain"
fi
