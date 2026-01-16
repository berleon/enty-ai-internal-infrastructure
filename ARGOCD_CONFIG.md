# Argo CD Configuration Management

This document explains how Argo CD's own configuration is managed via Kustomize and GitOps.

## Overview

Instead of manually patching Argo CD components, all configuration is version-controlled in `argocd/config/`:

- `kustomization.yaml` - Kustomize base that applies patches
- `patches/argocd-cm.yaml` - Argo CD ConfigMap (kustomize settings, SOPS config)
- `patches/repo-server-deployment.yaml` - repo-server deployment (volume mounts, env vars for SOPS/age)

## Applying the Configuration

### Initial Bootstrap (Manual)

Since Argo CD needs to exist before it can manage itself, apply the configuration manually once:

```bash
# From repo root:
kubectl kustomize argocd/config/ | kubectl apply -f -
```

This will:
1. Patch argocd-cm with kustomize options
2. Mount sops-age secret in repo-server
3. Set AGE_KEYFILE environment variable
4. repo-server will restart automatically

### Ongoing Management (GitOps)

Once bootstrapped, you can optionally create an Application to manage Argo CD's own configuration:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: argocd-config
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/berleon/enty-ai-internal-infrastructure.git
    targetRevision: main
    path: argocd/config
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

## What This Enables

With this configuration, Argo CD can:
- ✅ Decrypt SOPS-encrypted files using the age key
- ✅ Execute kustomize builds with KSOPS plugin support
- ✅ Automatically decrypt secrets before deploying applications

## Troubleshooting

If SOPS decryption still doesn't work:

1. **Verify age key is mounted:**
   ```bash
   kubectl exec -it deployment/argocd-repo-server -n argocd -- ls -la /tmp/age-keys/
   ```

2. **Verify AGE_KEYFILE is set:**
   ```bash
   kubectl exec -it deployment/argocd-repo-server -n argocd -- env | grep AGE_KEYFILE
   ```

3. **Check if KSOPS binary is available:**
   ```bash
   kubectl exec -it deployment/argocd-repo-server -n argocd -- which ksops
   ```

   If not found, KSOPS needs to be installed in the container image.

## Next Steps

If KSOPS binary isn't available, we need to either:
- Use a custom Argo CD image with KSOPS pre-installed
- Add an init container that installs KSOPS
- Use an alternative secret management solution (External Secrets Operator, Sealed Secrets, etc.)
