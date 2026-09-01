#!/usr/bin/env bash
#
# Maintenance runbook for the polarys cluster.
#
#   ./scripts/maintenance.sh down    # quiesce → dump DBs → stop → archive
#   ./scripts/maintenance.sh up      # bring everything back in dependency order
#   ./scripts/maintenance.sh dump    # DB dumps only, cluster left running
#   ./scripts/maintenance.sh status
#
# Run this ON the node (mako): the archive step reads the hostPath volumes
# directly, and kubectl must be able to reach the API server.
#
set -euo pipefail

KUBECTL="${KUBECTL:-kubectl}"
DATA_ROOT="${DATA_ROOT:-/data/k8s}"
ARCHIVE_DIR="${ARCHIVE_DIR:-${DATA_ROOT}/backups/archives}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_FILE="${ARCHIVE_DIR}/scale-state.txt"
TS="$(date +%Y%m%d-%H%M%S)"

# ── Workload inventory ───────────────────────────────────────────────────────
# Ordered tiers. Everything that writes to Postgres lives in APP_TIER so the
# databases are idle by the time we dump them.
APP_TIER=(
  "matrix deployment synapse"
  "matrix deployment mas"
  "matrix deployment livekit"
  "matrix deployment livekit-jwt"
  "git deployment forgejo"
  "games deployment factorio"
  "wk deployment wk"
  "proxy deployment whoami"
  "headlamp deployment headlamp"
)
DB_TIER=(
  "matrix statefulset pg"
  "git statefulset forgejo-pg"
)
# Traefik goes down last: while the app tier drains, clients get a clean 503
# from the proxy instead of a TCP reset.
EDGE_TIER=(
  "proxy deployment traefik"
)
CRONJOBS=(
  "matrix pg-backup"
  "git forgejo-pg-backup"
)
# Postgres backup CronJob → directory its dumps land in, and the dump prefix.
declare -A DUMP_DIRS=(
  ["matrix/pg-backup"]="${DATA_ROOT}/backups/matrix/postgresql:matrix"
  ["git/forgejo-pg-backup"]="${DATA_ROOT}/backups/forgejo/postgresql:forgejo"
)

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

# ── Helpers ──────────────────────────────────────────────────────────────────

# Poll the controller's own status rather than guessing pod label selectors.
wait_scaled_down() {
  local ns=$1 kind=$2 name=$3 timeout=${4:-300} waited=0
  while :; do
    local running
    running=$($KUBECTL -n "$ns" get "$kind" "$name" \
      -o jsonpath='{.status.replicas}' 2>/dev/null || echo 0)
    [ -z "$running" ] && running=0
    [ "$running" -eq 0 ] && return 0
    [ "$waited" -ge "$timeout" ] && die "$ns/$name still has $running pod(s) after ${timeout}s"
    sleep 3
    waited=$((waited + 3))
  done
}

# `kubectl wait --for=condition=complete` sits out the whole timeout when a job
# fails, so poll both terminal conditions instead and fail fast.
wait_job() {
  local ns=$1 job=$2 timeout=${3:-1800} waited=0 succeeded failed
  while :; do
    succeeded=$($KUBECTL -n "$ns" get job "$job" -o jsonpath='{.status.succeeded}' 2>/dev/null || echo "")
    failed=$($KUBECTL -n "$ns" get job "$job" -o jsonpath='{.status.failed}' 2>/dev/null || echo "")
    [ "${succeeded:-0}" -ge 1 ] 2>/dev/null && return 0
    # backoffLimit is 2, so only treat the job as lost once it stops retrying.
    if $KUBECTL -n "$ns" get job "$job" \
         -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}' 2>/dev/null | grep -q True; then
      return 1
    fi
    [ "$waited" -ge "$timeout" ] && { warn "timed out after ${timeout}s (failed=${failed:-0})"; return 1; }
    sleep 5
    waited=$((waited + 5))
  done
}

record_scale() {
  mkdir -p "$ARCHIVE_DIR"
  local ns kind name replicas tmp
  tmp="$(mktemp)"
  for entry in "${APP_TIER[@]}" "${DB_TIER[@]}" "${EDGE_TIER[@]}"; do
    read -r ns kind name <<<"$entry"
    replicas=$($KUBECTL -n "$ns" get "$kind" "$name" \
      -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "")
    # Only record live workloads: a second `down` would otherwise capture all
    # zeroes and a later `up` would faithfully restore nothing.
    if [ -n "$replicas" ] && [ "$replicas" -gt 0 ] 2>/dev/null; then
      echo "${ns}/${kind}/${name}=${replicas}" >> "$tmp"
    fi
  done
  if [ -s "$tmp" ]; then
    mv "$tmp" "$STATE_FILE"
    log "Recorded pre-shutdown replica counts in ${STATE_FILE}"
  else
    rm -f "$tmp"
    warn "everything is already scaled to 0 — keeping the existing ${STATE_FILE}"
  fi
}

