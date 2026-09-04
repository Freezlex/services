# Maintenance runbook

`maintenance.sh` quiesces the cluster, dumps both PostgreSQL instances and
archives every hostPath volume into one tarball. Run it **on the node (`mako`)** —
the archive step reads `/data/k8s` directly.

```bash
./scripts/maintenance.sh down     # quiesce → dump → stop → archive
./scripts/maintenance.sh up       # restart in dependency order
./scripts/maintenance.sh dump     # dumps only, cluster stays up
./scripts/maintenance.sh status
```

## Why the ordering matters

`down` works in tiers, and the order is the whole point:

1. **Suspend the backup CronJobs.** Otherwise the 03:15 / 03:45 schedule can fire
   against a Postgres that is on its way down.
2. **Scale the app tier to 0** — synapse, mas, livekit, livekit-jwt, forgejo,
   factorio, wk, whoami, headlamp. Everything that writes to a database is here.
3. **Dump the databases.** Apps are gone, Postgres is still up, so the dump is
   taken against an idle server rather than racing live writes. This is the step
   that has to sit between 2 and 4.
4. **Scale the databases to 0.** `pg` has a `preStop` hook running
   `pg_ctl -m fast stop` with a 90 s grace period, so the data directory is left
   clean and the filesystem copy in step 6 is a valid backup.
5. **Scale Traefik to 0** last, so clients get a clean 503 from the proxy while
   the app tier drains instead of a connection reset.
6. **Archive** `/data/k8s/{matrix,forgejo,games,proxy}` plus the fresh dumps.

The dumps are produced by triggering the existing CronJobs
(`kubectl create job --from=cronjob/...`) rather than by an ad-hoc pod. That is
deliberate: the CronJob's pod template already carries the `app: pg-backup` /
`app: forgejo-pg-backup` labels that the Postgres NetworkPolicies require on
port 5432, along with the right credentials and backup PVC. A hand-rolled pod
without those labels is silently blocked at the network layer.

## What lands in the archive

`/data/k8s/backups/archives/polarys-<TS>.tar.gz`, mode `600`:

| Path in tarball | Contents |
|---|---|
| `matrix/` | Synapse media store, Postgres data dir |
| `forgejo/` | Git repositories, Postgres data dir |
| `games/` | Factorio saves |
| `proxy/` | Traefik `acme.json` — keeps your issued certs |
| `db-dumps/` | Newest `pg_dumpall` per database |
| `cluster/secrets.yaml` | Every live Secret — the authoritative copy |
| `cluster/volumes.yaml`, `cluster/all-resources.yaml` | PV/PVC bindings, workload state |
| `manifests/` | Gitignored `*secrets.yaml` + the deployed commit SHA |

**The archive contains plaintext secrets.** Encrypt it before it leaves the node:

```bash
age -p -o polarys-<TS>.tar.gz.age polarys-<TS>.tar.gz && shred -u polarys-<TS>.tar.gz
```

The script does **no automatic deletion** — it stages the dumps and secrets in a
temp directory and prints the path on exit (including when it aborts early)
rather than removing it for you. That directory also holds plaintext secrets, so
clean it up once the archive is safely written:

```bash
rm -rf /tmp/tmp.XXXXXXXXXX     # the path the run printed
```

## Applying the update

> **Never apply a namespace directory wholesale, and never use `-R`.** The
> `01-secrets.template.yaml` files declare the *same* Secret names as your real
> `01-secrets.yaml` (`pg-creds`, `mas-creds`, `traefik-dns-creds`, …), so
> `kubectl apply -f matrix/` would overwrite live credentials with `CHANGE_ME`.
> Postgres keeps serving until its next restart, then nothing can authenticate.
> Name the secret file explicitly and apply component subdirectories, which
> contain no templates.

`git/` and `k8s/` are new in this update and have **no `01-secrets.yaml` yet** —
create them first or Forgejo and Headlamp will sit in `CreateContainerConfigError`:

```bash
cp git/01-secrets.template.yaml git/01-secrets.yaml   # then fill every CHANGE_ME
cp k8s/01-secrets.template.yaml k8s/01-secrets.yaml
```

```bash
./scripts/maintenance.sh down
# verify the archive exists and the dumps inside it are non-empty
git pull                    # or: git merge dev

kubectl apply -f global/storage-class.yaml

kubectl apply -f proxy/00-namespace.yaml  -f proxy/01-secrets.yaml
kubectl apply -f proxy/traefik/ -f proxy/whoami/

kubectl apply -f matrix/00-namespace.yaml -f matrix/01-secrets.yaml
kubectl apply -f matrix/postgresql/ -f matrix/synapse/ -f matrix/mas/ -f matrix/rtc/

kubectl apply -f git/00-namespace.yaml    -f git/01-secrets.yaml
kubectl apply -f git/postgresql/ -f git/forgejo/

kubectl apply -f k8s/00-namespace.yaml    -f k8s/01-secrets.yaml
kubectl apply -f k8s/headlamp/

kubectl apply -f games/00-namespace.yaml  -f games/factorio/
kubectl apply -f wk/00-namespace.yaml     -f wk/wk/

./scripts/maintenance.sh up
```

`kubectl apply` on a Deployment resets `replicas` to the manifest value, so the
workloads you just scaled to 0 come back up as you apply them. That is fine —
`up` is idempotent and still waits for readiness in dependency order.

Three more things that bite on this particular update:

- **`git/forgejo/05-sso.yaml` is a Job, and Job specs are immutable.** If it
  already ran, `kubectl apply` fails on it. Delete the completed Job first:
  `kubectl -n git delete job forgejo-sso-mas`.
- **New NetworkPolicies** (`matrix/postgresql/05-networkpolicy.yaml`,
  `git/postgresql/05-networkpolicy.yaml`) restrict port 5432 to labelled pods.
  If anything you added talks to Postgres, it needs to be in that allow-list or
  it will hang on connect.
- **Traefik cert changes**: `proxy/traefik/01-storage.yaml` keeps `acme.json` on a
  Retain PV, so certificates survive. If you are changing the ACME config, flip to
  the staging CA server (commented at `proxy/traefik/03-deployments.yaml:50`)
  first — a mistake against production burns Let's Encrypt rate limits for a week.

After MAS or Synapse image bumps, run the migration before declaring victory:

```bash
kubectl exec -n matrix deploy/mas -- mas-cli database migrate
```

## Restoring

Databases, from a dump inside the archive:

```bash
tar -xzf polarys-<TS>.tar.gz db-dumps/
gunzip -c db-dumps/matrix-<TS>.sql.gz  | kubectl exec -i -n matrix sts/pg      -- psql -U <root-user>
gunzip -c db-dumps/forgejo-<TS>.sql.gz | kubectl exec -i -n git sts/forgejo-pg -- psql -U <root-user>
```

Whole-volume restore — the cluster must be **down** first
(`./scripts/maintenance.sh down`), or Postgres will be overwritten under a
running server:

```bash
tar -xzf polarys-<TS>.tar.gz -C /data/k8s --numeric-owner matrix forgejo games proxy
./scripts/maintenance.sh up
```

`--numeric-owner` matters: the UIDs in the archive (999 postgres, 1000 forgejo,
845 factorio) must survive extraction or the pods will fail on permissions.
