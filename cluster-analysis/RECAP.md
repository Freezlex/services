# Homelab K8s review — improvement plan

I read all 78 manifests across `global`, `loadbalancer`, `proxy`, `git`, `matrix`, `k8s`, `wk`, and `games`. I haven't changed anything.

One caveat: `kubectl` currently points at an unreachable minikube context, so I couldn't inspect the live cluster. Some findings depend on facts not in the repo (node count, CNI, k3s version, what is exposed to the internet). I've marked those as **verify**.

**Overall:** the structure is good and the security intent is clearly there — namespace separation, SSO via MAS, probes/limits, backups with retention. The real risks are platform-level, not app-level: storage isn't node-aware, backups aren't offsite or file-level, the CI runner is root-equivalent, and config/secret changes don't roll out. Those are the things that will bite you during a node failure, an upgrade, or a compromised account. Most fixes are incremental.

---

## Top breaking points

| # | Breaking point | What happens | Severity |
|---|---|---|---|
| 1 | `hostPath` PVs without node affinity | Pod rescheduled to another node → empty data dir, apparent data loss; backup CronJob writes to a different node | 🔴 Critical |
| 2 | Backups are same-disk, DB-only | Disk/node loss loses data **and** backups; Forgejo repos, Synapse media, signing keys, k3s state not backed up | 🔴 Critical |
| 3 | Open MAS registration + auto-provisioning + privileged dind | Anyone can create an account → repo → workflow → root on the node | 🔴 Critical |
| 4 | Flat network / missing NetworkPolicies | Any compromised pod can reach Postgres, Synapse, MAS, the API, and the LAN | 🔴 Critical |
| 5 | ConfigMap/Secret changes don't roll out | `kubectl apply` silently does nothing; the "restart everything" workaround causes outages | 🟠 High |
| 6 | Manual MAS migrations + short startup probes | Fresh deploy/upgrade breaks login; migrations can be killed mid-flight | 🟠 High |
| 7 | Wrong `MX_SIGNING_KEY` generation docs | Synapse won't start if followed; federation identity at risk | 🟠 High |
| 8 | Postgres major upgrade in place | New major can't read the old data dir; data-loss risk | 🟠 High |
| 9 | Traefik single replica + `Recreate` + no priority | Full outage on every change; evicted under memory pressure | 🟠 High |
| 10 | No monitoring/alerting | Disk full, cert expiry, backup failure go unnoticed | 🟠 High |
| 11 | Open admin endpoints + no rate limit/MFA | Brute force / admin exposure | 🟠 High |
| 12 | `externalTrafficPolicy: Cluster` | Client IPs lost; rate limits, audit logs, IP allowlists are ineffective | 🟡 Medium-High |
| 13 | Factorio `stable` + `Always` | Unplanned game upgrade can break saves | 🟡 Medium-High |
| 14 | Forgejo SSO init race | Fresh install/DR needs a manual restart | 🟡 Medium |
| 15 | `envsubst`/SQL quoting | Secrets containing `$` or `'` break startup | 🟡 Medium |
| 16 | No PriorityClass/quotas/ephemeral-storage | Noisy neighbor / eviction | 🟡 Medium |
| 17 | No GitOps/CI | Drift, manual errors, dangerous redeploy command | 🟡 Medium |
| 18 | Secrets manual sync/rotation | SSO breaks on rotation; repo can't rebuild the cluster | 🟡 Medium |
| 19 | No staging/restore drill | Upgrades and DR are untested | 🟡 Medium |
| 20 | k3s/DNS/router config not in repo | Rebuild is not reproducible | 🟡 Medium |

---

## 1. Critical — data loss / node compromise

### 1.1 Storage is not node-aware

Every PV is `hostPath` with `kubernetes.io/no-provisioner` (`global/storage-class.yaml`, all `*/00-storage.yaml`). `hostPath` is invisible to the scheduler: it can place a pod on any node, and `DirectoryOrCreate` silently creates an empty directory. Only Forgejo, the runner, and LiveKit have `nodeSelector: mako`; Postgres, Synapse, Traefik ACME, Factorio, and **both backup CronJobs** do not.

If the cluster has more than one node, a rescheduled pod can come up with an empty database or repo store. Worse, the backup CronJob can run on a different node and write to that node's `/data/k8s/backups`, so retention and restores see different data. Even on one node, a node rename/rebuild breaks the `mako` selector and the PVs.

**Fix:** switch `hostPath` → `local` with `nodeAffinity`, or use k3s's `local-path` provisioner with a custom path. Add `nodeSelector`/`nodeAffinity` to **every** workload that mounts a local PV, including the backup CronJobs. Remove `DirectoryOrCreate` so a typo fails loudly. Add `fsGroupChangePolicy: OnRootMismatch`.

