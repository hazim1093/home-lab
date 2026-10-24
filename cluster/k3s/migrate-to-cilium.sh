#!/usr/bin/env bash
#
# Replace k3s' flannel CNI with Cilium on the running single-node cluster.
#
# What it does, in order:
#   1. backs up the k3s config, the CNI dir and the current NetworkPolicies
#   2. warms the image cache (keeps the outage short)
#   3. installs the repo's k3s config.yaml (flannel-backend: none,
#      disable-network-policy: true) and restarts k3s
#   4. applies kubernetes/components/cilium, which creates the HelmRelease;
#      Flux' helm-controller installs the chart
#   5. waits for Cilium and smoke-tests a pod (address + cluster DNS)
#
# Two windows exist until the node is rebooted, and both are expected:
#   - no NetworkPolicy is enforced between the k3s restart and Cilium becoming
#     ready (kube-router is off and Cilium is not up yet)
#   - pods created in that window take addresses from the same 10.42.0.x range
#     that flannel pods still hold, so a fresh pod can collide with one
# Reboot immediately after the script finishes. See cluster/k3s/README.md.
#
# Usage:
#   sudo ./migrate-to-cilium.sh            # migrate, then reboot by hand
#   sudo ./migrate-to-cilium.sh --reboot   # migrate, then reboot (unattended; only
#                                          # after you have verified WiFi autoconnect)
#   sudo ./migrate-to-cilium.sh --rollback [backup-dir]
#   --force                                # allow a live k3s config that differs
#                                          # from the repo beyond the CNI switch
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(cd "$SCRIPT_DIR/../.." && pwd)
COMPONENT="$REPO_DIR/kubernetes/components/cilium"
CONF=/etc/rancher/k3s/config.yaml
IMAGES="$SCRIPT_DIR/cilium-images.txt"

MODE=migrate
REBOOT=0
FORCE=0
ROLLBACK_DIR=""

log()  { printf '\n==> %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run as root (sudo $0)"

for arg in "$@"; do
  case "$arg" in
    --rollback) MODE=rollback ;;
    --reboot)   REBOOT=1 ;;
    --force)    FORCE=1 ;;
    -h|--help)  sed -n '2,31p' "$0"; exit 0 ;;
    -*)         die "unknown argument: $arg" ;;
    *)          ROLLBACK_DIR=$arg ;;
  esac
done

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
  local failed=0
  if [ ! -s "$IMAGES" ]; then
    warn "$IMAGES missing/empty - images will pull during the switch, which extends the window where no NetworkPolicy is enforced"
    return 0
  fi
  while read -r image; do
    case "$image" in ''|\#*) continue ;; esac
    log "pulling $image"
    k3s crictl pull "$image" >/dev/null 2>&1 || { warn "could not pre-pull $image"; failed=$((failed + 1)); }
  done < "$IMAGES"
  if [ "$failed" -gt 0 ]; then
    warn "$failed image(s) not cached: the switch will take longer and NetworkPolicies stay unenforced for that much longer"
  fi
}

# Refuse to replace a live config that has drifted: node-ip, tls-san or a token
# added by hand would be silently lost and could keep the API down on restart.
check_config_drift() {
  local drift
  drift=$(diff -u "$CONF" "$REPO_DIR/cluster/k3s/config.yaml" 2>/dev/null | grep -E '^[+-]' \
    | grep -vE '^(---|\+\+\+)' \
    | grep -vE '^[+-][[:space:]]*(#|$)' \
    | grep -vE '^[+-](flannel-backend|disable-network-policy):' || true)
  if [ -n "$drift" ]; then
    printf '%s\n' "$drift" >&2
    if [ "$FORCE" -ne 1 ]; then
      die "live $CONF differs beyond the CNI switch (above) - reconcile it, or re-run with --force"
    fi
    warn "--force: the lines above will be replaced by the repo version"
  fi
}

