# Matrix Stack

Synapse homeserver delegating authentication to MAS (Matrix Authentication Service), running on Kubernetes with Traefik as the ingress controller and own PostgreSql instance for security purpose.

## Architecture

```
matrix ns
  ├── Synapse     ──► PostgreSQL (matrix_synapse db)
  ├── MAS         ──► PostgreSQL (matrix_auth db)
  └── MatrixRTC   ──► LiveKit SFU + lk-jwt-service (Element Call)
```

## First-time setup

### 1. Secrets

```bash
cp 01-secrets.template.yaml 01-secrets.yaml
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

Copy the `secrets:` block from the output into the `secrets.yaml` key inside the
`mas-creds` Secret in `01-secrets.yaml`.

### 2. Apply

```bash
kubectl apply -f 00-namespace.yaml -f 01-secrets.yaml
kubectl apply -f postgresql/
kubectl apply -f synapse/
kubectl apply -f mas/
kubectl apply -f rtc/
```

### 3. MAS database migration

On first deploy, run the MAS migration after the MAS pod starts:

```bash
kubectl exec -n matrix deploy/mas -- mas-cli database migrate
```

`mas-cli server` syncs the `clients:` block from its ConfigMap into the database
on every start, so registering a new OAuth client only needs a rollout restart.

## MatrixRTC / Element Call

Transport discovery uses the MSC4519 endpoint served by Synapse, configured in
`synapse/01-config.yaml` under `matrix_rtc.transports`. Element Call 0.24.0
deprecated the older `/.well-known/matrix/client` `org.matrix.msc4143.rtc_foci`
route; that key is still published from the `wk` namespace as a fallback for
older clients and should stay until every client has moved on.

`livekit_service_url` must be the **public** lk-jwt-service URL — Synapse hands
it straight to clients, so an in-cluster address silently breaks calls.

Check it is live with:

```bash
curl -s https://matrix.polarys.im/_matrix/client/versions \
  | python3 -c "import sys,json;print(json.load(sys.stdin)['unstable_features']['org.matrix.msc4140'])"
# must print True — delayed events are required for call membership
```

## Backups

`postgresql/04-backup.yaml` runs a nightly `pg_dumpall` into
`/data/k8s/backups/matrix/postgresql`, keeping 14 days. Restore with:

```bash
gunzip -c /data/k8s/backups/matrix/postgresql/matrix-<TS>.sql.gz \
  | kubectl exec -i -n matrix sts/pg -- psql -U <root-user>
```

## Secrets management

`01-secrets.yaml` is listed in `.gitignore` and must never be committed.
`01-secrets.template.yaml` is safe to commit and tracks the expected structure.
