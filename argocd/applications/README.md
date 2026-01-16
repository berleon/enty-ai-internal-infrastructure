# Argo CD Applications

This directory contains all Argo CD Application manifests.

When you add a new Application manifest here and push to git, the `app-of-apps` 
application will automatically discover and deploy it within ~3 minutes.

## Full GitOps Automation

**Workflow:**
```
1. Create app in argocd/applications/my-app.yaml
2. git add + git commit + git push
3. Argo CD auto-discovers and deploys (~3 minutes)
4. Done - no manual kubectl apply needed!
```

## Examples

### Deploy an application with secrets
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: my-app
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/my-org/my-repo.git
    targetRevision: main
    path: kustomize/my-app/  # Uses SOPS encryption automatically
  destination:
    server: https://kubernetes.default.svc
    namespace: default
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

All encrypted values in kustomization.yaml files will be auto-decrypted by Argo CD's KSOPS plugin.
