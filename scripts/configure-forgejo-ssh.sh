#!/bin/bash
# Configure Tailscale SSH forwarding for Forgejo
# This script configures the Tailscale proxy to forward SSH traffic to Forgejo

set -e

echo "🔍 Finding Tailscale SSH proxy pod..."

# Wait for the proxy pod to be ready
echo "⏳ Waiting for SSH proxy pod to be ready..."
kubectl wait --for=condition=ready pod \
  -l tailscale.com/parent-resource=forgejo_forgejo-ssh-tailscale \
  -n tailscale \
  --timeout=60s

# Get the pod name
POD=$(kubectl get pod -n tailscale \
  -l tailscale.com/parent-resource=forgejo_forgejo-ssh-tailscale \
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
echo "🎉 Done! SSH is now accessible at:"
echo "   git@forgejo-ssh.tail36258d.ts.net"
echo ""
echo "Test with:"
echo "   ssh -T git@forgejo-ssh.tail36258d.ts.net"
echo "   git clone git@forgejo-ssh.tail36258d.ts.net:username/repo.git"
