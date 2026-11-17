# Offsite backup (pCloud)

Everything under `/data/k8s` (Forgejo data, Synapse data + media, both Postgres
data dirs, Traefik `acme.json`, the local `pg_dumpall` dumps, exported Secrets)
plus `/etc/rancher/k3s` is synced nightly to pCloud, **encrypted client-side**
with an rclone `crypt` remote — the pCloud side only ever sees ciphertext.

## Setup

1. Get a pCloud access token:

   ```bash
   docker run --rm -it -v ~/.config/rclone:/config/rclone rclone/rclone authorize "pcloud"
   ```

   Log in in the browser, then paste the printed `token = {...}` JSON into
   `01-secrets.template.yaml`.

2. Generate the two crypt passwords and fill them in:

   ```bash
   openssl rand -base64 32   # twice: password and password2
   ```

3. Create the remote folder once (any name — it must match `remote =` in the
   crypt section), e.g. `polarys-k8s-backups` in your pCloud.

4. Apply:

   ```bash
   cp global/offsite-backup/01-secrets.template.yaml global/offsite-backup/01-secrets.yaml
   kubectl apply -f global/offsite-backup/
   ```

## Schedule

| Time | Job | What |
|---|---|---|
| 03:15 | `matrix/pg-backup` | local `pg_dumpall` → `/data/k8s/backups/matrix/postgresql` |
| 03:45 | `git/forgejo-pg-backup` | local `pg_dumpall` → `/data/k8s/backups/forgejo/postgresql` |
| 04:00 | `backups/secrets-export` | all Secrets → `/data/k8s/backups/k8s/` (14d local retention) |
| 04:30 | `backups/offsite-sync` | rclone sync → pCloud (encrypted), 30d offsite retention |

## Verify

```bash
kubectl logs -n backups job/$(kubectl get jobs -n backups --sort-by=.metadata.creationTimestamp | tail -1 | awk '{print $1}')
# list what is actually offsite:
docker run --rm -it -v $PWD/global/offsite-backup/01-secrets.yaml:/config/rclone.conf:ro rclone/rclone ls pcloud-crypt:k8s
```

## Restore drill (do this quarterly on a scratch VM)

```bash
rclone sync pcloud-crypt:k8s /restore/data/k8s
rclone sync pcloud-crypt:etc-rancher-k3s /restore/etc/rancher/k3s
# then restore the DBs from the pg_dumpall dumps, not the raw data dirs.
```

## Notes / limits

- The raw Postgres data dirs under `/data/k8s` are copied as-is; they are only
  consistent if Postgres is stopped. The `pg_dumpall` dumps are the reliable
  DB restore path — keep both.
- k3s' etcd state (`/var/lib/rancher/k3s/server/db`) is not covered from
  inside a pod; for that, run `k3s etcd-snapshot` on the host (cron on the
  node) into `/data/k8s/backups/k3s/` and it will be picked up automatically.
- RPO = 24h, RTO = however long a restore takes. Test it before you need it.
