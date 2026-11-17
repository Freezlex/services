```
Internet
  └── Traefik (proxy ns)
        ├── matrix.polarys.im  ─── /_matrix/client/v3/login|logout|refresh ──► MAS
        │                    └── everything else ──────────────────────────► Synapse
        ├── auth.polarys.im    ──────────────────────────────────────────────► MAS
        ├── polarys.im/.well-known/ ────────────────────────────────────────► nginx (wk ns)
        ├── dashboard.polarys.im ──────────────────────────────────────────► Traefik dashboard
        └── k8s.polarys.im ────────────────────────────────────────────────► Headlamp (headlamp ns)
```

Redeploy all app namespaces at once (never touches kube-system, and ignores
StatefulSets/CronJobs — restart those explicitly):

```bash
for ns in matrix git proxy wk games headlamp backups; do
  kubectl rollout restart deployment -n "$ns"
done
```

## Backups

- Local: nightly `pg_dumpall` per Postgres into `/data/k8s/backups/...` (14d retention).
- Offsite: `global/offsite-backup/` syncs `/data/k8s` + `/etc/rancher/k3s` + all
  Secrets to pCloud, encrypted with rclone crypt. Setup: `global/offsite-backup/README.md`.

## Config changes

ConfigMaps/Secrets mounted with `subPath` do NOT hot-reload. Pods that render
config carry a `checksum/config` annotation — after editing a ConfigMap,
regenerate it and roll:

```bash
sha256sum git/forgejo/01-config.yaml | cut -d' ' -f1   # paste into the annotation
kubectl rollout restart deployment -n <ns> <name>
```
