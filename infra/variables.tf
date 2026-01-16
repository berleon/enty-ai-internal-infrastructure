variable "hcloud_token" {
  description = "Hetzner Cloud API token"
  type        = string
  sensitive   = true
}

variable "cluster_name" {
  description = "Name of the Kubernetes cluster (lowercase, alphanumeric, hyphens)"
  type        = string
  default     = "ironclad-forge"
}

variable "control_plane_nodepools" {
  description = "Control plane node pools configuration"
  type = list(object({
    name        = string
    location    = string
    type        = string
    count       = optional(number, 1)
    labels      = optional(map(string), {})
    taints      = optional(list(string), [])
  }))
  default = [
    {
      name     = "control-plane"
      location = "nbg1"              # Nuremberg, Germany
      type     = "cpx21"              # 3 vCPU, 4GB RAM, ~€9/month
      count    = 1                    # Single node for cost-effective setup
      labels   = { "node-type" = "control-plane" }
      taints   = []
    }
  ]
}

variable "worker_nodepools" {
  description = "Worker node pools configuration (empty for single-node cluster)"
  type = list(object({
    name   = string
    location = string
    type   = string
    count  = optional(number, 1)
    labels = optional(map(string), {})
    taints = optional(list(string), [])
  }))
  default = []
}

variable "cluster_access" {
  description = "How the cluster is accessed externally (public or private)"
  type        = string
  default     = "public"

  validation {
    condition     = contains(["public", "private"], var.cluster_access)
    error_message = "cluster_access must be either 'public' or 'private'"
  }
}

variable "cluster_kubeconfig_path" {
  description = "Path to write kubeconfig file (if null, uses Terraform output)"
  type        = string
  default     = null
}

variable "cluster_talosconfig_path" {
  description = "Path to write talosconfig file (if null, not written)"
  type        = string
  default     = null
}
