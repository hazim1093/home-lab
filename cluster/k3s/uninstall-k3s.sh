#!/bin/bash

################################################################################
# K3s Uninstall Script for Ubuntu/Debian
#
# This script completely removes K3s and cleans up all related configurations.
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

# Confirm uninstallation
confirm_uninstall() {
    log_warning "========================================="
    log_warning "K3s UNINSTALLATION"
    log_warning "========================================="
    echo
    log_warning "This will completely remove K3s and all associated data!"
    log_warning "All running containers and configurations will be deleted."
    echo

    read -p "Are you sure you want to continue? (yes/N): " -r
    echo
    if [[ ! $REPLY == "yes" ]]; then
        log_info "Uninstallation cancelled"
        exit 0
    fi
}

# Check if K3s is installed
check_k3s_installed() {
    if ! command -v k3s &> /dev/null; then
        log_warning "K3s is not installed"
        exit 0
    fi
}

# Stop K3s service
stop_k3s_service() {
    log_info "Stopping K3s service..."

    if systemctl is-active --quiet k3s; then
        systemctl stop k3s
        log_success "K3s service stopped"
    else
        log_info "K3s service is not running"
    fi
}

# Run K3s uninstall script
run_k3s_uninstall() {
    log_info "Running K3s uninstall script..."

    if [[ -f /usr/local/bin/k3s-uninstall.sh ]]; then
        /usr/local/bin/k3s-uninstall.sh
        log_success "K3s uninstalled"
    else
        log_warning "K3s uninstall script not found, continuing with manual cleanup..."
    fi
}

# Clean up firewall rules
cleanup_firewall() {
    log_info "Cleaning up firewall rules..."

    if command -v ufw &> /dev/null && ufw status | grep -q "Status: active"; then
        log_info "Removing UFW rules for K3s..."

        ufw delete allow 6443/tcp > /dev/null 2>&1 || true
        ufw delete allow 10250/tcp > /dev/null 2>&1 || true
        ufw delete allow 8472/udp > /dev/null 2>&1 || true
        ufw delete allow 51820/udp > /dev/null 2>&1 || true
        ufw delete allow 51821/udp > /dev/null 2>&1 || true

        log_success "UFW rules cleaned up"
    else
        log_info "UFW not active, skipping firewall cleanup"
    fi
}

# Clean up configuration files
cleanup_config_files() {
    log_info "Cleaning up configuration files..."

    local files_to_remove=(
        "/etc/rancher"
        "/var/lib/rancher"
    )

    for file in "${files_to_remove[@]}"; do
        if [[ -e "$file" ]]; then
            log_info "Removing $file..."
            rm -rf "$file"
        fi
    done

    log_success "Configuration files cleaned up"
}

# Clean up kubeconfig files
cleanup_kubeconfig() {
    log_info "Cleaning up kubeconfig files..."

    # Clean up root kubeconfig
    if [[ -d /root/.kube ]]; then
        log_info "Removing /root/.kube..."
        rm -rf /root/.kube
    fi

    # Clean up user kubeconfig if script was run with sudo
    if [[ -n "${SUDO_USER:-}" ]]; then
        local user_home
        user_home=$(eval echo "~$SUDO_USER")

        if [[ -d "$user_home/.kube" ]]; then
            log_info "Removing $user_home/.kube..."
            rm -rf "$user_home/.kube"
        fi
    fi

    log_success "Kubeconfig files cleaned up"
}

# Clean up kubectl symlink
cleanup_kubectl_symlink() {
    log_info "Cleaning up kubectl symlink..."

    if [[ -L /usr/local/bin/kubectl ]]; then
        local link_target
        link_target=$(readlink /usr/local/bin/kubectl)

        if [[ "$link_target" == "/usr/local/bin/k3s" ]]; then
            log_info "Removing kubectl symlink..."
            rm -f /usr/local/bin/kubectl
            log_success "kubectl symlink removed"
        else
            log_warning "kubectl symlink exists but points to: $link_target"
            log_warning "Not removing as it may not be K3s-related"
        fi
    else
        log_info "No kubectl symlink to remove"
    fi
}

# Clean up CNI configurations
cleanup_cni() {
    log_info "Cleaning up CNI configurations..."

    local cni_dirs=(
        "/etc/cni/net.d"
        "/opt/cni/bin"
        "/var/lib/cni"
    )

    for dir in "${cni_dirs[@]}"; do
        if [[ -d "$dir" ]]; then
            log_info "Removing $dir..."
            rm -rf "$dir"
        fi
    done

    log_success "CNI configurations cleaned up"
}

# Verify cleanup
verify_cleanup() {
    log_info "Verifying cleanup..."

    local issues=0

    # Check if k3s command still exists
    if command -v k3s &> /dev/null; then
        log_warning "k3s command still exists"
        issues=1
    fi

    # Check if K3s service exists
    if systemctl list-unit-files | grep -q k3s; then
        log_warning "K3s service still exists"
        issues=1
    fi

    # Check for remaining processes
    if pgrep -f k3s &> /dev/null; then
        log_warning "K3s processes still running"
        issues=1
    fi

    if [[ $issues -eq 0 ]]; then
        log_success "Cleanup verified successfully"
    else
        log_warning "Some cleanup issues detected, but main components removed"
    fi
}

# Display final status
display_final_status() {
    echo
    log_success "========================================="
    log_success "K3s Uninstallation Complete!"
    log_success "========================================="
    echo

    log_info "The following has been removed:"
    echo "  - K3s binaries and services"
    echo "  - K3s configuration files"
    echo "  - Kubeconfig files"
    echo "  - CNI configurations"
    echo "  - Firewall rules"
    echo

    log_info "System state:"
    echo "  - Swap: $(if swapon --show | grep -q '/'; then echo 'enabled'; else echo 'disabled (not changed)'; fi)"
    echo "  - Firewalld: $(systemctl is-active firewalld 2>/dev/null || echo 'inactive')"
    echo

    log_info "You can now reinstall K3s by running:"
    echo "  sudo ./install-k3s.sh"
    echo
}

# Main uninstall flow
main() {
    # Detect OS first
    detect_os

    log_info "Starting K3s uninstallation..."
    log_info "Detected OS: $OS $OS_VERSION"
    echo

    check_root
    check_k3s_installed
    confirm_uninstall
    stop_k3s_service
    run_k3s_uninstall
    cleanup_firewall
    cleanup_config_files
    cleanup_kubeconfig
    cleanup_kubectl_symlink
    cleanup_cni
    verify_cleanup
    display_final_status

    log_success "Uninstallation completed successfully!"
}

main "$@"
