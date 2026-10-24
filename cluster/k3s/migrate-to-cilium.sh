#!/usr/bin/env bash
#
# Replace k3s' flannel CNI with Cilium on the running single-node cluster.
#
# What it does, in order:
#   1. backs up the k3s config and the current NetworkPolicies
#   2. warms the image cache (best effort, keeps the outage short)
#   3. installs the repo's k3s config.yaml (flannel-backend: none,
#      disable-network-policy: true) and restarts k3s
#   4. applies kubernetes/components/cilium, which creates the HelmRelease;
#      Flux' helm-controller installs the chart
#   5. waits for the Cilium DaemonSets/Deployments and smoke-tests a pod
#
# Pods that are already running keep their sandboxes (and flannel addresses)
# until they are recreated; reboot the node afterwards so every pod moves onto
# Cilium. See cluster/k3s/README.md.
#
# Usage:
#   sudo ./migrate-to-cilium.sh            # migrate
#   sudo ./migrate-to-cilium.sh --reboot   # migrate, then reboot to finish
#   sudo ./migrate-to-cilium.sh --rollback # go back to flannel
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(cd "$SCRIPT_DIR/../.." && pwd)
COMPONENT="$REPO_DIR/kubernetes/components/cilium"
CONF=/etc/rancher/k3s/config.yaml
IMAGES="$SCRIPT_DIR/cilium-images.txt"

log()  { printf '\n==> %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run as root (sudo $0)"

wait_api() {
  for _ in $(seq 1 150); do
    k3s kubectl get --raw='/healthz' >/dev/null 2>&1 && return 0
    sleep 2
  done
  return 1
}

wait_cilium() {
  k3s kubectl -n kube-system rollout status ds/cilium --timeout=600s || return 1
  k3s kubectl -n kube-system rollout status ds/cilium-envoy --timeout=600s || return 1
  k3s kubectl -n kube-system rollout status deploy/cilium-operator --timeout=300s || return 1
}

prepull() {
  [ -f "$IMAGES" ] || { warn "$IMAGES missing, skipping image pre-pull"; return 0; }
  while read -r image; do
    case "$image" in ''|\#*) continue ;; esac
    log "pulling $image"
    k3s crictl pull "$image" >/dev/null 2>&1 || warn "could not pre-pull $image (will pull at install time)"
  done < "$IMAGES"
}

smoke_test() {
  local name=cilium-smoke-$$
  log "smoke test: scheduling a pod and checking its address"
  k3s kubectl run "$name" --image=registry.k8s.io/pause:3.10 --restart=Never >/dev/null
  for _ in $(seq 1 60); do
    ip=$(k3s kubectl get pod "$name" -o jsonpath='{.status.podIP}' 2>/dev/null || true)
    phase=$(k3s kubectl get pod "$name" -o jsonpath='{.status.phase}' 2>/dev/null || true)
    if [ -n "$ip" ] && [ "$phase" = "Running" ]; then
      k3s kubectl delete pod "$name" --wait=false >/dev/null 2>&1 || true
      case "$ip" in
        10.42.*) log "pod got $ip (Cilium cluster-pool), CNI is working"; return 0 ;;
        *) die "pod got $ip, expected an address from 10.42.0.0/16" ;;
      esac
    fi
    sleep 5
  done
  k3s kubectl describe pod "$name" 2>/dev/null | tail -20 || true
  k3s kubectl delete pod "$name" --wait=false >/dev/null 2>&1 || true
  return 1
}