```yaml
spec:
  local:
    path: /data/k8s/matrix/postgresql
  nodeAffinity:
    required:
      nodeSelectorTerms:
        - matchExpressions:
            - key: kubernetes.io/hostname
              operator: In
              values: ["mako"]
```

Also note: `capacity` on a `hostPath` PV is cosmetic — the disk is shared. Add disk/inode alerts.

### 1.2 Backups are not a disaster-recovery plan

The DB dumps are a good start, but they only cover Postgres (`matrix/postgresql/04-backup.yaml`, `git/postgresql/04-backup.yaml`). Not backed up:

- Forgejo repos, LFS, attachments, packages, Actions artifacts (`/data/k8s/forgejo/data`)
- Synapse media (`/data/k8s/matrix/synapse/media_store`)
- Traefik ACME state (`/data/k8s/proxy/traefik/letsencrypt`)
- Synapse signing key (`MX_SIGNING_KEY`), MAS signing/encryption keys (`mas-creds`)
- Forgejo `SECRET_KEY`, `INTERNAL_TOKEN`, LFS JWT, runner token
- k3s state (`/var/lib/rancher/k3s/server/db` or etcd snapshots), `/etc/rancher/k3s`
- The real secrets (gitignored, only on the node)

Backups live on the **same host** as the data, so a disk/node failure loses both. There is no offsite copy, no encryption, and no restore test. The Matrix README's restore command will also fail on a non-empty cluster because `pg_dumpall` includes `CREATE DATABASE`/`CREATE ROLE`, and it doesn't stop Synapse/MAS first.

**Fix:** host-level `restic`/Borg to S3/B2/Scaleway Object Storage covering `/data/k8s`, `/etc/rancher/k3s`, and k3s snapshots; encrypted, offsite, with retention. Add `forgejo dump` (or restic) for repos/LFS/attachments/packages. Keep the logical `pg_dumpall` for fast DB restores, but encrypt it and copy it offsite. Back up the signing keys and secrets. Write a real restore runbook and test it quarterly on a clean VM. Define RPO/RTO.

Note: `pg_dumpall` is not a consistent cross-database snapshot — Synapse and MAS are separate DBs. For a homelab that's usually acceptable, but document it. If consistency matters, use `pg_basebackup`/WAL or dump each DB in a transaction.

### 1.3 The CI runner is root-equivalent

`git/forgejo-runner/02-deployment.yaml` runs a privileged `docker:28-dind` with `DOCKER_TLS_CERTDIR=""`, `--tls=false`, and `tcp://0.0.0.0:2375`. The NetworkPolicy denies ingress, but if the policy is misconfigured or the CNI doesn't enforce it, the Docker daemon is unauthenticated cluster-wide. Even with the policy, any job container can reach the daemon and create a privileged container → root on the node. `container.privileged: false` does not mitigate this; the dind daemon is the privileged component.

The runner also lives in the `git` namespace alongside Forgejo and its secrets, and shares a 30 GiB PVC between `/var/lib/docker` and runner data.

**Fix:** treat any repo that can run Actions as root-equivalent. Options, in order of preference:

1. Dedicated runner node/VM with a taint/toleration, no other workloads.
2. Rootless dind with user namespaces.
3. A Kubernetes-native/ephemeral runner that doesn't expose a Docker socket.
4. At minimum: TLS + client certs on the Docker socket, a socket proxy with API restrictions, a separate `ci` namespace, no untrusted PR workflows, and a dedicated PVC for dind.

Also restrict egress to the registries/actions you actually use, not all public internet, and verify the NetworkPolicy with a test pod. Move the runner out of `git` so PSA can keep `git` at `baseline`/`restricted` and the runner at `privileged`.

### 1.4 Open registration + auto-provisioning

`matrix/mas/00-config.yaml` lines 47–49:

```yaml
password_registration_enabled: true
registration_token_required: false
password_registration_email_required: true
```

Anyone who can reach `auth.polarys.im` can create an account (email verification required). `git/forgejo/01-config.yaml` has `ENABLE_AUTO_REGISTRATION = true` (under `[oauth2_client]`, which controls OAuth2 auth-source auto-registration), `DISABLE_REGISTRATION = false`, and `ALLOW_ONLY_EXTERNAL_REGISTRATION = true` — so any MAS account can auto-create a Forgejo account.

Combined with the runner, that's a path from "anyone on the internet" to "root on the node": create account → create repo → run workflow → privileged dind. Even without the runner, it lets strangers into your forge and CI.

