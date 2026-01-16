# 🏗 Project: Deploy "Ironclad" Private Git Infrastructure

**Assignee:** @Me
**Status:** To Do
**Priority:** High
**Estimated Effort:** 4–6 Hours

## 1. Context & Objective
Migrate from GitHub/Codeberg to a self-hosted, fully owned Kubernetes stack.
**The Goal:** A secure, single-node cluster that auto-updates the OS, requires no open firewall ports, and uses GitOps for configuration management.

## 2. The Stack Selection ("Why this?")

| Component | Tool | Why was this selected? |
| :--- | :--- | :--- |
| **Compute** | **Hetzner Cloud** | Best price/performance in EU (`cpx21` ~€9/mo). |
| **OS** | **MicroOS** | **Killer Feature:** Auto-updates and reboots itself safely. If an update breaks, it auto-rollbacks (via Btrfs snapshots). Zero OS maintenance. |
| **Cluster** | **K3s** | Lightweight, rock-solid, production-grade Kubernetes. |
| **Network** | **Tailscale** | **Security:** We close ALL inbound ports (80/443/22). Access is only via private VPN mesh. Includes "MagicDNS" for automatic HTTPS certificates. |
| **Git** | **Forgejo** | Community-owned fork of Gitea. Stable, supports Actions, no VC pressure. |
| **CI/CD** | **Forgejo Runner** | Self-hosted "GitHub Actions" equivalent. |
| **Management** | **Argo CD** | **GitOps:** The server state is defined in code. Prevents "configuration drift" over time. |

---

## 3. Implementation Guide

### Phase 1: Infrastructure (Terraform)
**Repo:** `mysticaltech/terraform-hcloud-kube-hetzner`

*   **Action:** Create a directory `infra`, clone the repo, and create `kube.tfvars`.
*   **Critical Config:** We disable the default Load Balancer (saving €5/mo) and public ingress because we use Tailscale.

```hcl
# kube.tfvars
cluster_name = "ironclad-forge"
hcloud_token = "YOUR_HETZNER_TOKEN"

# Single Node "Monolith" (Cheapest & Simplest)
control_plane_count = 1
control_plane_server_type = "cpx21" # 3 vCPU / 4GB RAM (Avoid ARM/cax21 for now to ensure MicroOS stability)
agent_node_pools = []

# The "Zero Maintenance" OS
image = "openSUSE MicroOS"

# Networking & K3s
enable_klipper_metal_lb = false
allow_scheduling_on_control_plane = true
enable_metrics_server = true # Needed for 'kubectl top' and auto-scaling
```

*   **Deploy:** `terraform init && terraform apply`
*   **Result:** A locked-down server running K3s. SSH is reachable only via the IP output by Terraform.

### Phase 2: The "Stealth" Network (Tailscale)
*Goal: Connect the cluster to your private network so you can access it without opening ports.*