migrate() {
  [ -d "$COMPONENT" ] || die "$COMPONENT not found - run this from a checkout of home-lab"
  [ -f "$CONF" ] || die "$CONF not found"

  if grep -qE '^flannel-backend:[[:space:]]*none' "$CONF"; then
    warn "config already has flannel disabled (previous attempt?) - continuing"
  fi
  if k3s kubectl -n kube-system get ds cilium >/dev/null 2>&1; then
    die "cilium DaemonSet already exists - cluster is already migrated (use --rollback to undo)"
  fi

  local dir
  dir="/root/k3s-cni-backup-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$dir"
  cp -a "$CONF" "$dir/config.yaml"
  cp -a /var/lib/rancher/k3s/agent/etc/cni/net.d "$dir/cni-net.d" 2>/dev/null || true
  k3s kubectl get netpol -A -o yaml > "$dir/networkpolicies.yaml" 2>/dev/null || true
  log "backup: $dir"

  prepull

  log "writing $CONF (flannel off, kube-router network policy off)"
  diff -u "$CONF" "$REPO_DIR/cluster/k3s/config.yaml" || true
  install -m 0644 "$REPO_DIR/cluster/k3s/config.yaml" "$CONF"

  log "restarting k3s without flannel"
  systemctl restart k3s
  wait_api || die "API did not come back - restore $dir/config.yaml and restart k3s"

  log "applying $COMPONENT (HelmRelease -> helm-controller installs Cilium)"
  # Apply the HelmRepository as well, so the script works whether or not the
  # PR that adds it to flux-system/repos has been merged yet.
  k3s kubectl apply -f "$REPO_DIR/kubernetes/components/flux-system/repos/cilium.yaml"
  k3s kubectl apply -k "$COMPONENT"

  log "waiting for Cilium (images may still be pulling)"
  wait_cilium || die "Cilium did not become ready - see: k3s kubectl -n kube-system get pods"

  k3s kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status --brief || warn "cilium-dbg status failed"

  smoke_test || die "new pods are not getting Cilium addresses"

  cat <<EOF

------------------------------------------------------------------
Cilium is up. Pods that were running before the switch still use
their old flannel sandbox, and fresh Cilium addresses come from the
same 10.42.0.x range until those pods are recreated. Reboot now to
close that window:

    sudo reboot

(--reboot reboots straight after this check.)

After the reboot:

    k3s kubectl get pods -A | grep -v -E 'Running|Completed'
    k3s kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status
    curl -sk -o /dev/null -w '%{http_code}\\n' https://192.168.0.200/

Then merge the suspend:false flip for the cilium Kustomization.
Rollback at any point: sudo $0 --rollback
------------------------------------------------------------------
EOF
}

rollback() {
  local dir
  dir=$(find /root -maxdepth 1 -type d -name 'k3s-cni-backup-*' 2>/dev/null | sort | tail -1 || true)
  if [ -n "${1:-}" ] && [ -d "${1:-}" ]; then dir=$1; fi
  if [ -z "$dir" ] || [ ! -f "$dir/config.yaml" ]; then
    die "no backup config found (pass the backup dir)"
  fi

  log "rolling back to flannel using $dir/config.yaml"
  install -m 0644 "$dir/config.yaml" "$CONF"

  k3s kubectl -n flux-system delete helmrelease cilium --ignore-not-found >/dev/null 2>&1 || true
  k3s kubectl -n kube-system delete ds cilium cilium-envoy --ignore-not-found >/dev/null 2>&1 || true
  k3s kubectl -n kube-system delete deploy cilium-operator hubble-relay --ignore-not-found >/dev/null 2>&1 || true

  systemctl restart k3s
  wait_api || die "API did not come back"

  # Cilium removes other CNI configs (cni.exclusive); drop its own so the
  # restarted k3s writes the flannel config again.
  rm -f /etc/cni/net.d/05-cilium.conflist
  rm -f /var/lib/rancher/k3s/agent/etc/cni/net.d/05-cilium.conflist
  systemctl restart k3s
  wait_api || die "API did not come back after the second restart"

  log "flannel restored; reboot the node to recreate pod sandboxes"
}

case "${1:-}" in
  --rollback) rollback "${2:-}" ;;
  --reboot)   migrate; log "rebooting"; systemctl reboot --no-block ;;
  "")         migrate ;;
  -h|--help)  sed -n '2,30p' "$0" ;;
  *)          die "unknown argument: $1" ;;
esac
