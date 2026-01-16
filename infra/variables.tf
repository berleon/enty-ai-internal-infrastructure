variable "hcloud_token" {
  description = "Hetzner Cloud API token"
  type        = string
  sensitive   = true
}

variable "cluster_name" {
  description = "Name of the Kubernetes cluster"
  type        = string
  default     = "ironclad-forge"
}

variable "kubernetes_version" {
  description = "Kubernetes version to deploy"
  type        = string
  default     = "1.30"
}

variable "control_plane_count" {
  description = "Number of control plane nodes (1 for single-node, 3+ for HA)"
  type        = number
  default     = 1
}

variable "control_plane_server_type" {
  description = "Server type for control plane nodes"
  type        = string
  default     = "cpx21" # 3 vCPU, 4GB RAM
}

variable "agent_node_pools" {
  description = "List of worker node pools (empty list = single-node cluster)"
  type        = list(any)
  default     = []
}

variable "image" {
  description = "OS image to use (MicroOS for auto-updates)"
  type        = string
  default     = "openSUSE MicroOS"
}

variable "enable_klipper_metal_lb" {
  description = "Enable Klipper Metal Load Balancer (disable if using Tailscale Ingress)"
  type        = bool
  default     = false
}

variable "allow_scheduling_on_control_plane" {
  description = "Allow pods to schedule on control plane nodes"
  type        = bool
  default     = true
}

variable "enable_metrics_server" {
  description = "Enable metrics-server for kubectl top and pod autoscaling"
  type        = bool
  default     = true
}

variable "firewall_kube_api_in_port" {
  description = "Port for Kubernetes API (usually 6443)"
  type        = number
  default     = 6443
}

variable "firewall_enabled" {
  description = "Enable Hetzner Cloud Firewall (recommended: true)"
  type        = bool
  default     = true
}

variable "kubeconfig_output_path" {
  description = "Path to write kubeconfig file"
  type        = string
  default     = "~/.kube"
}
