# Matrix Stack

Synapse homeserver delegating authentication to MAS (Matrix Authentication Service), running on Kubernetes with Traefik as the ingress controller and own PostgreSql instance for security purpose.

## Architecture

```
matrix ns
  ├── Synapse  ──► PostgreSQL (matrix_synapse db)
  └── MAS      ──► PostgreSQL (matrix_auth db)
```

## First-time setup

### ?. Secrets

```bash
cp 01-secrets.yaml.example 01-secrets.yaml
```

Edit `01-secrets.yaml` and fill in all `CHANGE_ME` values:

```bash
# Generate strong secrets
openssl rand -hex 32   # use once per secret field
```

For the MAS signing keys and encryption secret, run:

```bash
mas-cli config generate
```

Copy the `secrets:` block from the output into the `secrets.yaml` key inside the `mas-secrets` Secret in `01-secrets.yaml`.

### ?. Apply

```bash
kubectl apply -f 00-namespace.yaml -f 01-secrets.yaml
kubectl apply -f postgresql/
kubectl apply -f synapse/
kubectl apply -f mas/
```

### ?. MAS database migration

On first deploy, run the MAS migration after the MAS pod starts:

```bash
kubectl exec -n matrix deploy/mas -- mas-cli database migrate
```

## Secrets management

`01-secrets.yaml` is listed in `.gitignore` and must never be committed.
`01-secrets.yaml.example` is safe to commit and tracks the expected structure.
