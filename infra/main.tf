terraform {
  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.45"
    }
  }
}

provider "hcloud" {
  token = var.hcloud_token
}

module "kube-hetzner" {
  source = "hcloud-k8s/kubernetes/hcloud"
  version = "~> 3.0"

  cluster_name = var.cluster_name
  hcloud_token = var.hcloud_token

  # Control plane configuration (Talos-based, requires odd number for HA)
  control_plane_nodepools = var.control_plane_nodepools

  # Worker nodes (optional)
  worker_nodepools = var.worker_nodepools

  # Cluster access
  cluster_access = var.cluster_access

  # Output paths
  cluster_kubeconfig_path = var.cluster_kubeconfig_path
  cluster_talosconfig_path = var.cluster_talosconfig_path
}

# The kubeconfig is available via: terraform output kubeconfig
# You can save it with:
#   terraform output -raw kubeconfig > ~/.kube/config
#   chmod 600 ~/.kube/config