smoke_test() {
  local name=cilium-smoke-$$ ip="" phase="" dup=0 logs=""
  log "smoke test: new pod -> cluster DNS through the Cilium datapath"

  # busybox is tiny, and the DNS query is a real end-to-end check
  # (pod -> Service VIP -> CoreDNS) rather than just "an address appeared".
  k3s kubectl run "$name" --image=busybox:1.36 --restart=Never --command -- \
    nslookup kubernetes.default.svc.cluster.local >/dev/null || return 1

  for _ in $(seq 1 60); do
    phase=$(k3s kubectl get pod "$name" -o jsonpath='{.status.phase}' 2>/dev/null || true)
    ip=$(k3s kubectl get pod "$name" -o jsonpath='{.status.podIP}' 2>/dev/null || true)
    case "$phase" in Running|Succeeded) [ -n "$ip" ] && break ;; esac
    sleep 5
  done

  if [ -z "$ip" ]; then
    k3s kubectl describe pod "$name" 2>/dev/null | tail -20 || true
    k3s kubectl delete pod "$name" --wait=false >/dev/null 2>&1 || true
    return 1
  fi

  case "$ip" in
    10.42.*) ;;
    *) k3s kubectl delete pod "$name" --wait=false >/dev/null 2>&1 || true
       die "smoke pod got $ip, expected an address from 10.42.0.0/16" ;;
  esac

  # Sharing an address with a live flannel pod means both CNIs are allocating.
  dup=$(k3s kubectl get pods -A -o jsonpath='{range .items[*]}{.status.podIP}{"\n"}{end}' 2>/dev/null \
    | grep -cx "$ip" || true)
  if [ "${dup:-0}" -gt 1 ]; then
    k3s kubectl delete pod "$name" --wait=false >/dev/null 2>&1 || true
    die "$dup pods share $ip - Cilium and flannel are both allocating; reboot before doing anything else"
  fi

  logs=$(k3s kubectl logs "$name" 2>&1 || true)
  k3s kubectl delete pod "$name" --wait=false >/dev/null 2>&1 || true

  if ! printf '%s' "$logs" | grep -q "kubernetes.default.svc.cluster.local"; then
    printf '%s\n' "$logs" | tail -10 >&2
    die "smoke pod could not resolve the kubernetes Service - datapath or DNS is broken"
  fi
  log "pod got $ip and resolved cluster DNS (Cilium datapath works)"
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

  log "checking $CONF for drift"
  check_config_drift

  log "writing $CONF (flannel off, kube-router network policy off)"
  diff -u "$CONF" "$REPO_DIR/cluster/k3s/config.yaml" || true
  install -m 0644 "$REPO_DIR/cluster/k3s/config.yaml" "$CONF"

  log "restarting k3s without flannel (NetworkPolicies are unenforced from here until Cilium is up)"
  systemctl restart k3s
  wait_api || die "API did not come back - restore $dir/config.yaml and restart k3s"

  log "applying $COMPONENT (HelmRelease -> helm-controller installs Cilium)"
  # Apply the HelmRepository as well, so the script works whether or not the
  # PR that adds it to flux-system/repos has been merged yet.
  k3s kubectl apply -f "$REPO_DIR/kubernetes/components/flux-system/repos/cilium.yaml"
  k3s kubectl apply -k "$COMPONENT"

  log "waiting for Cilium (images may still be pulling)"
  wait_cilium || die "Cilium did not become ready - see: k3s kubectl -n kube-system get pods"

  local status
  if status=$(k3s kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status --brief 2>&1); then
    printf '%s\n' "$status"
  else
    warn "cilium-dbg status failed: $status"
  fi

  smoke_test || die "new pods are not getting a working Cilium datapath"

  cat <<EOF

------------------------------------------------------------------
Cilium is up and NetworkPolicies are enforced again.

Pods that were running before the switch still hold their old
flannel sandbox, and fresh Cilium addresses come from the same
10.42.0.x range, so reboot now to close both windows:

    sudo reboot

After it is back (and WiFi has re-associated):

    k3s kubectl get pods -A | grep -v -E 'Running|Completed'
    k3s kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status
    curl -sk -o /dev/null -w '%{http_code}\\n' https://192.168.0.200/

Then merge the suspend:false flip for the cilium Kustomization.
Rollback at any point: sudo $0 --rollback
------------------------------------------------------------------
EOF

  if [ "$REBOOT" -eq 1 ]; then
    log "rebooting"
    systemctl reboot --no-block
  fi
}

rollback() {
  local dir=$ROLLBACK_DIR
  if [ -z "$dir" ]; then
    dir=$(find /root -maxdepth 1 -type d -name 'k3s-cni-backup-*' 2>/dev/null | sort | tail -1 || true)
  fi
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
  warn "Cilium CRDs, RBAC and the cilium-cni binary stay behind - harmless, but remove them before a future re-install"
}

case "$MODE" in
  rollback) rollback ;;
  *)        migrate ;;
esac
