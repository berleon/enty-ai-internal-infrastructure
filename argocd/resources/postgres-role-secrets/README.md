# PostgreSQL Role Secrets

CloudNativePG requires role secrets to be `kubernetes.io/basic-auth` type with `username` and `password` keys.

## Encrypting Secrets with SOPS

After replacing the placeholder values, encrypt each file:

```bash
cd argocd/resources/postgres-role-secrets/

# Encrypt each secret file
sops -e -i forgejo-db-password.yaml
sops -e -i authentik-db-password.yaml
sops -e -i paperless-db-password.yaml
```

## Reusing Passwords Across Namespaces

To use the same password in multiple locations (e.g., `database` namespace for CloudNativePG AND `forgejo` namespace for Forgejo app):

**Step 1:** Get the encrypted password value from the original secret:
```bash
# Example: View the forgejo password from database secret
cat argocd/resources/postgres-credentials/postgres-credentials.yaml | grep "forgejo-password:"
```

You'll see something like:
```yaml
forgejo-password: ENC[AES256_GCM,data:/QrQWKa7BWPHNVlEkb/4IhIHbAoZ/w==,iv:YEhk++FgjY3t/OEsuYRXVh9MqhzQUpDVsJ4NSGYD+VM=,tag:bd+GOrQS2bN8oOY1AUjvJA==,type:str]
```

**Step 2:** Copy the EXACT encrypted value to other secret files:
```bash
# In forgejo-db-password.yaml:
password: ENC[AES256_GCM,data:/QrQWKa7BWPHNVlEkb/4IhIHbAoZ/w==,iv:YEhk++FgjY3t/OEsuYRXVh9MqhzQUpDVsJ4NSGYD+VM=,tag:bd+GOrQS2bN8oOY1AUjvJA==,type:str]

# In forgejo-postgres-secret.yaml (forgejo namespace):
forgejo-password: ENC[AES256_GCM,data:/QrQWKa7BWPHNVlEkb/4IhIHbAoZ/w==,iv:YEhk++FgjY3t/OEsuYRXVh9MqhzQUpDVsJ4NSGYD+VM=,tag:bd+GOrQS2bN8oOY1AUjvJA==,type:str]
```

**Step 3:** Encrypt the modified files with SOPS:
```bash
sops -e -i forgejo-db-password.yaml
```

SOPS will preserve the encrypted value and add its own metadata, resulting in the same password being usable in multiple locations.

## Secret Structure

Each role needs:
- **database namespace**: `kubernetes.io/basic-auth` secret with `username` + `password` (for CloudNativePG)
- **service namespace**: Custom secret structure as needed by the service (e.g., Forgejo uses `forgejo-password` key)

## Example Workflow for Forgejo

1. **Database namespace** (`argocd/resources/postgres-role-secrets/forgejo-db-password.yaml`):
   ```yaml
   type: kubernetes.io/basic-auth
   stringData:
     username: forgejo
     password: ENC[...]  # Encrypted password
   ```

2. **Forgejo namespace** (`argocd/resources/forgejo-postgres-secret/forgejo-postgres-secret.yaml`):
   ```yaml
   type: Opaque
   stringData:
     forgejo-password: ENC[...]  # Same encrypted password
   ```

Both secrets decrypt to the same password value when deployed.
