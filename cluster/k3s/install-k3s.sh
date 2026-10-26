#!/bin/bash

################################################################################
# K3s Installation Script for Ubuntu/Debian
#
# Installs K3s with automatic configuration and auto-start on boot, then
# installs Cilium (the CNI) so the node is Ready before Flux is bootstrapped.
# Order on a new node: this script -> Flux bootstrap (kubernetes/bootstrap/flux).
################################################################################

set -euo pipefail

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# Detect OS
detect_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS=$ID
        OS_VERSION=$VERSION_ID

        # Only support Ubuntu/Debian
        if [[ ! "$OS" =~ ^(ubuntu|debian)$ ]]; then
            log_error "Unsupported OS: $OS"
            log_error "This script only supports Ubuntu and Debian"
            exit 1
        fi
    else
        log_error "Cannot detect OS. /etc/os-release not found."
        exit 1
    fi
}

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
        exit 1
    fi
}

# Check if K3s is already installed
check_existing_installation() {
    if command -v k3s &> /dev/null; then
        log_warning "K3s is already installed"
        k3s --version
        read -p "Do you want to reinstall? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "Installation cancelled"
            exit 0
        fi
        log_info "Proceeding with reinstallation..."
    fi
}

# Install prerequisites
install_prerequisites() {
    log_info "Installing prerequisites..."

    local packages=(
        curl
        wget
        vim
        git
        tar
    )

    log_info "Detected $OS $OS_VERSION"

    # Update package cache
    apt-get update -qq

    for package in "${packages[@]}"; do
        if ! dpkg -l | grep -qw "$package"; then
            log_info "Installing $package..."
            apt-get install -y "$package" > /dev/null 2>&1
        else
            log_info "$package is already installed"
        fi
    done

    log_success "Prerequisites installed"
}

# Configure firewall
configure_firewall() {
    log_info "Configuring firewall for K3s..."

    # Ubuntu/Debian use ufw, but it's usually not enabled by default
    if command -v ufw &> /dev/null; then
        if ufw status | grep -q "Status: active"; then
            log_info "UFW is active. Configuring K3s ports..."

            # K3s server ports
            ufw allow 6443/tcp comment 'K3s API' > /dev/null 2>&1
            ufw allow 10250/tcp comment 'K3s Kubelet' > /dev/null 2>&1
            ufw allow 8472/udp comment 'Cilium/K3s VXLAN' > /dev/null 2>&1
            ufw allow 51820/udp comment 'K3s Wireguard' > /dev/null 2>&1
            ufw allow 51821/udp comment 'K3s Wireguard' > /dev/null 2>&1

            log_success "UFW configured for K3s"
        else
            log_info "UFW is installed but not active. Skipping firewall configuration."
            log_warning "For home lab behind router, this is usually fine."
        fi
    else
        log_info "No firewall detected. Skipping firewall configuration."
        log_warning "Ensure your network/router provides adequate protection."
    fi
}

# Disable swap (recommended for Kubernetes)
disable_swap() {
    log_info "Checking swap status..."

    if swapon --show | grep -q '/'; then
        log_warning "Swap is enabled. Disabling swap..."
        swapoff -a

        # Comment out swap entries in /etc/fstab
        sed -i '/swap/s/^/#/' /etc/fstab

        log_success "Swap disabled"
    else
        log_info "Swap is already disabled"
    fi
}

# Install K3s
install_k3s() {
    log_info "Installing K3s..."

    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local config_file="$script_dir/config.yaml"

    # Check if config file exists
    if [[ ! -f "$config_file" ]]; then
        log_error "Configuration file not found: $config_file"
        exit 1
    fi

    # Create K3s config directory
    mkdir -p /etc/rancher/k3s

    # Copy config file
    cp "$config_file" /etc/rancher/k3s/config.yaml
    log_info "Configuration file copied to /etc/rancher/k3s/config.yaml"

    # Download and install K3s.
    # Pinned: a rebuild must land on the same version as upgrade-k3s.sh's plan.
    export INSTALL_K3S_SKIP_START=false
    # v1.36 is the newest k8s that Cilium 1.20 is tested against (1.33-1.36).
    export INSTALL_K3S_VERSION="${INSTALL_K3S_VERSION:-v1.36.5+k3s1}"

    curl -sfL https://get.k3s.io | sh -

    log_success "K3s installed successfully"
}

