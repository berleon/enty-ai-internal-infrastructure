#!/usr/bin/env python3
"""
Dashboard script to check Ironclad infrastructure health.
Displays node status, pod health, and backup status.

Requirements:
    pip install kubernetes rich

Usage:
    python3 dashboard.py
"""

import sys
import time
from datetime import datetime, timezone, timedelta

try:
    from kubernetes import client, config
    from rich.console import Console
    from rich.table import Table
    from rich.panel import Panel
    from rich.layout import Layout
    from rich.text import Text
except ImportError as e:
    print(f"Error: Missing required packages. Install with:")
    print(f"  pip install kubernetes rich")
    sys.exit(1)

console = Console()

# Status icons
ICON_OK = "🟢"
ICON_WARN = "🟡"
ICON_ERROR = "🔴"
ICON_UNKNOWN = "⚪"


def get_cluster_status():
    """Fetch cluster status from Kubernetes API"""
    try:
        config.load_kube_config()
    except config.config_exception.ConfigException:
        console.print(
            "[bold red]Error:[/bold red] Could not load kubeconfig. "
            "Make sure kubectl is configured."
        )
        sys.exit(1)

    v1 = client.CoreV1Api()
    batch_v1 = client.BatchV1Api()
    apps_v1 = client.AppsV1Api()

    # Node status
    nodes_data = []
    try:
        nodes = v1.list_node()
        for node in nodes.items:
            ready = any(
                c.type == "Ready" and c.status == "True"
                for c in node.status.conditions
            )
            status_icon = ICON_OK if ready else ICON_ERROR
            cpu = node.status.allocatable.get("cpu", "N/A")
            memory = node.status.allocatable.get("memory", "N/A")

            nodes_data.append({
                "name": node.metadata.name,
                "status": status_icon,
                "ready": ready,
                "cpu": cpu,
                "memory": memory,
            })
    except Exception as e:
        console.print(f"[bold red]Error fetching nodes:[/bold red] {e}")
        nodes_data = []

    # Backup status
    backup_info = f"{ICON_UNKNOWN} No Backup Job Found"
    backup_status = "unknown"
    backup_age_hours = None

    try:
        cronjobs = batch_v1.list_cron_job_for_all_namespaces()
        for job in cronjobs.items:
            if "backup" in job.metadata.name:
                last_time = job.status.last_schedule_time
                if last_time:
                    now = datetime.now(timezone.utc)
                    # Handle timezone-aware comparison
                    if last_time.tzinfo is None:
                        last_time = last_time.replace(tzinfo=timezone.utc)
                    diff = now - last_time
                    hours = diff.total_seconds() / 3600
                    backup_age_hours = hours

                    if hours < 25:
                        backup_info = (
                            f"{ICON_OK} Last Backup: {hours:.1f} hours ago "
                            f"({last_time.strftime('%Y-%m-%d %H:%M UTC')})"
                        )
                        backup_status = "ok"
                    else:
                        backup_info = (
                            f"{ICON_ERROR} Last Backup: {hours:.1f} hours ago! "
                            f"({last_time.strftime('%Y-%m-%d %H:%M UTC')})"
                        )
                        backup_status = "overdue"
                else:
                    backup_info = f"{ICON_WARN} Backup Job exists but never ran"
                    backup_status = "never_ran"
    except Exception as e:
        backup_info = f"{ICON_ERROR} Error checking backups: {e}"
        backup_status = "error"

    # Pod status
    pod_table = Table(
        show_header=True,
        header_style="bold magenta",
        show_lines=False,
    )
    pod_table.add_column("Namespace", style="cyan")
    pod_table.add_column("Pod Name", style="green")
    pod_table.add_column("Status")
    pod_table.add_column("Restarts", justify="right")

    try:
        pods = v1.list_pod_for_all_namespaces(
            field_selector='status.phase!=Succeeded,status.phase!=Failed'
        )

        all_healthy = True
        pod_data = []

        for pod in pods.items:
            # Skip system namespaces
            if pod.metadata.namespace in ["kube-system", "kube-node-lease", "tailscale"]:
                continue

            status = pod.status.phase
            restarts = 0
            if pod.status.container_statuses:
                restarts = sum(c.restart_count for c in pod.status.container_statuses)

            # Determine status color
            if status == "Running":
                color = "green"
                status_icon = ICON_OK
            elif status == "Pending":
                color = "yellow"
                status_icon = ICON_WARN
            else:
                color = "red"
                status_icon = ICON_ERROR
                all_healthy = False

            # Warn on high restart count
            if restarts > 5:
                all_healthy = False

            pod_data.append({
                "namespace": pod.metadata.namespace,
                "name": pod.metadata.name,
                "status": f"{status_icon} {status}",
                "restarts": str(restarts),
                "color": color,
            })

        # Sort by namespace then by name
        pod_data.sort(key=lambda x: (x["namespace"], x["name"]))

        for pod in pod_data:
            restart_color = "red" if int(pod["restarts"]) > 5 else "white"
            pod_table.add_row(
                pod["namespace"],
                pod["name"],
                pod["status"],
                f"[{restart_color}]{pod['restarts']}[/{restart_color}]",
            )

    except Exception as e:
        console.print(f"[bold red]Error fetching pods:[/bold red] {e}")
        all_healthy = False

    # Deployment status
    deployment_status = []
    try:
        deployments = apps_v1.list_deployment_for_all_namespaces()
        for deploy in deployments.items:
            if deploy.metadata.namespace in ["kube-system", "kube-node-lease", "tailscale"]:
                continue

            desired = deploy.spec.replicas or 0
            ready = deploy.status.ready_replicas or 0
            updated = deploy.status.updated_replicas or 0

            if ready == desired and updated == desired:
                status_icon = ICON_OK
                status_text = "Ready"
                color = "green"
            elif ready > 0:
                status_icon = ICON_WARN
                status_text = f"Progressing ({ready}/{desired})"
                color = "yellow"
            else:
                status_icon = ICON_ERROR
                status_text = f"Not Ready ({ready}/{desired})"
                color = "red"

            deployment_status.append({
                "namespace": deploy.metadata.namespace,
                "name": deploy.metadata.name,
                "status": f"{status_icon} {status_text}",
                "color": color,
            })

    except Exception as e:
        console.print(f"[bold yellow]Warning:[/bold yellow] Could not fetch deployments: {e}")

    return {
        "nodes": nodes_data,
        "pods": pod_table,
        "backup": backup_info,
        "backup_status": backup_status,
        "deployments": deployment_status,
        "all_healthy": all_healthy,
    }