desired_replicas() {
  local key="$1/$2/$3"
  if [ -f "$STATE_FILE" ] && grep -q "^${key}=" "$STATE_FILE"; then
    grep "^${key}=" "$STATE_FILE" | cut -d= -f2
  else
    echo 1   # every manifest in this repo declares replicas: 1
  fi
}

scale_tier() {
  local -n tier=$1
  local replicas=$2 ns kind name target
  for entry in "${tier[@]}"; do
    read -r ns kind name <<<"$entry"
    if ! $KUBECTL -n "$ns" get "$kind" "$name" >/dev/null 2>&1; then
      warn "skipping ${ns}/${name} (not deployed)"
      continue
    fi
    if [ "$replicas" = "restore" ]; then
      target=$(desired_replicas "$ns" "$kind" "$name")
    else
      target=$replicas
    fi
    log "scale ${ns}/${kind}/${name} → ${target}"
    $KUBECTL -n "$ns" scale "$kind" "$name" --replicas="$target"
  done
}

wait_tier_down() {
  local -n tier=$1
  local ns kind name
  for entry in "${tier[@]}"; do
    read -r ns kind name <<<"$entry"
    $KUBECTL -n "$ns" get "$kind" "$name" >/dev/null 2>&1 || continue
    log "waiting for ${ns}/${name} to terminate"
    # pg has terminationGracePeriodSeconds: 90 plus a preStop `pg_ctl -m fast`.
    wait_scaled_down "$ns" "$kind" "$name" 300
  done
}

wait_tier_up() {
  local -n tier=$1
  local ns kind name
  for entry in "${tier[@]}"; do
    read -r ns kind name <<<"$entry"
    $KUBECTL -n "$ns" get "$kind" "$name" >/dev/null 2>&1 || continue
    log "waiting for ${ns}/${name} to become ready"
    $KUBECTL -n "$ns" rollout status "$kind/$name" --timeout=300s
  done
}

set_cronjobs() {
  local suspend=$1 ns name
  for entry in "${CRONJOBS[@]}"; do
    read -r ns name <<<"$entry"
    $KUBECTL -n "$ns" get cronjob "$name" >/dev/null 2>&1 || continue
    log "cronjob ${ns}/${name} suspend=${suspend}"
    $KUBECTL -n "$ns" patch cronjob "$name" \
      -p "{\"spec\":{\"suspend\":${suspend}}}"
  done
}

# ── Commands ─────────────────────────────────────────────────────────────────

