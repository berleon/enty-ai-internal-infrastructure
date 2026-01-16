output "cluster_name" {
  description = "Name of the deployed Kubernetes cluster"
  value       = module.kube-hetzner.cluster_name
}

output "kubeconfig" {
  description = "Kubeconfig for kubectl access (saved to ~/.kube/config by default)"
  value       = local.kubeconfig
  sensitive   = true
}

output "control_plane_ip" {
  description = "IP address of the control plane node"
  value       = module.kube-hetzner.control_plane_public_ip
}

output "kubeapi_server_host" {
  description = "Kubernetes API server host"
  value       = module.kube-hetzner.kubeapi_server_host
}

output "ssh_key_id" {
  description = "SSH key ID created for cluster access"
  value       = module.kube-hetzner.ssh_key_id
}

output "firewall_id" {
  description = "Hetzner Cloud Firewall ID"
  value       = try(module.kube-hetzner.firewall_id, null)
}

output "firewall_rules" {
  description = "Firewall rules created by the module"
  value       = "Check Hetzner Console or module documentation for details"
}

output "next_steps" {
  description = "Instructions for next steps"
  value = <<-EOT
    Kubernetes cluster deployed successfully!

    1. Verify cluster:
       export KUBECONFIG=~/.kube/config
       kubectl cluster-info
       kubectl get nodes

    2. Install Tailscale operator for secure private access:
       helm repo add tailscale https://pkgs.tailscale.com/helmcharts
       helm repo update
       helm upgrade --install tailscale-operator tailscale/tailscale-operator \
         --namespace tailscale --create-namespace \
         --set-string oauth.clientId="YOUR_OAUTH_CLIENT_ID" \
         --set-string oauth.clientSecret="YOUR_OAUTH_CLIENT_SECRET"

    3. Install Argo CD for GitOps:
       kubectl create namespace argocd
       kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

    4. Configure your git repository with apps/forgejo.yaml, apps/runner.yaml, apps/backup.yaml

    See CLAUDE.md for detailed deployment phases.
  EOT
}
