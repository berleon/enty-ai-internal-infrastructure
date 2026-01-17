# ArgoCD Layered GitOps Structure

This directory contains all Kubernetes application manifests managed by Argo CD using a **layered app-of-apps pattern**.

## 📐 Architecture

Applications are organized into **3 dependency layers** with explicit sync ordering:

```
┌─────────────────────────────────────────────────────────────┐
│  Layer 1: Infrastructure (sync wave 0)                      │
│  ├─ Argo CD configuration                                   │
│  ├─ PostgreSQL Operator (CloudNative-PG)                    │
│  └─ Tailscale Operator (VPN mesh)                           │
└─────────────────────────────────────────────────────────────┘
              ↓ Dependencies flow downward
┌─────────────────────────────────────────────────────────────┐
│  Layer 2: Platform (sync wave 1)                            │
│  ├─ PostgreSQL Cluster (shared database)                    │
│  ├─ Backup Services (S3 backups)                            │
│  └─ Shared Secrets (GitHub credentials)                     │
└─────────────────────────────────────────────────────────────┘
              ↓
┌─────────────────────────────────────────────────────────────┐
│  Layer 3: Apps (sync wave 2)                                │
│  ├─ Forgejo (Git server)                                    │
│  └─ Authentik (SSO provider)                                │
└─────────────────────────────────────────────────────────────┘
```

## 🗂️ Directory Structure

```
argocd/
├── app-of-apps.yaml                    # Root application (syncs 3 layers)
├── install/                            # Argo CD installation config
│   ├── kustomization.yaml
│   └── patches/
│       ├── repo-server-ksops.yaml      # KSOPS plugin for secret decryption
│       └── resource-limits.yaml        # Memory optimization for 4GB node
│
├── infrastructure/                     # Layer 1: Core operators
│   ├── app-of-apps.yaml
│   ├── argocd/
│   ├── postgres-operator/
│   └── tailscale-operator/
│
├── platform/                           # Layer 2: Shared services
│   ├── app-of-apps.yaml
│   ├── postgres-cluster/
│   ├── backup/
│   └── shared-secrets/
│
└── apps/                               # Layer 3: User applications
    ├── app-of-apps.yaml
    ├── forgejo/
    └── authentik/
```

See full directory tree in the repository.

## 🔄 How It Works

### 1. Root App-of-Apps

The root `app-of-apps.yaml` syncs the 3 layer app-of-apps with explicit ordering:

```yaml
sources:
  - path: argocd/infrastructure/
    include: 'app-of-apps.yaml'  # Sync wave 0

  - path: argocd/platform/
    include: 'app-of-apps.yaml'  # Sync wave 1

  - path: argocd/apps/
    include: 'app-of-apps.yaml'  # Sync wave 2
```

### 2. Layer App-of-Apps

Each layer's `app-of-apps.yaml` auto-discovers applications:

```yaml
source:
  path: argocd/infrastructure/
  directory:
    recurse: true
    exclude: 'app-of-apps.yaml'
```

### 3. Application Structure

Each service has all resources co-located:

```
apps/forgejo/
├── application.yaml            # Main app (Helm chart)
├── secrets/                    # SOPS-encrypted secrets
│   ├── oauth/
│   └── postgres/
└── ingress/                    # Tailscale ingress
```

## 🚀 Adding a New Application

```bash
# 1. Create directory in appropriate layer
mkdir -p argocd/apps/my-app

# 2. Create Application manifest
cat > argocd/apps/my-app/application.yaml <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: my-app
  namespace: argocd
spec:
  project: default
  source:
    repoURL: oci://registry.example.com/my-app
    chart: my-app
  destination:
    server: https://kubernetes.default.svc
    namespace: my-app
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
EOF

# 3. Commit and push
git add argocd/apps/my-app/
git commit -m "feat(apps): add my-app"
git push

# 4. Watch Argo CD auto-sync (~3 minutes)
kubectl get applications -n argocd -w
```

## 🔐 Secret Management

All secrets use **SOPS encryption** with **KSOPS**:

```bash
# Create encrypted secret
sops -e /tmp/my-secret.yaml > argocd/apps/my-app/secrets/my-secret.yaml

# Edit encrypted secret
sops argocd/apps/my-app/secrets/my-secret.yaml

# View decrypted
sops -d argocd/apps/my-app/secrets/my-secret.yaml
```

## 📊 Benefits

- **Co-location** - All resources for a service in one directory
- **Explicit dependencies** - Sync waves ensure correct order
- **Scalability** - Add services without cluttering root
- **Discoverability** - Easy to find service resources
- **Auto-discovery** - Commit new app → auto-deploys

## 🔍 Troubleshooting

```bash
# Check application status
kubectl get application my-app -n argocd -o yaml

# Force sync
kubectl patch application my-app -n argocd \
  --type=merge -p '{"operation":{"sync":{"force":true}}}'

# Check KSOPS
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-repo-server

# Verify sync waves
kubectl get application -n argocd -o custom-columns=\
NAME:.metadata.name,\
WAVE:.metadata.annotations."argocd\.argoproj\.io/sync-wave"
```

## 📚 Further Reading

- [Argo CD App of Apps Pattern](https://argo-cd.readthedocs.io/en/stable/operator-manual/cluster-bootstrapping/)
- [Sync Waves and Phases](https://argo-cd.readthedocs.io/en/stable/user-guide/sync-waves/)
- [KSOPS Plugin](https://github.com/viaduct-ai/kustomize-sops)
- [SOPS Encryption Guide](../SOPS.md)

## 🔄 Migration History

**2026-01-17:** Migrated from flat structure to layered organization using `scripts/migrate-argocd-structure.sh`.