# Reuses the existing backup CronJobs instead of a hand-rolled pod: the job
# template already carries the `app: pg-backup` label the Postgres
# NetworkPolicy requires, plus the right credentials and backup PVC.
cmd_dump() {
  local ns name started=()
  for entry in "${CRONJOBS[@]}"; do
    read -r ns name <<<"$entry"
    $KUBECTL -n "$ns" get cronjob "$name" >/dev/null 2>&1 \
      || { warn "no cronjob ${ns}/${name}, skipping"; continue; }
    local job="manual-${name}-${TS}"
    log "triggering ${ns}/${job}"
    $KUBECTL -n "$ns" create job "$job" --from="cronjob/${name}"
    started+=("$ns $job")
  done
  [ ${#started[@]} -gt 0 ] || die "no backup CronJobs found — nothing was dumped"

  local ok=0 job
  for entry in "${started[@]}"; do
    read -r ns job <<<"$entry"
    log "waiting for ${ns}/${job}"
    if wait_job "$ns" "$job" 1800; then
      $KUBECTL -n "$ns" logs "job/${job}" 2>/dev/null | sed 's/^/    /' || true
    else
      ok=1
      warn "dump job ${ns}/${job} did not complete — logs follow"
      $KUBECTL -n "$ns" logs "job/${job}" 2>/dev/null | sed 's/^/    /' || true
    fi
  done
  [ "$ok" -eq 0 ] || die "at least one dump failed; do NOT proceed with the update"
  log "database dumps complete"
}

cmd_archive() {
  [ -d "$DATA_ROOT" ] || die "${DATA_ROOT} not found — run this on the node"
  mkdir -p "$ARCHIVE_DIR"

  local stage
  stage="$(mktemp -d)"
  # Cleanup is deliberately manual — no automatic rm on the node. The trap only
  # reports the path, including on the `die` paths where the script exits early.
  # Expanded now, not at trap time: $stage is function-local and would be out of
  # scope (and trip `set -u`) by the time an EXIT trap fires.
  # shellcheck disable=SC2064
  trap "printf '\033[1;33m[!]\033[0m staging dir holds plaintext secrets, delete it: %s\n' '$stage' >&2" EXIT
  mkdir -p "$stage/db-dumps" "$stage/cluster" "$stage/manifests"

  # Newest dump per database, so the archive is self-contained without
  # dragging along the full 14-day retention window.
  local key dir prefix newest
  for key in "${!DUMP_DIRS[@]}"; do
    IFS=: read -r dir prefix <<<"${DUMP_DIRS[$key]}"
    newest=$(ls -1t "${dir}/${prefix}-"*.sql.gz 2>/dev/null | head -1 || true)
    if [ -n "$newest" ]; then
      log "including dump $(basename "$newest")"
      cp -a "$newest" "$stage/db-dumps/"
    else
      warn "no dump found in ${dir} for ${prefix}"
    fi
  done

  # Cluster-side state: the authoritative copy of every Secret, in case a
  # local *secrets.yaml has drifted from what is actually applied.
  log "capturing cluster resources"
  $KUBECTL get secret -A -o yaml   > "$stage/cluster/secrets.yaml"
  $KUBECTL get pv,pvc -A -o yaml   > "$stage/cluster/volumes.yaml"
  $KUBECTL get all -A -o yaml      > "$stage/cluster/all-resources.yaml"
  chmod 600 "$stage/cluster/secrets.yaml"

  # Gitignored secret manifests, plus the commit this cluster was running.
  ( cd "$REPO_ROOT" && find . -name '*secrets.yaml' -not -name '*template*' \
      -exec cp --parents {} "$stage/manifests/" \; ) 2>/dev/null || true
  git -C "$REPO_ROOT" rev-parse HEAD > "$stage/manifests/GIT-COMMIT" 2>/dev/null || true

  # Only archive the data dirs that actually exist — tar aborts on a missing one.
  local data_dirs=() d
  for d in matrix forgejo games proxy; do
    [ -d "${DATA_ROOT}/${d}" ] && data_dirs+=("$d") || warn "${DATA_ROOT}/${d} absent, skipping"
  done
  [ ${#data_dirs[@]} -gt 0 ] || die "no data directories found under ${DATA_ROOT}"

  local out="${ARCHIVE_DIR}/polarys-${TS}.tar.gz"
  log "writing ${out}"
  tar -czf "$out" --numeric-owner \
    -C "$DATA_ROOT" "${data_dirs[@]}" \
    -C "$stage" db-dumps cluster manifests
  chmod 600 "$out"   # contains plaintext Secrets

  log "archive ready: ${out} ($(du -h "$out" | cut -f1))"
  warn "this archive holds plaintext secrets — encrypt before moving it off-node"
  echo "    age -p -o ${out}.age ${out} && shred -u ${out}"
}

cmd_down() {
  record_scale
  set_cronjobs true
  log "── stopping application tier ──"
  scale_tier APP_TIER 0
  wait_tier_down APP_TIER

  log "── dumping databases (apps down, Postgres still up) ──"
  cmd_dump

  log "── stopping databases ──"
  scale_tier DB_TIER 0
  wait_tier_down DB_TIER

  log "── stopping edge ──"
  scale_tier EDGE_TIER 0
  wait_tier_down EDGE_TIER

  log "── archiving ──"
  cmd_archive

  # Factorio saves on SIGTERM; confirm the save on disk is actually fresh.
  local saves="${DATA_ROOT}/games/factorio/saves"
  if [ -d "$saves" ]; then
    log "newest factorio save:"
    ls -lt "$saves" | head -3 | sed 's/^/    /'
  fi

  log "cluster is down. Safe to apply manifests / update the node."
}

cmd_up() {
  log "── starting databases ──"
  scale_tier DB_TIER restore
  wait_tier_up DB_TIER

  log "── starting application tier ──"
  scale_tier APP_TIER restore
  wait_tier_up APP_TIER

  log "── starting edge ──"
  scale_tier EDGE_TIER restore
  wait_tier_up EDGE_TIER

  set_cronjobs false
  log "cluster is up."
}

cmd_status() {
  $KUBECTL get deploy,sts -A \
    -o custom-columns=NS:.metadata.namespace,KIND:.kind,NAME:.metadata.name,DESIRED:.spec.replicas,READY:.status.readyReplicas
  echo
  $KUBECTL get cronjob -A \
    -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,SUSPEND:.spec.suspend,LAST:.status.lastScheduleTime
}

case "${1:-}" in
  down)    cmd_down ;;
  up)      cmd_up ;;
  dump)    cmd_dump ;;
  archive) cmd_archive ;;
  status)  cmd_status ;;
  *) die "usage: $0 {down|up|dump|archive|status}" ;;
esac