def print_dashboard(status_data):
    """Print the status dashboard"""
    # Node status panel
    node_lines = []
    all_nodes_ready = True
    for node in status_data["nodes"]:
        node_lines.append(
            f"{node['status']} {node['name']} (CPU: {node['cpu']}, Mem: {node['memory']})"
        )
        if not node["ready"]:
            all_nodes_ready = False

    node_panel_color = "green" if all_nodes_ready else "red"
    node_panel = Panel(
        "\n".join(node_lines) if node_lines else "No nodes found",
        title="🖥️  Infrastructure",
        border_style=node_panel_color,
        expand=False,
    )

    # Backup status panel
    backup_color = "green"
    if status_data["backup_status"] == "error":
        backup_color = "red"
    elif status_data["backup_status"] == "overdue":
        backup_color = "red"
    elif status_data["backup_status"] == "never_ran":
        backup_color = "yellow"
    elif status_data["backup_status"] == "unknown":
        backup_color = "yellow"

    backup_panel = Panel(
        status_data["backup"],
        title="💾 Backup Status",
        border_style=backup_color,
        expand=False,
    )

    # Deployment status
    deploy_lines = []
    for deploy in status_data["deployments"]:
        deploy_lines.append(
            f"  [{deploy['color']}]{deploy['status']}[/{deploy['color']}] "
            f"{deploy['namespace']}/{deploy['name']}"
        )

    deploy_panel = Panel(
        "\n".join(deploy_lines) if deploy_lines else "No deployments found",
        title="📦 Deployments",
        border_style="blue",
        expand=False,
    )

    # Overall health status
    overall_status = "✓ All systems operational" if status_data["all_healthy"] else "⚠ Check warnings above"
    health_color = "green" if status_data["all_healthy"] else "yellow"

    console.print()
    console.print(node_panel)
    console.print(backup_panel)
    console.print(deploy_panel)
    console.print(status_data["pods"])
    console.print()
    console.print(
        Panel(
            overall_status,
            border_style=health_color,
            expand=False,
        )
    )
    console.print()


def main():
    """Main function"""
    try:
        with console.status("[bold green]Connecting to Kubernetes cluster...") as status:
            status_data = get_cluster_status()

        print_dashboard(status_data)

    except KeyboardInterrupt:
        console.print("\n[yellow]Interrupted by user[/yellow]")
        sys.exit(0)
    except Exception as e:
        console.print(f"[bold red]Fatal error:[/bold red] {e}", style="bold red")
        sys.exit(1)


if __name__ == "__main__":
    main()