# Configure kubeconfig
configure_kubeconfig() {
    log_info "Configuring kubeconfig..."

    # Wait for kubeconfig to be created
    local max_attempts=30
    local attempt=0

    while [[ ! -f /etc/rancher/k3s/k3s.yaml ]]; do
        attempt=$((attempt + 1))
        if [[ $attempt -ge $max_attempts ]]; then
            log_error "Timeout waiting for kubeconfig file"
            exit 1
        fi
        log_info "Waiting for kubeconfig file... ($attempt/$max_attempts)"
        sleep 2
    done

    # Set proper permissions (already set in config.yaml, but ensure it)
    chmod 644 /etc/rancher/k3s/k3s.yaml

    # Create symlink for kubectl access
    if [[ ! -L /usr/local/bin/kubectl ]]; then
        ln -s /usr/local/bin/k3s /usr/local/bin/kubectl
        log_info "Created kubectl symlink"
    fi

    # Setup kubeconfig for current user
    if [[ -n "${SUDO_USER:-}" ]]; then
        local user_home
        user_home=$(eval echo "~$SUDO_USER")

        mkdir -p "$user_home/.kube"
        cp /etc/rancher/k3s/k3s.yaml "$user_home/.kube/config"
        chown -R "$SUDO_USER:$SUDO_USER" "$user_home/.kube"

        log_info "Kubeconfig copied to $user_home/.kube/config"
    fi

    log_success "Kubeconfig configured"
}

# Wait for the API server (the node stays NotReady until Cilium is installed)
wait_for_api() {
    log_info "Waiting for the API server..."
    local attempt=0
    until k3s kubectl get --raw=/healthz &> /dev/null; do
        attempt=$((attempt + 1))
        if [[ $attempt -ge 90 ]]; then
            log_error "Timeout waiting for the API server"
            journalctl -u k3s --no-pager -n 30 || true
            exit 1
        fi
        sleep 2
    done
    log_success "API server is up"
}

# Install the Helm CLI (only needed to bootstrap Cilium; Flux takes over after)
install_helm() {
    if command -v helm &> /dev/null; then
        log_info "helm is already installed: $(helm version --short)"
        return
    fi

    local version="${HELM_VERSION:-v3.18.6}"
    local arch
    case "$(uname -m)" in
        x86_64)  arch=amd64 ;;
        aarch64) arch=arm64 ;;
        armv7l)  arch=arm ;;
        *) log_error "Unsupported CPU architecture: $(uname -m)"; exit 1 ;;
    esac

    log_info "Installing helm $version ($arch)..."
    local tmp
    tmp=$(mktemp -d)
    local tarball="helm-${version}-linux-${arch}.tar.gz"
    curl -sfL "https://get.helm.sh/${tarball}" -o "$tmp/$tarball"
    curl -sfL "https://get.helm.sh/${tarball}.sha256sum" -o "$tmp/$tarball.sha256sum"
    (cd "$tmp" && sha256sum -c "$tarball.sha256sum" > /dev/null)
    tar -xzf "$tmp/$tarball" -C "$tmp"
    install -m 0755 "$tmp/linux-${arch}/helm" /usr/local/bin/helm
    rm -rf "$tmp"
    log_success "helm installed"
}

