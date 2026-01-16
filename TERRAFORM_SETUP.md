# Terraform Setup Guide

Complete guide for deploying Ironclad infrastructure using Terraform and Hetzner Cloud.

---

## Overview

This Terraform configuration uses the **terraform-hcloud-kubernetes** module (v3.x) to provision a Talos OS Kubernetes cluster on Hetzner Cloud. The module automates:
- Server provisioning (Hetzner Cloud)
- Network setup (VPC, firewall)
- Talos OS installation and configuration
- SSL certificates
- Cloud controller manager integration

---

## Prerequisites

### 1. Install Terraform

**macOS:**
```bash
brew install terraform
```

**Linux:**
```bash
wget https://releases.hashicorp.com/terraform/1.7.0/terraform_1.7.0_linux_amd64.zip
unzip terraform_1.7.0_linux_amd64.zip
sudo mv terraform /usr/local/bin/
```

**Verify:**
```bash
terraform version
# Output: Terraform v1.7.0 (or later)
```

### 2. Install kubectl

**macOS:**
```bash
brew install kubectl
```

**Linux:**
```bash
curl -LO https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl
sudo mv kubectl /usr/local/bin/
chmod +x /usr/local/bin/kubectl
```

**Verify:**
```bash
kubectl version --client
```

### 3. Hetzner Cloud API Token

1. Sign up at https://hetzner.cloud (get €20 credit with referral)
2. Go to **Console** → **Security** → **Tokens**
3. Create a new token:
   - Name: `terraform-ironclad`
   - Permissions: `Read & Write`
