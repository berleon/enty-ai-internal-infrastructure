# Module outputs from terraform-hcloud-kubernetes
# See: https://github.com/hcloud-k8s/terraform-hcloud-kubernetes/blob/main/README.md

output "kubeconfig" {
  description = "Kubeconfig content for kubectl access"
  value       = module.kube-hetzner.kubeconfig
  sensitive   = true
}

output "talosconfig" {
  description = "Talosconfig for talosctl access (Talos OS management)"
  value       = try(module.kube-hetzner.talosconfig, null)
  sensitive   = true
}

output "kubeconfig_yaml" {
  description = "Instructions for using kubeconfig"
  value = <<-EOT
    Your kubeconfig is ready!

    To use it with kubectl:
      # Option 1: Save to ~/.kube/config
      terraform output -raw kubeconfig > ~/.kube/config
      chmod 600 ~/.kube/config
      kubectl get nodes

      # Option 2: Use KUBECONFIG environment variable
      export KUBECONFIG=$(pwd)/kubeconfig.yaml
      terraform output -raw kubeconfig > kubeconfig.yaml
      kubectl get nodes

    Note: The cluster uses Talos OS (modern immutable Kubernetes OS)
  EOT
}

output "next_steps" {
  description = "Instructions for next steps"
  value = <<-EOT
    Kubernetes cluster deployed successfully!

    1. Save your kubeconfig:
       terraform output -raw kubeconfig > ~/.kube/config
       chmod 600 ~/.kube/config

    2. Verify cluster is healthy:
       kubectl cluster-info
       kubectl get nodes
       kubectl get pods -A

    3. Install Tailscale operator for secure private access:
       helm repo add tailscale https://pkgs.tailscale.com/helmcharts
       helm repo update
       helm upgrade --install tailscale-operator tailscale/tailscale-operator \
         --namespace tailscale --create-namespace \
         --set-string oauth.clientId="YOUR_OAUTH_CLIENT_ID" \
         --set-string oauth.clientSecret="YOUR_OAUTH_CLIENT_SECRET"

    4. Install Argo CD for GitOps:
       kubectl create namespace argocd
       kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

    5. Deploy applications from apps/forgejo.yaml, apps/runner.yaml, apps/backup.yaml

    See CLAUDE.md for detailed deployment phases.
  EOT
}
