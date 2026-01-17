# Shared PostgreSQL Usage Guide

**Quick reference for connecting services to the shared PostgreSQL instance.**

---

## Connection Details

**Service Name:** `postgresql-shared-postgresql.database.svc.cluster.local`
**Port:** `5432`
**Secret:** `postgresql-shared-passwords` (namespace: `database`)

---

## Pre-configured Databases

| Database | User | Password Secret Key |
|----------|------|---------------------|
| `authentik` | `authentik` | `authentik-password` |
| `forgejo` | `forgejo` | `forgejo-password` |
| `paperless` | `paperless` | `paperless-password` |
| _(admin)_ | `postgres` | `postgres-password` |

---

## Connection String Format

```
postgresql://USERNAME:PASSWORD@postgresql-shared-postgresql.database.svc.cluster.local:5432/DATABASE
```

**Examples:**
```bash
# Authentik
postgresql://authentik:PASSWORD@postgresql-shared-postgresql.database.svc.cluster.local:5432/authentik

# Forgejo
postgresql://forgejo:PASSWORD@postgresql-shared-postgresql.database.svc.cluster.local:5432/forgejo

# Paperless
postgresql://paperless:PASSWORD@postgresql-shared-postgresql.database.svc.cluster.local:5432/paperless
```

---

## Service Configuration Examples

### Authentik

```yaml
authentik:
  postgresql:
    host: "postgresql-shared-postgresql.database.svc.cluster.local"
    port: 5432
    name: "authentik"
    user: "authentik"
    password: "file:///secrets/postgres/password"

server:
  volumes:
    - name: postgres-secret
      secret:
        secretName: postgresql-shared-passwords
        items:
          - key: authentik-password
            path: password
  volumeMounts:
    - name: postgres-secret
      mountPath: /secrets/postgres
      readOnly: true

worker:
  volumes:
    - name: postgres-secret
      secret:
        secretName: postgresql-shared-passwords
        items:
          - key: authentik-password
            path: password
  volumeMounts:
    - name: postgres-secret
      mountPath: /secrets/postgres
      readOnly: true

# Disable bundled PostgreSQL
postgresql:
  enabled: false
```

### Forgejo

```yaml
gitea:
  database:
    builtIn:
      postgresql:
        enabled: false

  config:
    database:
      DB_TYPE: postgres
      HOST: postgresql-shared-postgresql.database.svc.cluster.local:5432
      NAME: forgejo
      USER: forgejo
      # Password injected via environment variable

# Inject password from secret
extraEnv:
  - name: GITEA__database__PASSWD
    valueFrom:
      secretKeyRef:
        name: postgresql-shared-passwords
        key: forgejo-password
        namespace: database
```

### Paperless-NGX

```yaml
env:
  PAPERLESS_DBHOST: "postgresql-shared-postgresql.database.svc.cluster.local"
  PAPERLESS_DBPORT: "5432"
  PAPERLESS_DBNAME: "paperless"
  PAPERLESS_DBUSER: "paperless"

envFrom:
  - secretRef:
      name: paperless-db-secret

---
# Create secret referencing shared password
apiVersion: v1
kind: Secret
metadata:
  name: paperless-db-secret
  namespace: paperless
stringData:
  PAPERLESS_DBPASS: "{{ lookup('kubernetes.core.k8s', kind='Secret', namespace='database', resource_name='postgresql-shared-passwords') | json_query('data.\"paperless-password\"') | b64decode }}"
```

---

## Management Commands

### Connect to PostgreSQL

```bash
# As postgres admin
kubectl exec -it -n database postgresql-shared-postgresql-0 -- \
  psql -U postgres

# As specific user
kubectl exec -it -n database postgresql-shared-postgresql-0 -- \
  psql -U authentik -d authentik
```

### List Databases

```bash
kubectl exec -n database postgresql-shared-postgresql-0 -- \
  psql -U postgres -c "\l"
```

