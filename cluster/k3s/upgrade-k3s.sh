#!/usr/bin/env bash
#
# Upgrade the single-node k3s cluster to a newer Kubernetes minor.
#
# Kubernetes does not support skipping minors, so the upgrade is a list of
# single-minor hops (TARGETS below). Each hop installs a pinned k3s release and
# then waits for a healthy cluster before the next one starts.
#
# Nothing here touches persistent data: k3s keeps its sqlite datastore and the
# local-path volumes under /var/lib/rancher/k3s. The script backs both up before
# the first hop anyway.
#
# Usage:
#   sudo ./upgrade-k3s.sh             # run the plan
#   sudo ./upgrade-k3s.sh --dry-run   # show what would happen
#   sudo ./upgrade-k3s.sh --yes       # no confirmation prompt
#
# Rollback (only within the same minor, or restore the backup):
#   cp /root/k3s-upgrade-<ts>/k3s.<version> /usr/local/bin/k3s && systemctl restart k3s
set -euo pipefail

# Latest patch release of each minor on the stable channel (2026-10).
# One minor per hop, in order.
TARGETS=(
  "v1.34.12+k3s1"
  "v1.35.9+k3s1"
  "v1.36.5+k3s1"
)

DRY_RUN=0
ASSUME_YES=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --yes|-y)  ASSUME_YES=1 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

log()  { printf '\n==> %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run as root (sudo $0)"

current_version() { k3s --version 2>/dev/null | awk 'NR==1{print $3}'; }

# version_lt A B -> true when A < B (build metadata ignored by sort -V).
version_lt() { [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" = "$1" ]; }

wait_api() {
  for _ in $(seq 1 150); do
    k3s kubectl get --raw='/healthz' >/dev/null 2>&1 && return 0
    sleep 2
  done
  return 1
}

wait_healthy() {
  local node
  node=$(k3s kubectl get nodes -o jsonpath='{.items[0].metadata.name}') || return 1
  k3s kubectl wait --for=condition=Ready "node/$node" --timeout=600s || return 1

  # Pods keep running across a k3s restart; anything still Pending after the
  # upgrade means a controller or the CNI did not come back.
  local pending=1
  for _ in $(seq 1 60); do
    pending=$(k3s kubectl get pods -A --field-selector=status.phase=Pending --no-headers 2>/dev/null | wc -l)
    [ "$pending" -eq 0 ] && break
    sleep 10
  done
  if [ "$pending" -ne 0 ]; then
    k3s kubectl get pods -A --field-selector=status.phase=Pending
    return 1
  fi

  # End-to-end: the Gateway must still answer.
  local gw
  gw=$(k3s kubectl -n traefik get gateway traefik-gateway -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true)
  if [ -n "$gw" ]; then
    curl -sk -o /dev/null --max-time 15 "https://$gw/" || { warn "gateway $gw did not answer"; return 1; }
  else
    warn "gateway address not found, skipping the ingress probe"
  fi
}

backup() {
  local cur=$1 dir
  dir="/root/k3s-upgrade-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$dir"
  cp -a /usr/local/bin/k3s "$dir/k3s.$cur"
  cp -a /etc/rancher/k3s "$dir/rancher-k3s"
  if [ -d /var/lib/rancher/k3s/server/db ]; then
    cp -a /var/lib/rancher/k3s/server/db "$dir/server-db"
  fi
  k3s kubectl get all -A -o yaml > "$dir/cluster-objects.yaml" 2>/dev/null || true
  printf '%s\n' "$dir"
}

hop() {
  local version=$1
  log "upgrading to k3s $version"

  # INSTALL_K3S_VERSION is what pins the release; the config file and the
  # systemd unit (plain 'k3s server') are regenerated but stay equivalent.
  curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="$version" INSTALL_K3S_SKIP_START=false sh - \
    || die "install script failed for $version"

  systemctl is-active --quiet k3s || die "k3s service is not running after installing $version"
  wait_api || die "API did not come back after installing $version"
  wait_healthy || die "cluster is not healthy after installing $version"

  local now
  now=$(current_version)
  [ "$now" = "$version" ] || die "expected $version, running $now"
  log "k3s $version is up"
}

main() {
  local cur
  cur=$(current_version)
  [ -x /usr/local/bin/k3s ] || die "k3s binary not found at /usr/local/bin/k3s"

  log "current k3s: $cur"
  printf 'plan:\n'
  printf '  %s\n' "${TARGETS[@]}"

  if [ "$DRY_RUN" -eq 1 ]; then
    log "dry run, nothing changed"
    exit 0
  fi

  local avail_kb
  avail_kb=$(df --output=avail -k /usr/local/bin | tail -1 | tr -d ' ')
  [ "$avail_kb" -gt 3000000 ] || die "need ~3 GB free on / for the backup, have $((avail_kb/1024)) MB"

  if [ "$ASSUME_YES" -eq 0 ]; then
    printf '\nThe API restarts for ~30s per hop and pods are not drained.\nContinue? [y/N] '
    read -r reply
    [[ "$reply" =~ ^[Yy]$ ]] || { echo "aborted"; exit 1; }
  fi

  local backup_dir=""
  for target in "${TARGETS[@]}"; do
    if ! version_lt "$cur" "$target"; then
      log "skipping $target (already at $cur)"
      continue
    fi
    if [ -z "$backup_dir" ]; then
      backup_dir=$(backup "$cur")
      log "backup: $backup_dir"
    fi
    hop "$target"
    cur=$(current_version)
  done

  log "done: k3s $(current_version)"
  if [ -n "$backup_dir" ]; then
    log "backup kept at $backup_dir"
  fi
}

main
