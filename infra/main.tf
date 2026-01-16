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
  # Using the version from the terraform-hetzner-readme
  version = "~> 3.0"

  cluster_name              = var.cluster_name
  hcloud_token              = var.hcloud_token
  kubernetes_version        = var.kubernetes_version
  control_plane_count       = var.control_plane_count
  control_plane_server_type = var.control_plane_server_type
  agent_node_pools          = var.agent_node_pools
  image                     = var.image
  enable_klipper_metal_lb   = var.enable_klipper_metal_lb
  allow_scheduling_on_control_plane = var.allow_scheduling_on_control_plane
  enable_metrics_server     = var.enable_metrics_server
  firewall_kube_api_in_port = var.firewall_kube_api_in_port
  firewall_enabled          = var.firewall_enabled

  # For production, you'd want high availability
  # This single-node setup is intentional for cost savings
  # Production note: K3s etcd is single-node; for HA add control_plane_count >= 3
}

# Data source to fetch kubeconfig from the module output
locals {
  kubeconfig = module.kube-hetzner.kubeconfig
}

# Write kubeconfig to file for local kubectl access
resource "local_file" "kubeconfig" {
  content              = local.kubeconfig
  filename             = pathexpand("${var.kubeconfig_output_path}/config")
  file_permission      = "0600"
  directory_permission = "0700"
}