4. Copy the token (you'll need it for `kube.tfvars`)

### 4. SSH Key (Generated Automatically)

The Terraform module will automatically generate an SSH key for you. No pre-setup needed.

---

## Step 1: Configure Terraform

### Create kube.tfvars

```bash
cd infra
cp kube.tfvars.example kube.tfvars
```

### Edit kube.tfvars

Open `infra/kube.tfvars` and fill in:

```hcl
# Required: Your Hetzner Cloud API token
hcloud_token = "YOUR_API_TOKEN_HERE"

# Recommended: Keep cluster name consistent
cluster_name = "ironclad-forge"

# Single node (cost-effective for testing)
control_plane_count       = 1
control_plane_server_type = "cpx21"  # 3 vCPU, 4GB RAM

# Leave empty for single-node
agent_node_pools = []

# OS with auto-updates
image = "openSUSE MicroOS"

# Settings
enable_klipper_metal_lb = false     # Disable (use Tailscale)
allow_scheduling_on_control_plane = true
enable_metrics_server = true
firewall_enabled = true
```

**Important:** Keep `kube.tfvars` in `.gitignore` - it contains your API token!

---

## Step 2: Initialize Terraform

```bash
cd infra
terraform init
```

**Output:**
```
Initializing the backend...
Initializing provider plugins...
Terraform has been successfully configured!
```

This:
- Downloads the Hetzner provider
- Downloads the terraform-hcloud-kubernetes module
- Initializes local state (`.terraform/`)

---

## Step 3: Plan the Deployment

```bash
terraform plan -var-file=kube.tfvars
```

**Review the output:**
- Should show creation of: Hetzner server, firewall, network, kubeconfig
- Check resource count (usually 10-15 resources)
- Verify `control_plane_server_type` is correct

**Example output:**
```
Plan: 14 to add, 0 to change, 0 to destroy.
```

---

## Step 4: Apply the Configuration

```bash
terraform apply -var-file=kube.tfvars
```

**You will be asked:**
```
Do you want to perform these actions?
```

Type: `yes`

**Cluster creation:** 5-10 minutes

**Waiting for:**
1. Server boot (2 min)
2. Talos OS installation (3 min)
3. Node readiness (1-2 min)

**You'll see:**
```
Apply complete! Resources created.

Outputs:
cluster_name = "ironclad-forge"
control_plane_ip = "1.2.3.4"
```

**The kubeconfig is automatically saved to** `~/.kube/config`

---

## Step 5: Verify the Cluster

```bash
export KUBECONFIG=~/.kube/config

# Check nodes
kubectl get nodes
# Output:
# NAME                    STATUS   ROLES                  AGE     VERSION
# ironclad-forge-master   Ready    control-plane,master   2m      v1.30.x

# Check pods
kubectl get pods -A

# Check cluster info
kubectl cluster-info
```

**Success!** Your Talos OS Kubernetes cluster is running.

---

## Configuration Options

### Server Types (cpx = ARM/AMD, cax = Arm64)

| Type | vCPU | RAM | Cost | Use Case |
|------|------|-----|------|----------|
| `cpx11` | 2 | 2 GB | €5 | Minimal testing |
| `cpx21` | 3 | 4 GB | €9 | **Recommended** (single-node) |
| `cpx31` | 4 | 8 GB | €17 | Small production |
| `cpx41` | 8 | 16 GB | €34 | Medium workloads |
| `cpx51` | 16 | 32 GB | €68 | Large workloads |

**Recommendation:** Start with `cpx21`, upgrade if needed.

### High Availability (HA)

For production, change:

```hcl
control_plane_count = 3
control_plane_server_type = "cpx31"

agent_node_pools = [
  {
    name              = "worker"
    server_type       = "cpx21"
    location          = "nbg1"
    count             = 2
  }
]
```

Then: `terraform apply -var-file=kube.tfvars`

---

## Managing the Cluster

### Update Talos/Kubernetes Version

```bash
# Talos OS updates automatically
# To manually verify version:
talosctl version --nodes <NODE_IP>

# Kubernetes version can be updated via kube.tfvars if needed
kubernetes_version = "1.30"  # Change to desired version
terraform apply -var-file=kube.tfvars
```

### Upgrade Server Type

```bash
# Edit kube.tfvars
control_plane_server_type = "cpx31"

# Apply (triggers server rebuild)
terraform apply -var-file=kube.tfvars
```

### Add Worker Nodes

```hcl
agent_node_pools = [
  {
    name              = "worker"
    server_type       = "cpx21"
    location          = "nbg1"
    count             = 1
  }
]

# Apply
terraform apply -var-file=kube.tfvars
```

### Access Node via SSH

```bash
# Get node IP from Terraform output
NODE_IP=$(terraform output -raw control_plane_ip)

# Access Talos node (requires talosctl, not SSH)
talosctl -n $NODE_IP version
talosctl -n $NODE_IP logs kubelet

# Note: Talos OS is immutable and doesn't allow SSH access
# Use talosctl for all node interactions
```

---

## Terraform State Management

### Local State (Default)

State stored in `infra/terraform.tfstate`

**For backups/version control:**
- ✓ Commit `terraform.tflock` (dependency lock file)
- ✗ DO NOT commit `terraform.tfstate` (contains secrets)
- ✗ DO NOT commit `kube.tfvars` (contains API token)

### Remote State (Production)

Use S3, Terraform Cloud, or other backends:

```hcl
# infra/backend.tf
terraform {
  cloud {
    organization = "my-org"
    workspaces {
      name = "ironclad"
    }
  }
}
```

Then:
```bash
terraform login  # Authenticate
terraform init   # Migrate to cloud state
```

---

## Troubleshooting

### Issue: "Error acquiring the state lock"

The state is locked (another Terraform process running).

**Fix:**
```bash
terraform force-unlock LOCK_ID  # Get ID from error message
```

### Issue: "Module version not available"

The terraform-hcloud-kubernetes module version may be outdated.

**Fix:**
```bash
# Force module download
rm -rf .terraform
terraform init
```

### Issue: Cluster creation hangs

Check Hetzner console:
- Is the server running?
- Does it show any errors?

```bash
# Check Talos logs (via talosctl)
talosctl -n NODE_IP logs kubelet -f  # Follow logs in real-time
talosctl -n NODE_IP dmesg  # System logs
```

### Issue: kubectl can't connect

```bash
# Check kubeconfig
ls -la ~/.kube/config

# Verify context
kubectl config current-context

# Test connection
kubectl cluster-info

# If still failing:
export KUBECONFIG=~/.kube/config
kubectl cluster-info --context=default
```

### Issue: Nodes not ready

```bash
# Check node status
kubectl get nodes -o wide

# Get events
kubectl get events -A --sort-by='.lastTimestamp'

# Check node logs
kubectl logs -n kube-system -l component=kubelet
```

---

## Cleanup & Destruction

### Destroy Entire Cluster

```bash
terraform destroy -var-file=kube.tfvars
# Type: yes
```

**This will delete:**
- Server instance
- Volumes
- Network resources
- SSH keys
- Everything (permanent!)

### Keep State, Destroy Cluster

```bash
# Only destroy infrastructure, keep Terraform state
terraform destroy -var-file=kube.tfvars
```

**To re-create from state:**
```bash
terraform apply -var-file=kube.tfvars
```

---

## Advanced: Custom Module Parameters

The module supports many additional options. See the [terraform-hcloud-kubernetes module documentation](https://github.com/hcloud-k8s/terraform-hcloud-kubernetes) for:
- Custom networks
- Advanced networking
- Cloud init scripts
- Custom labels/taints
- Autoscaling groups

To use custom parameters, extend `infra/variables.tf` and pass to the module in `main.tf`.

---

## Next Steps

1. ✓ Deploy Talos OS Kubernetes cluster (you are here)
2. Install Tailscale operator: see README.md
3. Install Argo CD: see README.md
4. Deploy Forgejo/Runners: see apps/
5. Enable backups: see apps/backup.yaml

---

## References

- **Module Repo:** https://github.com/hcloud-k8s/terraform-hcloud-kubernetes
- **Module Registry:** https://registry.terraform.io/modules/hcloud-k8s/kubernetes/hcloud
- **Talos OS Docs:** https://www.talos.dev/
- **Hetzner Cloud Docs:** https://docs.hetzner.cloud/
- **Terraform Docs:** https://www.terraform.io/docs/

---

**Last Updated:** 2026-01-16