**Fix:** close MAS registration (disable password registration or require a registration token/invite), or restrict it to an allowlist/email domain. If you need self-service, put it behind a VPN/invite. In Forgejo, either keep auto-registration but only for trusted MAS accounts, or disable auto-registration and create users manually. Audit existing Forgejo users. Add MFA to the admin accounts.

The `[oauth2_client] ENABLE_AUTO_REGISTRATION` setting itself is the right knob for OAuth2 auth sources; the issue is **who can get a MAS account**.

### 1.5 The network is flat

Only `git/postgresql` and `git/forgejo-runner` have NetworkPolicies. `matrix`, `proxy`, `headlamp`, `games`, and `wk` have none. Any compromised pod (Factorio, nginx, whoami, a Forgejo job) can reach Postgres, Synapse, MAS, the kubelet/API, and the LAN. The `git` Postgres policy also has a dead `app: forgejo-sso` rule (`git/postgresql/05-networkpolicy.yaml:22`).

The runner's egress policy is both too broad and too narrow: it allows all public internet except private ranges (exfiltration), but if `git.polarys.im` resolves to `192.168.1.200`, the runner can't reach Forgejo. The `app: forgejo` pod rule is unused because the runner uses the external URL.

**Fix:** default-deny ingress/egress per namespace, then allow DNS, required services, and public internet only where needed. Block `169.254.169.254`, `100.64.0.0/10`, and LAN ranges from pods that don't need them. For the runner, allow the Forgejo service/VIP and the specific registries/actions. Add policies for `matrix` (Synapse/MAS/Postgres/LiveKit), `proxy` (oauth2-proxy, Traefik dashboard), `headlamp`, `games`, and `wk`.

k3s includes kube-router's NetworkPolicy controller by default, so these should be enforced — but verify with a test pod, and make sure `--disable-network-policy` isn't set. If you switch CNI, install a policy engine.

---
## 2. High — upgrade and operational breakage

### 2.1 ConfigMap/Secret changes don't roll out

ConfigMaps/Secrets are mounted or rendered, but changing them does not restart pods. `git/forgejo` renders `app.ini` to the PVC; `matrix/synapse` renders `homeserver.yaml` to the PVC; `matrix/mas` renders to an emptyDir; `matrix/rtc` renders to an emptyDir; `wk` mounts a ConfigMap. `subPath` mounts (`matrix/mas` secrets, `matrix/synapse` signing key/log config, `git/forgejo` app.ini) never receive updates.

So `kubectl apply` a config change and nothing happens. The root README's "restart everything" command is the workaround — and it restarts every Deployment in every namespace, including `kube-system`, while ignoring StatefulSets and CronJobs.

**Fix:** add a checksum annotation to pod templates (Helm/Kustomize `configMapGenerator`), or deploy Reloader/Stakater to restart on ConfigMap/Secret changes. Avoid `subPath` for configs that change; mount the directory or use a projected volume. Render configs to an emptyDir, not the PVC, where possible. Document that signing keys require a restart.

### 2.2 Migrations and startup probes

`matrix/README.md` requires `kubectl exec -n matrix deploy/mas -- mas-cli database migrate` on first deploy. If the MAS pod is crash-looping because the schema is missing, `kubectl exec` may fail; GitOps can't reproduce this. Upgrades can require migrations before the new version starts.

`matrix/synapse/02-deployment.yaml` has a startupProbe of 30 × 5s = 150s. Synapse migrations on a large DB can take longer; if the startupProbe fails, the container is killed mid-migration. `git/forgejo/02-deployment.yaml` has **no** startupProbe; liveness starts at 20s and fails after 5 × 15s = 95s, which can kill Forgejo during a migration.

**Fix:** run MAS migrations in a Job (`mas-cli database migrate`) before the Deployment, via Argo CD sync wave or Flux `dependsOn`; add `mas-cli config check` as a validation step. Increase Synapse's startupProbe to 10–30 minutes for upgrades; add a Forgejo startupProbe with a generous threshold (5–10 minutes). Keep liveness gated by startup. Document that Synapse/MAS/Forgejo migrations are one-way.

### 2.3 Synapse signing key

`matrix/README.md` says "generate strong secrets: `openssl rand -hex 32`" for all fields, including `MX_SIGNING_KEY`. A Synapse signing key is **not** a 32-byte hex string; it's an ed25519 key file in the format `ed25519 <key_id> <base64>`. If you followed the README for this field, Synapse would fail to start. If your current key is valid, the doc is still a trap for the next rebuild.