### List Users

```bash
kubectl exec -n database postgresql-shared-postgresql-0 -- \
  psql -U postgres -c "\du"
```

### Check Database Sizes

```bash
kubectl exec -n database postgresql-shared-postgresql-0 -- \
  psql -U postgres -c "SELECT datname, pg_size_pretty(pg_database_size(datname)) FROM pg_database ORDER BY pg_database_size(datname) DESC;"
```

### Check Active Connections

```bash
kubectl exec -n database postgresql-shared-postgresql-0 -- \
  psql -U postgres -c "SELECT datname, usename, count(*) FROM pg_stat_activity GROUP BY datname, usename ORDER BY count(*) DESC;"
```

---

## Adding a New Database

To add a new service database, edit `argocd/applications/postgresql-shared.yaml`:

1. **Add password to secret:**
   ```bash
   sops argocd/applications/postgresql-shared-secret.yaml
   # Add: myapp-password: "SECURE_PASSWORD"
   ```

2. **Add initdb script section:**
   ```yaml
   initdb:
     scripts:
       01-create-databases.sh: |
         # ... existing databases ...

         # Add new database
         MYAPP_PASSWORD="${MYAPP_PASSWORD}"
         psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" <<-EOSQL
           CREATE DATABASE myapp;
           CREATE USER myapp WITH PASSWORD '$MYAPP_PASSWORD';
           GRANT ALL PRIVILEGES ON DATABASE myapp TO myapp;
           ALTER DATABASE myapp OWNER TO myapp;
           \\c myapp
           GRANT ALL ON SCHEMA public TO myapp;
         EOSQL
   ```

3. **Add to extraEnvVars:**
   ```yaml
   extraEnvVars:
     # ... existing vars ...
     - name: MYAPP_PASSWORD
       valueFrom:
         secretKeyRef:
           name: postgresql-shared-passwords
           key: myapp-password
   ```

4. **Commit and push** - Argo CD will sync

---

## Resource Tuning

**Current Settings (for 4GB CAX11 node):**
- Memory request: 256Mi
- Memory limit: 512Mi
- shared_buffers: 128MB
- effective_cache_size: 384MB
- work_mem: 2MB

**If you upgrade to 8GB CAX21:**

Edit `postgresql-shared.yaml`:

```yaml
resources:
  requests:
    memory: 512Mi
  limits:
    memory: 1Gi

extendedConfiguration: |
  shared_buffers = 256MB
  effective_cache_size = 768MB
  work_mem = 4MB
```

---

## Backup & Restore

### Backup All Databases

```bash
kubectl exec -n database postgresql-shared-postgresql-0 -- \
  pg_dumpall -U postgres | gzip > postgres-backup-$(date +%Y%m%d).sql.gz
```

### Backup Single Database

```bash
kubectl exec -n database postgresql-shared-postgresql-0 -- \
  pg_dump -U authentik authentik | gzip > authentik-backup-$(date +%Y%m%d).sql.gz
```

### Restore Database

```bash
gunzip -c backup.sql.gz | kubectl exec -i -n database postgresql-shared-postgresql-0 -- \
  psql -U postgres
```

---

## Troubleshooting

### Check PostgreSQL Logs

```bash
kubectl logs -n database postgresql-shared-postgresql-0 --tail=100 -f
```

### Check Resource Usage

```bash
kubectl top pod -n database
```

### Test Connection

```bash
kubectl run -it --rm psql-test --image=postgres:17 --restart=Never -- \
  psql -h postgresql-shared-postgresql.database.svc.cluster.local \
       -U authentik -d authentik
```

### PostgreSQL Not Starting (OOM)

If PostgreSQL is killed due to out-of-memory:

1. Check node memory: `kubectl top nodes`
2. Reduce PostgreSQL memory limits
3. Consider upgrading to CAX21 (8GB)

---

**See also:** `docs/references/postgresql-bitnami-README.md` for full chart documentation