# Kernel/network prerequisites Cilium needs. Fails early with a reason instead of
# a crash-looping agent ten minutes later.
preflight_cilium() {
    log_info "Checking Cilium prerequisites..."

    local kver major minor
    kver=$(uname -r)
    major=${kver%%.*}
    minor=${kver#*.}; minor=${minor%%.*}
    if (( major < 5 || (major == 5 && minor < 10) )); then
        log_error "Kernel $kver is too old for Cilium (needs >= 5.10)"
        exit 1
    fi

    if ! stat -fc %T /sys/fs/cgroup 2> /dev/null | grep -q cgroup2fs; then
        log_error "cgroup v2 is not mounted at /sys/fs/cgroup (Cilium needs it)"
        exit 1
    fi

    # Tunnel mode needs vxlan. Report what actually failed instead of guessing:
    # a missing module (Ubuntu: linux-modules-extra-$(uname -r)) and a leftover
    # interface from a previous install look different.
    local modprobe_err ip_err
    modprobe_err=$(modprobe vxlan 2>&1) || true
    if ip_err=$(ip link add cilium-preflight type vxlan id 4242 dstport 8472 2>&1); then
        ip link delete cilium-preflight
    else
        log_error "Cannot create a vxlan interface: ${ip_err:-no output}"
        [[ -n "$modprobe_err" ]] && log_error "modprobe vxlan: $modprobe_err"
        if ip -br link | grep -q 'cilium_'; then
            log_error "Leftover Cilium interfaces exist (run uninstall-k3s.sh and reboot):"
            ip -br link | grep 'cilium_' >&2
        fi
        log_error "If the module is missing: apt install linux-modules-extra-$kver"
        exit 1
    fi

    if ! mountpoint -q /sys/fs/bpf; then
        mount bpffs /sys/fs/bpf -t bpf 2> /dev/null || log_warning "Could not mount /sys/fs/bpf (Cilium mounts it itself)"
    fi

    # NetworkManager must not touch Cilium's interfaces (WiFi boxes commonly run it).
    if systemctl is-active --quiet NetworkManager 2> /dev/null; then
        log_info "NetworkManager detected - marking Cilium interfaces unmanaged"
        mkdir -p /etc/NetworkManager/conf.d
        cat > /etc/NetworkManager/conf.d/99-cilium.conf <<'NMEOF'
[keyfile]
unmanaged-devices=interface-name:cilium_*;interface-name:lxc*
NMEOF
        systemctl reload NetworkManager || true
    fi

    log_success "Prerequisites OK (kernel $kver)"
}

# Cilium writes its CNI config/binary to the chart defaults (/etc/cni/net.d,
# /opt/cni/bin). containerd must read the same directories. With flannel-backend=none
# k3s emits no [cni] section, so containerd uses those defaults; k3s only sets its
# own dirs (/var/lib/rancher/k3s/...) when flannel is enabled. Verify instead of
# assuming, because a mismatch gives pods with no address and no useful error.
verify_cni_paths() {
    local toml=/var/lib/rancher/k3s/agent/etc/containerd/config.toml
    local attempt=0
    until [[ -f "$toml" ]]; do
        attempt=$((attempt + 1))
        if [[ $attempt -ge 60 ]]; then
            log_error "containerd config $toml never appeared"
            exit 1
        fi
        sleep 2
    done

    local bin_dir conf_dir
    bin_dir=$(grep -E '^[[:space:]]*bin_dirs?[[:space:]]*=' "$toml" | head -n1 || true)
    conf_dir=$(grep -E '^[[:space:]]*conf_dir[[:space:]]*=' "$toml" | head -n1 || true)

    if [[ -z "$bin_dir" && -z "$conf_dir" ]]; then
        log_info "containerd uses its default CNI dirs (/opt/cni/bin, /etc/cni/net.d) - matches Cilium"
        return
    fi

    # An override is only fine if it is the default spelled out.
    if { [[ -z "$bin_dir" ]] || [[ "$bin_dir" == *'/opt/cni/bin'* ]]; } \
        && { [[ -z "$conf_dir" ]] || [[ "$conf_dir" == *'"/etc/cni/net.d"'* ]]; }; then
        return
    fi

    log_error "containerd's CNI dirs differ from Cilium's defaults:"
    log_error "  ${bin_dir:-bin_dir unset}"
    log_error "  ${conf_dir:-conf_dir unset}"
    log_error "Set cni.binPath/cni.confPath in kubernetes/components/cilium/values.yaml to these paths and re-run."
    exit 1
}

# Everything needed to diagnose a failed Cilium install in one paste-able file.
cilium_diagnostics() {
    local out=/root/cilium-install-diagnostics.txt
    log_warning "Cilium did not come up - collecting diagnostics into $out"
    {
        echo "### date";               date
        echo "### uname";              uname -a
        echo "### nodes";              k3s kubectl get nodes -o wide
        echo "### node conditions";    k3s kubectl describe node | sed -n '/Conditions:/,/Addresses:/p'
        echo "### kube-system pods";   k3s kubectl -n kube-system get pods -o wide
        echo "### cilium describe";    k3s kubectl -n kube-system describe ds/cilium | tail -60
        for c in config mount-cgroup apply-sysctl-overwrites mount-bpf-fs clean-cilium-state install-cni-binaries; do
            echo "### cilium init container: $c"
            k3s kubectl -n kube-system logs ds/cilium -c "$c" --tail=40 2>&1
        done
        echo "### cilium-agent logs";  k3s kubectl -n kube-system logs ds/cilium -c cilium-agent --tail=120 2>&1
        echo "### operator logs";      k3s kubectl -n kube-system logs deploy/cilium-operator --tail=60 2>&1
        echo "### CNI dirs"
        ls -la /etc/cni/net.d /opt/cni/bin /var/lib/rancher/k3s/agent/etc/cni/net.d /var/lib/rancher/k3s/data/cni 2>&1
        echo "### containerd cni config"; grep -n -i -A3 "cni" /var/lib/rancher/k3s/agent/etc/containerd/config.toml 2>&1
        echo "### links";              ip -br link
        echo "### k3s journal";        journalctl -u k3s --no-pager -n 80
    } > "$out" 2>&1 || true
    log_warning "Paste $out when asking for help"
}

# Install Cilium BEFORE Flux, following Cilium's own k3s guide
# (docs.cilium.io/en/stable/installation/k3s). With flannel disabled the node has
# no CNI, so no pod - Flux' controllers included - can start until Cilium runs.
#
# Bootstrap installs a minimal Cilium (no Hubble/metrics) so that anything slow or
# optional cannot fail the CNI itself. Flux' HelmRelease (same release name and
# namespace, same chart version) then adopts it and upgrades to the full
# values.yaml, so any failure from there on is isolated from basic networking.
install_cilium() {
    if ! grep -qE '^flannel-backend:[[:space:]]*none' /etc/rancher/k3s/config.yaml; then
        log_warning "flannel is enabled in config.yaml - skipping Cilium"
        return
    fi

    local script_dir component version
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    component="$script_dir/../../kubernetes/components/cilium"
    if [[ ! -f "$component/values.yaml" || ! -f "$component/helmrelease.yaml" ]]; then
        log_error "Cilium component not found at $component - run from a full checkout of home-lab"
        exit 1
    fi
    version=$(awk '/chart: cilium/ {f=1} f && /version:/ {gsub(/"/, "", $2); print $2; exit}' "$component/helmrelease.yaml")
    if [[ -z "$version" ]]; then
        log_error "Could not read the Cilium chart version from helmrelease.yaml"
        exit 1
    fi

    preflight_cilium
    wait_for_api
    verify_cni_paths
    install_helm

    log_info "Installing Cilium $version (minimal; this pulls images, a few minutes)..."
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
    if ! helm upgrade --install cilium cilium \
        --repo https://helm.cilium.io \
        --version "$version" \
        --namespace kube-system \
        --values "$component/values.yaml" \
        --set hubble.enabled=false \
        --set hubble.relay.enabled=false \
        --set prometheus.enabled=false \
        --set operator.prometheus.enabled=false \
        --wait --timeout 8m; then
        cilium_diagnostics
        exit 1
    fi
    log_success "Cilium $version installed"

    log_info "Smoke test: node Ready, CoreDNS up, a new pod resolves cluster DNS..."
    if ! k3s kubectl wait --for=condition=Ready node --all --timeout=180s \
        || ! k3s kubectl -n kube-system rollout status deploy/coredns --timeout=180s \
        || ! k3s kubectl run cilium-smoke --rm -i --restart=Never --image=busybox:1.36 --pod-running-timeout=2m \
            -- nslookup kubernetes.default.svc.cluster.local; then
        cilium_diagnostics
        exit 1
    fi
    log_success "Pod networking and cluster DNS work"
}

# Verify installation
verify_installation() {
    log_info "Verifying K3s installation..."

    # Check if K3s service is running
    if systemctl is-active --quiet k3s; then
        log_success "K3s service is running"
    else
        log_error "K3s service is not running"
        systemctl status k3s --no-pager
        exit 1
    fi

    # Wait for node to be ready
    log_info "Waiting for node to be ready..."
    local max_attempts=60
    local attempt=0

    while ! k3s kubectl get nodes 2>/dev/null | grep -q "Ready"; do
        attempt=$((attempt + 1))
        if [[ $attempt -ge $max_attempts ]]; then
            log_error "Timeout waiting for node to be ready"
            k3s kubectl get nodes
            exit 1
        fi
        log_info "Waiting for node... ($attempt/$max_attempts)"
        sleep 2
    done

    log_success "Node is ready"
}

# Display cluster information
display_cluster_info() {
    echo
    log_success "========================================="
    log_success "K3s Installation Complete!"
    log_success "========================================="
    echo

    log_info "K3s Version:"
    k3s --version | head -n 1
    echo

    log_info "Node Status:"
    k3s kubectl get nodes -o wide
    echo

    log_info "System Pods:"
    k3s kubectl get pods -A
    echo

    log_info "Kubeconfig location: /etc/rancher/k3s/k3s.yaml"

    if [[ -n "${SUDO_USER:-}" ]]; then
        local user_home
        user_home=$(eval echo "~$SUDO_USER")
        log_info "User kubeconfig: $user_home/.kube/config"
        echo
        log_info "You can now run kubectl commands as $SUDO_USER:"
        echo "  kubectl get nodes"
    fi
    echo

    log_info "Next steps:"
    echo "  1. Bootstrap Flux: see kubernetes/bootstrap/flux/README.md"
    echo "     (Cilium is already running; Flux adopts it from kubernetes/components/cilium)"
    echo "  2. Check the CNI: k3s kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status --brief"
    echo
}

# Main installation flow
main() {
    # Detect OS first
    detect_os

    log_info "Starting K3s installation..."
    log_info "Detected OS: $OS $OS_VERSION"
    echo

    check_root

    # k3s already installed and only the Cilium step failed: skip straight to it.
    if [[ "${1:-}" == "--cilium-only" ]]; then
        command -v k3s &> /dev/null || { log_error "k3s is not installed - run without --cilium-only"; exit 1; }
        install_cilium
        verify_installation
        display_cluster_info
        log_success "Cilium installation completed successfully!"
        return
    fi

    check_existing_installation
    install_prerequisites
    configure_firewall
    disable_swap
    install_k3s
    configure_kubeconfig
    install_cilium
    verify_installation
    display_cluster_info

    log_success "Installation completed successfully!"
}

main "$@"
