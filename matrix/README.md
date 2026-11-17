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

Exception: `MX_SIGNING_KEY` is **not** a hex string. It is an ed25519 key file
(`ed25519 <key_id> <base64>`). Generate it with Synapse:

```bash
docker run --rm -v "$PWD:/out" ghcr.io/element-hq/synapse:v1.164.2 \
  /bin/sh -c "cd /out && python -m synapse.app.homeserver \
    --config-path /dev/null --generate-keys \
    --server-name polarys.im" 2>/dev/null || true
# simpler: run `synapse --generate-keys` once and copy polarys.im.signing.key
cat polarys.im.signing.key   # paste the whole file as MX_SIGNING_KEY
```

Losing the signing key breaks federation identity — it is backed up offsite
by the `secrets-export` job (see `global/offsite-backup/README.md`).

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

Each `livekit` transport advertises two URLs, both of which must be **public** —
Synapse hands them straight to clients, so an in-cluster address silently breaks
calls:

- `url` — the SFU WebSocket URL (`wss://rtc.polarys.im/livekit/sfu`) that current
  clients connect to. Traefik terminates TLS on the `websecure` entrypoint and
  proxies `Host(`rtc.polarys.im`) && PathPrefix(`/livekit/sfu`)` to the `lk`
  Service (port 7880) over plain HTTP with the prefix stripped
  (`rtc/04-ingress.yaml`); websocket `Upgrade`/`Connection` headers are passed
  through, so `wss://` at the edge becomes plain HTTP in-cluster.
- `livekit_service_url` — the public lk-jwt-service URL. Deprecated since Synapse
  v1.161.0, kept only so older clients that don't understand `url` can still fetch
  a JWT directly. Going `url`-only requires registering lk-jwt-service as an
  application service (`io.element.msc4512.proxy_prefix: "rtc/livekit"`) with
  `experimental_features.msc4512_enabled` + `msc4502_enabled` on Synapse.

Check it is live with:

```bash
curl -s https://matrix.polarys.im/_matrix/client/versions \
  | python3 -c "import sys,json;print(json.load(sys.stdin)['unstable_features']['org.matrix.msc4140'])"
# must print True — delayed events are required for call membership
```

## Backups

`postgresql/04-backup.yaml` runs a nightly `pg_dumpall` into
`/data/k8s/backups/matrix/postgresql`, keeping 14 days locally. Everything under
`/data/k8s` (incl. these dumps and an export of all Secrets) is then synced
**encrypted** to pCloud by `global/offsite-backup/` — see its README.

Restore drill (run quarterly on a scratch VM):

```bash
# 1. stop the apps that write to the DB
kubectl scale -n matrix deploy/synapse deploy/mas --replicas=0
# 2. on a FRESH cluster the dump restores cleanly; on a non-empty one
#    pg_dumpall's CREATE DATABASE/ROLE will error — either drop them first or
#    restore with: psql -v ON_ERROR_STOP=0 and skip existing objects.
gunzip -c /data/k8s/backups/matrix/postgresql/matrix-<TS>.sql.gz \
  | kubectl exec -i -n matrix sts/pg -- psql -U <root-user> -v ON_ERROR_STOP=1
# 3. restart
kubectl scale -n matrix deploy/synapse deploy/mas --replicas=1
```

## Extracting your MAS `sub`

Headlamp's ClusterRoleBinding (`k8s/01-secrets.yaml`) needs `oidc:<sub>`.
Get an id_token for the Headlamp client and decode its `sub` claim:

```bash
# after logging in via https://k8s.polarys.im, the token is in the browser;
# or use the OAuth2 device/CLI flow against https://auth.polarys.im and:
echo "<id_token>" | cut -d. -f2 | tr '_-' '/+' | base64 -d 2>/dev/null | python3 -c "import sys,json;print(json.load(sys.stdin)['sub'])"
```

## Secrets management

`01-secrets.yaml` is listed in `.gitignore` and must never be committed.
`01-secrets.template.yaml` is safe to commit and tracks the expected structure.
