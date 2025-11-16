# K3s Cluster Setup

Minimal K3s installation for Rocky Linux with auto-start on boot.

## What You Get

- Single-node K3s cluster
- Auto-starts on boot (systemd enabled)
- Firewall configured automatically
- Traefik and ServiceLB disabled (minimal install)

## Prerequisites

- Rocky Linux 8 or 9
- Root/sudo access
- Internet connectivity

## Installation

### 1. Get the scripts on your Rocky Linux machine

**Option A: Git clone (recommended)**
```bash
git clone https://github.com/YOUR-USERNAME/home-lab.git
cd home-lab/cluster/k3s
```

**Option B: SCP from local machine**
```bash
scp -r cluster/k3s user@rocky-machine:~/
ssh user@rocky-machine
cd k3s
```

### 2. Run the install script

```bash
sudo ./install-k3s.sh
```

Done! K3s is now installed and will start automatically on boot.

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

## Uninstall

```bash
sudo ./uninstall-k3s.sh
```

## Configuration

Edit [config.yaml](config.yaml) before installation to customize:
- Network CIDRs (default: 10.42.0.0/16 for pods, 10.43.0.0/16 for services)
- Disabled components (default: Traefik, ServiceLB)

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
├── install-k3s.sh       # Installation script
├── config.yaml          # K3s configuration
├── uninstall-k3s.sh     # Cleanup script
└── README.md            # This file
```

## Resources

- [K3s Documentation](https://docs.k3s.io/)
- [K3s GitHub](https://github.com/k3s-io/k3s)
