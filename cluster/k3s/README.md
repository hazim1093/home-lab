# K3s Cluster Setup

Minimal K3s installation for Ubuntu/Debian with auto-start on boot.

## What You Get

- Single-node K3s cluster
- Auto-starts on boot (systemd enabled)
- Automatic OS detection (Ubuntu/Debian)
- Firewall configured automatically (if UFW is enabled)
- Traefik and ServiceLB disabled (minimal install)
- CNI is Cilium, not flannel (see [CNI: Cilium](#cni-cilium))

## Prerequisites

- **Ubuntu Server 24.04 LTS** (recommended)
- Or Debian 12
- Root/sudo access
- Internet connectivity

## Installation

### 1. Get the scripts on your server

**Option A: Git clone (recommended)**
```bash
git clone https://github.com/YOUR-USERNAME/home-lab.git
cd home-lab/cluster/k3s
```

**Option B: SCP from local machine**
```bash
scp -r cluster/k3s user@server:~/
ssh user@server
cd k3s
```

### 2. Run the install script

```bash
sudo ./install-k3s.sh
```

The script will:
- Auto-detect your OS (Ubuntu or Debian)
- Install prerequisites (curl, wget, git, vim, tar)
- Configure UFW firewall (if active)
- Disable swap
- Install K3s
- Enable auto-start on boot

Done! K3s is now installed and will start automatically on boot.

**This config has flannel disabled.** On a brand-new node that leaves k3s with
no CNI, and Flux cannot install Cilium before Flux itself is bootstrapped: boot
with flannel (comment out `flannel-backend`/`disable-network-policy` in
[config.yaml](config.yaml)), bootstrap Flux, then run `migrate-to-cilium.sh`.
On an existing cluster use the migration script directly.

## Verify

```bash
kubectl get nodes
kubectl get pods -A
systemctl status k3s
```

## Usage

### As root
```bash
kubectl get nodes
```

### As regular user
```bash
export KUBECONFIG=~/.kube/config
kubectl get nodes
```

Or add to `.bashrc`:
```bash
echo 'export KUBECONFIG=~/.kube/config' >> ~/.bashrc
```

## Upgrading k3s

Kubernetes only supports one minor version per upgrade step, so the script
upgrades through every intermediate minor (`v1.33 -> v1.34 -> v1.35 -> v1.36`)
and waits for a healthy cluster between hops.

```bash
cd ~/home-lab/cluster/k3s
git pull
sudo ./upgrade-k3s.sh --dry-run   # prints the plan against the running version
sudo ./upgrade-k3s.sh
```

Per hop the script installs the pinned release from get.k3s.io (config file and
systemd unit are untouched by that), then checks: API `/healthz`, node `Ready`,
no `Pending` pods, and an HTTPS answer from the Traefik gateway. It stops at the
first failure — the cluster keeps running, the remaining hops simply do not
happen.

Backups go to `/root/k3s-upgrade-<timestamp>/` (k3s binary, `/etc/rancher/k3s`,
a **consistent** copy of the sqlite datastore — online backup via `sqlite3` when
installed, otherwise a brief k3s stop — and a YAML dump of cluster objects).
Pods are not drained; the API is down for roughly 30s per hop, containers keep
running.

There is no cross-minor downgrade in k3s: reverting means restoring that
datastore + binary (a control-plane state rebuild) or redeploying the node.

**Latest stable is deliberately not the target for this node**: Cilium 1.20 is
tested against k8s 1.33-1.36, so `v1.36.5+k3s1` is the newest version that keeps
the CNI on a supported pair. Revisit when Cilium ships 1.37 support.

## CNI: Cilium

[config.yaml](config.yaml) sets `flannel-backend: none` and
`disable-network-policy: true`; the CNI is Cilium, deployed from
`kubernetes/components/cilium` (chart pinned there, values too).

Why Cilium: NetworkPolicies are enforced by Cilium's datapath (k3s' kube-router
controller is off) and Hubble gives per-flow L3/L4/L7 visibility.

Two values are k3s-specific and **required** — without them Cilium writes its CNI
config and binary to `/etc/cni` and `/opt/cni/bin`, which this node's containerd
does not read, so new pods come up with no address:

```yaml
cni.binPath: /var/lib/rancher/k3s/data/cni
cni.confPath: /var/lib/rancher/k3s/agent/etc/cni/net.d
```

### Switching an existing flannel cluster

```bash
cd ~/home-lab/cluster/k3s
git pull
sudo ./migrate-to-cilium.sh
sudo reboot          # moves pods that still hold a flannel sandbox onto Cilium
```

The script backs up `/etc/rancher/k3s/config.yaml`, the CNI dir and the
NetworkPolicies to `/root/k3s-cni-backup-<timestamp>/`, pre-pulls the Cilium
images, refuses to overwrite a live config that drifted from the repo (override
with `--force`), writes the new config, restarts k3s, applies the component
(Flux' helm-controller installs the chart) and smoke-tests a pod: it must get an
address from `10.42.0.0/16`, not share it with another pod, and resolve
`kubernetes.default.svc.cluster.local`.

Two windows exist between the k3s restart and the reboot, both expected:
- **No NetworkPolicy is enforced** until Cilium's agents are ready (kube-router
  is off, Cilium is not up yet). That is why the image pre-pull runs first.
- New pods can take an address a live flannel pod still holds. The smoke test
  fails if it sees a duplicate; either way, **reboot immediately**.

`--reboot` does the reboot for you, but only use it once you have confirmed the
node re-associates with WiFi by itself (this box is WiFi-only, with no console
path other than physical access). Rebooting by hand keeps that visible.

Local-path volumes and the sqlite datastore are untouched by the CNI switch.

The `cilium` Flux Kustomization ships **suspended** — resume it only after the
script has run, otherwise Cilium and flannel would both allocate from
`10.42.0.0/16`:

```bash
flux resume kustomization cilium -n flux-system   # or merge the suspend:false commit
```

### Verify

```bash
k3s kubectl get pods -A | grep -v -E 'Running|Completed'
k3s kubectl -n kube-system get ds,deploy | grep cilium
k3s kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status --brief
k3s kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg endpoint list | head
curl -sk -o /dev/null -w '%{http_code}\n' https://192.168.0.200/
```

Every running pod should appear in `endpoint list` once the node has rebooted.

Hubble relay runs in-cluster (`hubble-relay.kube-system:80`); port-forward it for
`hubble observe`:

```bash
k3s kubectl -n kube-system port-forward svc/hubble-relay 4245:80
hubble observe --follow
```

### Rollback

```bash
sudo ./migrate-to-cilium.sh --rollback
sudo reboot
```

Restores the backed-up config, removes the Cilium HelmRelease and DaemonSets and
drops its CNI config so k3s writes flannel's again. Cilium's CRDs, RBAC and the
`cilium-cni` binary stay behind — harmless, but clean them up before a future
re-install.

## Uninstall

```bash
sudo ./uninstall-k3s.sh
```

## Configuration

Edit [config.yaml](config.yaml) before installation to customize:
- Network CIDRs (default: 10.42.0.0/16 for pods, 10.43.0.0/16 for services)
- Disabled components (default: Traefik, ServiceLB)
- CNI (default: Cilium — flannel and kube-router network policy enforcement off)

See [K3s docs](https://docs.k3s.io/installation/configuration) for all options.

## Troubleshooting

**Service not running:**
```bash
systemctl status k3s
journalctl -u k3s -f
```

**Not starting on boot:**
```bash
systemctl is-enabled k3s
sudo systemctl enable k3s
```

**kubectl not found:**
```bash
sudo ln -s /usr/local/bin/k3s /usr/local/bin/kubectl
```

## Files

```
cluster/k3s/
├── install-k3s.sh       # Installation script (pinned k3s version)
├── upgrade-k3s.sh       # Minor-version upgrade, one hop at a time
├── migrate-to-cilium.sh # flannel -> Cilium switch, plus --rollback
├── cilium-images.txt    # image pre-pull hints used by the migration
├── config.yaml          # K3s configuration (Cilium, no flannel)
├── uninstall-k3s.sh     # Cleanup script
└── README.md            # This file
```

## Resources

- [K3s Documentation](https://docs.k3s.io/)
- [K3s GitHub](https://github.com/k3s-io/k3s)