**Fix:** document the correct generation (Synapse's `--generate-keys` or the `signedjson` helper), verify the current key format, and back up the key. Losing it breaks federation identity. Also back up MAS's `secrets.yaml` (encryption + signing keys); losing those breaks SSO/tokens.

### 2.4 PostgreSQL upgrades

`git/postgresql/02-deployment.yaml` mounts the PVC at `/var/lib/postgresql` with `subPath: pgdata` and relies on the postgres:18 default `PGDATA=/var/lib/postgresql/18/docker`. `matrix/postgresql/02-deployment.yaml` sets `PGDATA=/var/lib/postgresql/data/pgdata` and mounts at `/var/lib/postgresql`. Both can work with postgres:18 (the image changed the default layout), but the inconsistency makes restores/upgrades error-prone.

More important: **never bump the Postgres major tag in place.** `postgres:19` will not read an 18 data directory; the pod will fail or initialize a new cluster, and the `Retain` PV will hold the old data. Changing `POSTGRES_PASSWORD` after first init also does not rotate the DB password.

**Fix:** set `PGDATA` explicitly in both, align the layouts, and document a major-upgrade procedure (dump/restore or `pg_upgrade`) with a test. Add `postgres_exporter`, tune `shared_buffers` for the 512Mi limit, add `fsGroupChangePolicy`, `priorityClassName`, node pinning, and a default-deny egress policy (DNS only). Add `pgBackRest`/WAL if you want PITR.

### 2.5 Traefik is a single point of failure

`proxy/traefik/03-deployments.yaml` has 1 replica, `strategy: Recreate`, no `priorityClassName`, and no `terminationGracePeriodSeconds`/preStop. Every config change/upgrade is a full outage for HTTP, Forgejo SSH, Factorio UDP, and LiveKit signaling. Under memory pressure, Traefik can be evicted before Factorio. The ACME `acme.json` on a single PVC forces `Recreate`.

**Fix:** add `priorityClassName: homelab-critical` (or `system-cluster-critical`), `terminationGracePeriodSeconds: 60`, and a preStop sleep if you move to RollingUpdate. For HA: cert-manager + 2 replicas + PDB + topology spread + `externalTrafficPolicy: Local` + MetalLB on multiple nodes. If you keep 1 replica, document the downtime and back up `acme.json`. Consider moving Factorio UDP to its own MetalLB service to decouple game traffic from Traefik.

### 2.6 No monitoring or alerting

There is no Prometheus/Grafana/Alertmanager, no node-exporter/kube-state-metrics, no log aggregation, and no uptime checks. Traefik exposes metrics (`--metrics.prometheus=true`) but nothing scrapes them. You'll find out about a full disk, expired cert, failed backup, or OOMKill only when a user complains.

**Fix:** deploy a lightweight stack (VictoriaMetrics or Prometheus + Grafana + Alertmanager; node-exporter, kube-state-metrics, blackbox-exporter; Loki + Alloy for logs). Alerts for:

- disk/inode > 80/90%
- certificate expiry < 14 days
- backup age > 26h
- pod restarts / CrashLoopBackOff
- node NotReady
- Traefik 5xx rate
- Postgres connections/disk
- Synapse federation errors
- MAS login errors
- LiveKit TURN failures
- MetalLB speaker down

Dashboards for cluster/Traefik/Postgres/Synapse/Forgejo/LiveKit. Uptime probes for all public endpoints and the `.well-known` files. Add a simple `ntfy`/email receiver.

### 2.7 Admin surface, rate limiting, MFA

`matrix/synapse/04-ingress.yaml` exposes `polarys.im/_synapse/` publicly (admin API; app-level token required, but still exposed). `matrix/mas/03-ingress.yaml` exposes `/_mas/admin` publicly, and the `mas-adminapi` route is redundant with the `mas` route — it adds no protection. The Traefik dashboard is behind oauth2-proxy, but the login page is public. There is no rate limiting on Forgejo/MAS/oauth2-proxy, Forgejo SSH is public on port 22, and no MFA is mentioned.

**Fix:** remove the `/_synapse/` route unless needed; if needed, add an `ipAllowList` (LAN/VPN) and rate limit. Remove the redundant `mas-adminapi` route or add auth. Put admin UIs behind a VPN (WireGuard/Tailscale) or an IP allowlist. Add Traefik `rateLimit` on auth/login endpoints. Add fail2ban/nftables for SSH. Enable MFA for the MAS/Forgejo admin accounts. Add CAA/SPF/DKIM/DMARC for `polarys.im` (MAS sends email).

### 2.8 Client IPs are lost

`proxy/traefik/04-services.yaml` uses the default `externalTrafficPolicy: Cluster`, so kube-proxy SNATs; Traefik sees the node IP, not the client. Forgejo's `REVERSE_PROXY_TRUSTED_PROXIES` trusts private ranges, and Traefik's `X-Forwarded-For` contains the node IP. Matrix federation, Forgejo audit logs, and any IP-based rate limiting/allowlist see the wrong IP.

**Fix:** set `externalTrafficPolicy: Local` on the Traefik service and ensure Traefik runs on the node that advertises the MetalLB IP (pin both to `mako` with `L2Advertisement` node selectors, or run Traefik on all nodes). With multiple nodes and L2, `Local` requires endpoints on the advertising node — document the trade-off. Alternatively, accept the loss and don't rely on client IPs for security.

### 2.9 Forgejo SSO registration race

`git/forgejo/02-deployment.yaml` runs `register-mas-sso` as an init container before the main Forgejo container. On a fresh DB, the schema may not exist yet; the command fails, logs a warning, exits 0, and only retries on the next pod restart. First-time setup/DR requires a manual restart. The `admin auth list | awk '{print $2}'` check is brittle.

**Fix:** move it to a Job that waits for `forgejo admin auth list` to succeed, checks idempotently, and retries with `backoffLimit`; run it after Forgejo is ready (sync wave). Or use a `postStart` hook with retries. Document the manual fallback.

### 2.10 `envsubst` and SQL quoting

`envsubst` without a variable whitelist substitutes any `$` in configs/SQL. Passwords containing `$` get mangled. `init.sql` embeds passwords in single quotes; a `'` in a password breaks the SQL or allows injection. `openssl rand -hex 32` avoids this, but the templates don't enforce it.

**Fix:** use `envsubst '${VAR1} ${VAR2} ...'` with an explicit list; use `psql -v` + `:'var'` quoting or `quote_literal` for SQL; restrict generated secrets to `[A-Za-z0-9]` or escape properly. Add a startup validation.

### 2.11 Factorio upgrades

`games/factorio/01-deployment.yaml` uses `factoriotools/factorio:stable` with `imagePullPolicy: Always` — every pod restart may pull a new Factorio version, and major upgrades can break saves. There is no readiness probe, no `terminationGracePeriodSeconds`/preStop, and no NetworkPolicy.

**Fix:** pin the version (`factoriotools/factorio:2.0.x`), use `IfNotPresent`, and upgrade explicitly with a save backup. Add a readiness probe (`pgrep`), `terminationGracePeriodSeconds: 120`, `securityContext`, `automountServiceAccountToken: false`, `priorityClassName: homelab-low`, and a NetworkPolicy. Consider a dedicated MetalLB UDP service instead of Traefik.

### 2.12 No priority classes, quotas, or ephemeral-storage limits

There is no `PriorityClass`, `ResourceQuota`, `LimitRange`, or `ephemeral-storage` request/limit. Under memory pressure, the kubelet may evict Traefik/Postgres before Factorio; a runaway dind/Factorio/Synapse can fill the node disk (hostPath PVs share the same disk).

**Fix:** add `homelab-critical`/`homelab-standard`/`homelab-low` PriorityClasses; assign Traefik/Postgres/Synapse/MAS/Forgejo critical, Factorio/whoami low. Add per-namespace `ResourceQuota` and `LimitRange`; set `ephemeral-storage` requests/limits and `emptyDir.sizeLimit`. Add disk/inode alerts.

---

## 3. Medium — reproducibility and hardening

### 3.1 GitOps and CI

Manual `kubectl apply`, no Kustomize/Helm, no `kustomization.yaml`, no CI validation, no Renovate. The root README's redeploy command restarts every Deployment in every namespace (including `kube-system`) and ignores StatefulSets/CronJobs — it's a full-outage button. The `app.kubernetes.io/managed-by: gitops` label is misleading because there's no GitOps controller.

**Fix:** Flux or Argo CD; Kustomize overlays or Helm; sync waves/dependsOn (namespaces → CRDs → MetalLB → Traefik → storage → secrets → Postgres → apps → monitoring); prune/self-heal; Renovate for image updates. CI: `kubeconform -strict`, `yamllint`, `kustomize build`/`helm template`, `gitleaks`, `trivy config`, `conftest`, `shellcheck`. Replace the README command with `make diff/apply/restart` targets.

### 3.2 Secrets

The real secrets are gitignored and live only on the node, so the repo can't rebuild the cluster. Shared OAuth client secrets are duplicated in `matrix-creds`, `forgejo-creds`, `headlamp-creds`, and `oauth2-proxy-creds`; rotating one without the others breaks SSO. There is no encryption at rest in Git, no rotation runbook, and no `gitleaks`. Some dead/confusing fields: `traefik-dashboard-auth` is unused, `MAS_ENCRYPTION_SECRET` is unused, `DB_HOST` is unused, and `mas-adminapi` is redundant.

**Fix:** SOPS+age (or SealedSecrets/External Secrets) so the repo is self-contained; one source of truth for shared secrets; a rotation runbook for DB passwords, OAuth client secrets, runner token, MAS/Synapse signing keys, ACME account key, cookie secret, SMTP password, and the Scaleway API key. Add `gitleaks` pre-commit/CI. Remove dead secrets/fields.

### 3.3 Staging and restore drills

No staging environment and no restore drill. Upgrades of Synapse/MAS/Forgejo/Postgres are one-way and untested. The Matrix README's restore command is not a real runbook.

**Fix:** a `staging` namespace (or a second k3s VM/kind) with a restored DB and separate hostnames; run smoke tests before upgrades. Quarterly restore drill on a clean VM; document RPO/RTO and the rebuild steps. Add `forgejo doctor check`, `mas-cli config check`, `synapse --check-config`, and endpoint checks.

### 3.4 k3s, DNS, and router config are not in the repo

The k3s OIDC config (`--oidc-username-claim=sub`, `--oidc-username-prefix=oidc:`, client ID) is only in `/etc/rancher/k3s/config.yaml` on the node, not in the repo. DNS records, router port forwards (80/443 TCP, 22 TCP, 34197 UDP, 7881 TCP, 7882 UDP), the DHCP reservation for `192.168.1.200-210`, and split-horizon DNS are not documented. A node/router rebuild is not reproducible.

**Fix:** add `infra/` with the k3s install command/config, CNI/version, firewall rules, DNS records, and router port forwards. Use external-dns with Scaleway for DNS; reserve the MetalLB pool outside DHCP; document split-horizon DNS (and add the MetalLB VIP to the runner's egress allowlist if used). Add CAA/SPF/DKIM/DMARC.

### 3.5 Image pinning and supply chain

Mixed pinning: `nginx:latest` (`wk`), `traefik/whoami:latest`, `factoriotools/factorio:stable` + `Always`, `alpine:latest` in Synapse/MAS/LiveKit/Factorio init containers, `docker:28-dind`, `runner:13`, `traefik:3.7`, `matrix-authentication-service:1.28`, `livekit-server:v1.13`. `apk add gettext` at every start depends on the Alpine repo.

**Fix:** pin patch versions/digests, use `IfNotPresent`, Renovate, Trivy/cosign (optional). Build a tiny pinned `envsubst` image instead of `apk add` at runtime, or vendor the package. Align `alpine:3.21` vs `3.24`.

### 3.6 Pod hardening

Most pods lack `seccompProfile: RuntimeDefault`, `readOnlyRootFilesystem`, `capabilities.drop: [ALL]`, `automountServiceAccountToken: false`, and `enableServiceLinks: false`. No PSA labels. Only Headlamp/MAS/Synapse/Forgejo runner have partial hardening.

**Fix:** add PSA labels (`baseline`/`restricted`; `privileged` only for the runner namespace), `seccompProfile`, drop caps, disable the SA token where unused, `readOnlyRootFilesystem` where possible (with emptyDir for `/tmp`), `runAsNonRoot` where possible. Keep Traefik's `NET_BIND_SERVICE`. Move the runner to `ci` with `privileged`.

### 3.7 `chown -R` and `fsGroup`

`git/forgejo/02-deployment.yaml:35`, `matrix/synapse/02-deployment.yaml:35`, and `games/factorio/01-deployment.yaml:29` run `chown -R` on every start over large data volumes. This can take minutes and delay startup; `fsGroupChangePolicy` defaults to `Always`.

**Fix:** set `fsGroupChangePolicy: OnRootMismatch`; remove recursive chown; only chown the specific config files/dirs. The Forgejo runner already does this — copy the pattern.

### 3.8 `subPath` mounts

`matrix/mas` mounts `secrets.yaml` via `subPath`; `matrix/synapse` mounts the signing key and log config via `subPath`; `git/forgejo` mounts `app.ini` via `subPath`. Updates to the Secret/ConfigMap don't propagate.

**Fix:** mount directories/projected volumes where possible; document that signing keys require a restart; add Reloader/checksum for the rest.

### 3.9 App-specific notes

- **Forgejo:** add `forgejo dump` backup, a `doctor check` CronJob, metrics, startupProbe, terminationGracePeriod, invite-only registration, hide the footer version, review `[cron.cleanup_packages] OLDER_THAN=24h`, restrict `[webhook] ALLOWED_HOST_LIST`, consider DB TLS. Add `[service] DEFAULT_USER_VISIBILITY=private` if desired. Pin Actions by SHA.
- **Synapse:** add `public_baseurl`, `media_retention`, `enable_metrics`, `max_upload_size`, a longer startupProbe, `terminationGracePeriodSeconds: 120`, memory 2Gi (or request 1Gi/no limit), node pinning, `fsGroupChangePolicy`, remove the public `/_synapse/` route, and decide on `report_stats`/federation whitelist.
- **MAS:** migration Job, `config check`, remove unused `MAS_ENCRYPTION_SECRET`, remove the internal port from the Service, rate limiting, MFA, registration lockdown, email DNS, `readOnlyRootFilesystem`/seccomp.
- **LiveKit:** validate `LIVEKIT_NODE_IP`, use a dedicated media IP, add a startupProbe, `Recreate`, `externalTrafficPolicy: Local`, TURN for remote clients, rate-limit the JWT endpoint, metrics, NetworkPolicy.
- **wk:** pin nginx, run non-root, fix `security.txt` content type, add cache headers, `server_tokens off`, NetworkPolicy.
- **Headlamp:** document SA vs OIDC behavior, put it behind a VPN/IP allowlist, add NetworkPolicy, seccomp, readOnlyRootFS, priority, MFA, and put the k3s OIDC config in the repo.
- **oauth2-proxy:** remove the deprecated `trustForwardHeader`, scope the cookie/whitelist to `dashboard.polarys.im`, add a startupProbe, seccomp, readOnlyRootFS, NetworkPolicy, rate limiting, metrics.
- **Traefik:** add priority, grace period/preStop, seccomp, `allowPrivilegeEscalation: false`, remove the unused dashboard basic auth, restrict admin, set `externalTrafficPolicy: Local`, update MetalLB annotations, add metrics scraping, and consider cert-manager/HA. Remove `namespace` from the ClusterRole/ClusterRoleBinding; add `get` on `endpointslices`; vendor the CRDs.
- **MetalLB:** update to `metallb.io/*` annotations, reserve the pool, pin the manifest, and monitor the speaker.
- **whoami:** remove it or protect it.

### 3.10 Cleanup and dead config

- `git/postgresql/01-config.yaml` comment says "Synapse database & user".
- `matrix/01-secrets.template.yaml` says "Copy 01-secrets.yaml.example" (wrong filename).
- `proxy/oauth2-proxy/01-deployment.yaml` references `proxy/oauth2-proxy/00-secrets.template.yaml` (wrong path).
- `k8s/01-secrets.template.yaml` references "memory/notes" for the MAS `sub` extraction; document it in-repo.
- `git/postgresql/05-networkpolicy.yaml` has a dead `app: forgejo-sso` rule.
- `matrix/mas/03-ingress.yaml` has a redundant `mas-adminapi` route.
- `matrix/mas/02-service.yaml` exposes the internal 8081 port unnecessarily.
- `proxy/01-secrets.template.yaml` has an unused `traefik-dashboard-auth`.
- `matrix/01-secrets.template.yaml` has unused `MAS_ENCRYPTION_SECRET` and `DB_HOST`.
- `wk/wk/00-config.yaml` serves `security.txt` as `application/json`.
- `proxy/traefik/00-bindings.yaml` has `namespace` on ClusterRole/ClusterRoleBinding (ignored) and is missing `get` on `endpointslices`.
- `matrix/postgresql/02-deployment.yaml` and `git/postgresql/02-deployment.yaml` use different PGDATA layouts.
- `matrix/synapse/01-config.yaml` hardcodes `pg-svc` while `DB_HOST` is in the secret.
- `git/forgejo-runner/02-deployment.yaml` uses `alpine:3.21` while other files use `3.24`.
- `proxy/traefik/04-services.yaml` and `matrix/rtc/02-services.yaml` use deprecated `metallb.universe.tf` annotations.
- `matrix/README.md` restore command needs a real runbook.
- The root README diagram is incomplete (missing `git`, `rtc`, `whoami`, Factorio, `wk`).

---

## 4. Suggested roadmap

| Phase | Time | Focus | Done when |
|---|---|---|---|
| **0. Stop the bleeding** | This week | Offsite restic backup; close MAS registration; isolate the runner; pin Factorio; add PriorityClass to Traefik; add disk/cert/backup alerts; remove `whoami`; fix the `MX_SIGNING_KEY` doc; add Forgejo startupProbe / raise Synapse's; add checksum/Reloader; add nodeSelector/nodeAffinity stopgap | A disk failure no longer means total loss; no stranger can reach CI; Traefik isn't evicted before games |
| **1. Reproducibility** | 2–4 weeks | SOPS/SealedSecrets; GitOps (Flux/Argo); Kustomize/Helm; CI validation; MAS migration Job; config rollout; upgrade/restore runbooks; k3s/DNS/router docs | The repo can rebuild the cluster; config changes apply automatically; upgrades have a runbook |
| **2. Reliability** | 1–2 months | Storage migration to `local` PV/local-path; monitoring/logging/uptime; default-deny NetworkPolicies; PSA/seccomp/readOnlyRootFS; resource quotas; external-dns; Traefik HA/cert-manager (optional); Forgejo dump/doctor; Postgres exporter/PITR (optional) | Disk/cert/backup failures alert; pods are hardened; storage is node-aware |
| **3. Polish** | Ongoing | Staging/restore drills; image pinning/Renovate/Trivy; MFA/rate limiting/admin VPN; LiveKit TURN; docs; remove dead config; consider Longhorn/Velero if needed | Upgrades are boring; DR is tested; the repo is self-documenting |

---

## 5. Quick wins (a few hours)

1. Run `restic` against `/data/k8s` and `/etc/rancher/k3s` to an offsite bucket **today**.
2. Set `password_registration_enabled: false` (or require a token) in `matrix/mas/00-config.yaml`.
3. Pin Factorio and set `imagePullPolicy: IfNotPresent`.
4. Add `priorityClassName: homelab-critical` to Traefik/Postgres/Synapse/MAS/Forgejo.
5. Add `nodeSelector: mako` to every workload with a hostPath PV (Postgres, Synapse, Traefik, Factorio, backups) as a stopgap; then add `nodeAffinity` to the PVs.
6. Add a startupProbe to Forgejo; raise Synapse's to 10 minutes.
7. Add a checksum annotation or Reloader.
8. Remove the `whoami` ingress.
9. Add a disk/cert/backup alert.
10. Fix the `MX_SIGNING_KEY` doc and back up the key.
11. Remove the public `/_synapse/` route or add an IP allowlist.
12. Add `fsGroupChangePolicy: OnRootMismatch` and remove `chown -R`.
13. Pin `nginx`, `alpine`, and `whoami`.
14. Add default-deny NetworkPolicies to `matrix`, `proxy`, `headlamp`, `games`, and `wk`.

---

## 6. What I need to confirm

These change the severity of several findings:

- Is the cluster **single-node or multi-node**? If multi-node, the hostPath issue is critical today; if single-node, it's a rebuild risk.
- Which **CNI/policy engine**? Is `--disable-network-policy` set? (k3s's default kube-router should enforce.)
- Which **k3s version**? The runner uses native sidecar `restartPolicy: Always`, which needs 1.29+.
- Is the cluster **exposed to the internet**? Which ports are forwarded? Is there a VPN?
- What are your **RPO/RTO** expectations, and where should backups go (B2/S3/NAS)?
- Is open MAS registration **intentional**? Do you need self-service signup?
- Do you run **untrusted PRs/forks** through Forgejo Actions?
- Is `mako` the only node? Will you add nodes?
- Do you want **HA ingress**, or is downtime acceptable?
- Do you have a **staging environment/VM**?

---

## 7. What's already good

- Clear namespace separation and mostly consistent labels.
- SSO via MAS for Forgejo, Headlamp, and the Traefik dashboard; OIDC + RBAC binding.
- Backups with `gzip -t`, retention, and `concurrencyPolicy: Forbid`.
- `Recreate` for stateful workloads and Traefik ACME; `preStop`/grace period for Postgres.
- Probes and resource requests/limits on most workloads.
- Good security intent: `OFFLINE_MODE`, `DISABLE_GIT_HOOKS`, `DEFAULT_PRIVATE`, argon2, `cookie-secure`, HSTS, `sendanonymoususage=false`, `.gitignore` for secrets.
- Comments explaining tricky choices (ACME `Recreate`, MAS claims, dind networking).
- `fsGroup`/`terminationGracePeriodSeconds` for Postgres; `nodeSelector` for some local-PV workloads.
- NetworkPolicy intent for Postgres and the runner; backup retention; `Forbid` concurrency.
- Startup probes on most workloads; `Recreate` for Factorio/Forgejo/Synapse/Traefik.
- No secrets committed; templates are clear and documented.

The commit history shows repeated fixes around the runner/dind and PV attribution — those are symptoms of the two biggest structural issues (privileged CI and non-node-aware storage). Fixing the structure will stop the whack-a-mole.