1.  **Generate Auth Key:** Go to [Tailscale Admin](https://login.tailscale.com/admin/settings/keys) -> Generate Auth Key (Tag: `tag:k8s`, Reusable, Ephemeral).
2.  **Install Operator:** Use Helm to install the Tailscale operator.
    ```bash
    helm repo add tailscale https://pkgs.tailscale.com/helmcharts
    helm upgrade --install tailscale-operator tailscale/tailscale-operator \
      --namespace tailscale --create-namespace \
      --set-string oauth.clientId="<YOUR_OAUTH_CLIENT_ID>" \
      --set-string oauth.clientSecret="<YOUR_OAUTH_SECRET>"
    ```
3.  **Secure Your Access:**
    *   Get the new node IP from your Tailscale dashboard (e.g., `100.x.y.z`).
    *   Update your local `~/.kube/config` to point to `https://100.x.y.z:6443`.
    *   **Verify:** Run `kubectl get nodes` from your laptop. It should work.
    *   *Security Win:* You can now close port 6443 on the Hetzner Firewall if you wish (via Terraform), making the API invisible to the internet.

### Phase 3: GitOps Bootstrapping (Argo CD)
*Goal: Install the "brain" that manages the apps.*

1.  **Install Argo:**
    ```bash
    kubectl create namespace argocd
    kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
    ```
2.  **Access UI:** `kubectl port-forward svc/argocd-server -n argocd 8080:443` -> Open `https://localhost:8080`.
3.  **The Config Repo:** Create a **private GitHub repository** (e.g., `my-infra-config`). This is your "Backup Brain". If your cluster dies, this repo rebuilds it.

### Phase 4: Deploying Forgejo (The App)
*Goal: Define Forgejo in your GitHub repo so Argo CD can deploy it.*

Create file `apps/forgejo.yaml` in your config repo:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: forgejo
  namespace: argocd
spec:
  project: default
  source:
    repoURL: 'https://codeberg.org/forgejo/forgejo-helm'
    targetRevision: '9.0.0' # Pin version for stability
    chart: forgejo
    helm:
      values: |
        image:
          tag: 9.0.0
        persistence:
          enabled: true
          size: 50Gi
          storageClass: hcloud-volumes # Uses Hetzner Block Storage (Resilient)
        ingress:
          enabled: true
          className: tailscale # <--- The Magic: Auto-HTTPS via Tailscale
          hosts:
            - host: git-forge # Becomes https://git-forge.tailnet-name.ts.net
          annotations:
            tailscale.com/tags: "tag:k8s"
  destination:
    server: 'https://kubernetes.default.svc'
    namespace: forgejo
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```
*   **Deploy:** `kubectl apply -f apps/forgejo.yaml`
*   **Result:** Open `https://git-forge.tailnet-name.ts.net`. You have a working, private Git server.

### Phase 5: CI/CD Runners (The "Action" Wall Fix)
*Goal: Enable "Actions" to run docker builds.*

*   **Challenge:** Running Docker-in-Docker (dind) on K3s can be tricky.
*   **Solution:** Use the `wrenix` community chart which pre-configures dind.

1.  Get Registration Token from your new Forgejo: *Site Administration > Actions > Runners > Create Runner*.
2.  Add `apps/runner.yaml` to your config repo:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: forgejo-runner
  namespace: argocd
spec:
  project: default
  source:
    repoURL: 'oci://codeberg.org/wrenix/helm-charts'
    chart: forgejo-runner
    targetRevision: '0.6.0'
    helm:
      values: |
        runner:
          config:
            # Connect to internal K8s service to save bandwidth/latency
            url: "http://forgejo-http.forgejo.svc.cluster.local:3000"
            token: "<YOUR_TOKEN_HERE>" # Suggestion: Use a K8s Secret reference in production
            labels:
              - "ubuntu-latest:docker://node:20-bullseye"
        dind:
          enabled: true # Enables sidecar for building docker images
  destination:
    server: 'https://kubernetes.default.svc'
    namespace: forgejo-runner
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

### Phase 6: The "Sleep at Night" Backup
*Goal: If Hetzner deletes your server, you lose nothing.*

Create `apps/backup.yaml`. This CronJob dumps the DB and uploads to S3.

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: forgejo-backup-s3
  namespace: forgejo
spec:
  schedule: "0 3 * * *" # Every day at 3 AM
  jobTemplate:
    spec:
      template:
        spec:
          volumes:
            - name: backup-dir
              emptyDir: {}
            - name: data
              persistentVolumeClaim:
                claimName: data-forgejo-0 # Check exact PVC name via kubectl
          initContainers:
            - name: dump
              image: codeberg.org/forgejo/forgejo:9.0.0
              command: ["/bin/sh", "-c"]
              args: ["forgejo dump -c /data/gitea/conf/app.ini -f /backup/dump.zip"]
              volumeMounts:
                - mountPath: /data
                  name: data
                - mountPath: /backup
                  name: backup-dir
          containers:
            - name: upload
              image: minio/mc
              command: ["/bin/sh", "-c"]
              args:
                - |
                  mc alias set s3 https://s3.amazonaws.com $ACCESS_KEY $SECRET_KEY;
                  mc cp /backup/dump.zip s3/my-backup-bucket/forgejo-$(date +%F).zip;
              env:
                - name: ACCESS_KEY
                  value: "YOUR_S3_KEY"
                - name: SECRET_KEY
                  value: "YOUR_S3_SECRET"
              volumeMounts:
                - mountPath: /backup
                  name: backup-dir
          restartPolicy: OnFailure
```

---

## 4. Maintenance & "Gotchas"

1.  **Updates:** Do not manually update anything. When Forgejo releases v9.1, update the `targetRevision` in your GitHub `apps/forgejo.yaml` file. Argo CD will pull the change and update the cluster.
2.  **Monitoring:** Don't install Prometheus (it eats RAM). Use `k9s` (a CLI tool) on your laptop. It connects via Tailscale and gives you a perfect real-time dashboard of CPU/RAM usage.
3.  **Storage:** You are using `hcloud-volumes`. These are safe, network-attached drives. If the node dies, the drive survives and re-attaches to a new node.
----

You are absolutely right. Since we are building a "Set and Forget" system, you need a way to check if it's *actually* working without digging through raw kubectl logs every time.

Here is a **"Control Center"** toolkit. This includes:
1.  **`control.sh`**: A master script to manage common tasks (opening UIs, triggering backups).
2.  **`dashboard.py`**: A lightweight Python script you run locally. It connects via Tailscale, queries the K8s API, and renders a beautiful status board (including the exact age of your last backup).

### Prerequisites
Run this locally on your laptop.
```bash
# You need the python kubernetes library and 'rich' for the UI
pip install kubernetes rich
```

---

### 1. The Local Status Dashboard (`dashboard.py`)
Save this file as `dashboard.py`. It reads your local `kubeconfig` and gives you a "Mission Control" view.

**What it does:**
*   Checks if the K8s node is online.
*   Checks if all Pods (Forgejo, Runner, Argo) are healthy.
*   **Crucial:** Finds your Backup CronJob, checks when it last ran, and warns you if the backup is older than 24 hours.

```python
#!/usr/bin/env python3
import time
from datetime import datetime, timezone
from kubernetes import client, config
from rich.console import Console
from rich.table import Table
from rich.panel import Panel
from rich.layout import Layout
from rich.live import Live

console = Console()

def get_status():
    try:
        config.load_kube_config()
        v1 = client.CoreV1Api()
        batch_v1 = client.BatchV1Api()

        # 1. Node Status
        nodes = v1.list_node()
        node_status = []
        for node in nodes.items:
            cpu = node.status.allocatable["cpu"]
            mem = node.status.allocatable["memory"]
            # Simple check if Ready
            ready = any(c.type == "Ready" and c.status == "True" for c in node.status.conditions)
            status_icon = "🟢" if ready else "🔴"
            node_status.append(f"{status_icon} {node.metadata.name} (CPU: {cpu}, Mem: {mem})")

        # 2. Backup Status (The most important part)
        cronjobs = batch_v1.list_cron_job_for_all_namespaces()
        backup_info = "⚪ No Backup Job Found"
        backup_color = "red"

        for job in cronjobs.items:
            if "backup" in job.metadata.name:
                last_time = job.status.last_schedule_time
                if last_time:
                    now = datetime.now(timezone.utc)
                    diff = now - last_time
                    hours = diff.total_seconds() / 3600

                    if hours < 25:
                        backup_info = f"🟢 Last Backup: {hours:.1f} hours ago ({last_time.strftime('%Y-%m-%d %H:%M')})"
                        backup_color = "green"
                    else:
                        backup_info = f"🔴 Last Backup: {hours:.1f} hours ago! (Check Logs)"
                        backup_color = "red"
                else:
                    backup_info = "🟡 Backup Job exists but never ran"
                    backup_color = "yellow"

        # 3. Pod Health
        pods = v1.list_pod_for_all_namespaces(field_selector='status.phase!=Succeeded,status.phase!=Failed')
        pod_table = Table(show_header=True, header_style="bold magenta")
        pod_table.add_column("Namespace")
        pod_table.add_column("Pod Name")
        pod_table.add_column("Status")
        pod_table.add_column("Restarts")

        all_healthy = True
        for pod in pods.items:
            if pod.metadata.namespace in ["kube-system", "tailscale"]: continue # Skip noise

            status = pod.status.phase
            restarts = 0
            if pod.status.container_statuses:
                restarts = sum(c.restart_count for c in pod.status.container_statuses)

            # Simple visual check
            color = "green"
            if status != "Running":
                color = "red"
                all_healthy = False
            elif restarts > 5:
                color = "yellow"

            pod_table.add_row(
                pod.metadata.namespace,
                pod.metadata.name,
                f"[{color}]{status}[/{color}]",
                str(restarts)
            )

        return node_status, backup_info, backup_color, pod_table

    except Exception as e:
        return [f"Error connecting: {e}"], "Connection Failed", "red", Table()

if __name__ == "__main__":
    with console.status("[bold green]Connecting to Cluster via Tailscale...") as status:
        nodes, backup_msg, backup_col, pods = get_status()

    console.print(Panel("\n".join(nodes), title="🖥️  Infrastructure (Hetzner)", border_style="blue"))
    console.print(Panel(backup_msg, title="💾 Backup Status", border_style=backup_col))
    console.print(Panel(pods, title="📦 Application Status", border_style="white"))
```

---

### 2. The Management Script (`control.sh`)
Save this as `control.sh` and `chmod +x control.sh`. This wraps the complex kubectl commands.

```bash
#!/bin/bash

# Configuration
KUBE_CTX="default" # Or whatever your context name is
NAMESPACE="argocd"
ARGO_PORT=8080

function show_help {
    echo "Usage: ./control.sh [command]"
    echo "Commands:"
    echo "  status       Run the python dashboard"
    echo "  ui-argo      Open Argo CD (Port Forwards & Opens Browser)"
    echo "  ui-git       Open Forgejo (via Tailscale URL)"
    echo "  backup-now   Trigger an immediate manual backup"
    echo "  logs-backup  Show logs from the last backup job"
    echo "  top          Show real-time CPU/RAM usage (k9s style)"
}

case "$1" in
    status)
        python3 dashboard.py
        ;;

    ui-argo)
        echo "🔌 Port forwarding Argo CD to http://localhost:$ARGO_PORT..."
        echo "🔐 (Press Ctrl+C to stop)"
        # Opens browser in background (Mac/Linux compatible)
        (sleep 2 && (open http://localhost:$ARGO_PORT || xdg-open http://localhost:$ARGO_PORT)) &
        kubectl port-forward svc/argocd-server -n argocd $ARGO_PORT:443
        ;;

    ui-git)
        # Assumes you used the hostname 'git-forge' in your Tailscale config
        URL="https://git-forge.tailnet-name.ts.net"
        echo "🚀 Opening $URL..."
        open $URL || xdg-open $URL
        ;;

    backup-now)
        echo "💾 Triggering Manual Backup Job..."
        # Creates a one-off job from the CronJob template
        kubectl create job --from=cronjob/forgejo-backup-s3 manual-backup-$(date +%s) -n forgejo
        echo "⏳ Job started. Watch status with: ./control.sh logs-backup"
        ;;

    logs-backup)
        echo "🔍 Finding last backup job..."
        # Finds the newest pod starting with 'manual-backup' or 'forgejo-backup-s3'
        LAST_POD=$(kubectl get pods -n forgejo --sort-by=.metadata.creationTimestamp -o name | grep -E 'backup' | tail -n 1)
        if [ -z "$LAST_POD" ]; then
            echo "❌ No backup pods found."
        else
            echo "📜 Logs for $LAST_POD:"
            kubectl logs $LAST_POD -n forgejo --all-containers
        fi
        ;;

    top)
        # Requires 'kubectl top' to be working (metrics-server)
        watch "kubectl top nodes && echo '' && kubectl top pods -A --sort-by=cpu | head -n 15"
        ;;

    *)
        show_help
        ;;
esac
```

### 3. Usage Workflow

1.  **Morning Check:**
    ```bash
    ./control.sh status
    ```
    *Output:* You see a green panel saying "Last Backup: 4.2 hours ago". All good.

2.  **Something looks wrong?**
    ```bash
    ./control.sh top
    ```
    *Output:* You see Forgejo using 100% CPU.

3.  **Need to change a setting?**
    ```bash
    ./control.sh ui-argo
    ```
    *Output:* Opens Argo CD in your browser securely.

4.  **Paranoid before a big merge?**
    ```bash
    ./control.sh backup-now
    ```
    *Output:* Triggers an immediate push to S3.

### 4. Recommendation: The "Pro" Tool
If you want a *real-time* terminal UI that is better than any script I can write, install **k9s**.

```bash
# Mac
brew install k9s
# Linux
curl -sS https://webinstall.dev/k9s | bash
```

Run it simply by typing `k9s`.
*   It works perfectly over Tailscale.
*   You can press `:` and type `cronjobs` to see your backups.
*   You can press `l` to view logs instantly.
*   It is the ultimate dashboard for this specific stack.
