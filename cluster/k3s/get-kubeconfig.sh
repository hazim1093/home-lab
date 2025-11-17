#!/bin/bash

################################################################################
# K3s Kubeconfig Export Script
#
# This script generates a kubeconfig file for accessing the K3s cluster
# from external machines (like your Mac) on the same network.
################################################################################

set -euo pipefail

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

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

# Check if K3s is installed
check_k3s_installed() {
    if ! command -v k3s &> /dev/null; then
        log_error "K3s is not installed"
        exit 1
    fi
}

# Get server IP address
get_server_ip() {
    log_info "Detecting server IP address..."

    # Try to get the primary network interface IP
    local ip_addr

    # Method 1: Get IP from default route interface
    ip_addr=$(ip route get 1.1.1.1 | grep -oP 'src \K\S+' 2>/dev/null || true)

    if [[ -z "$ip_addr" ]]; then
        # Method 2: Get first non-loopback IPv4 address
        ip_addr=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '127.0.0.1' | head -n1)
    fi

    if [[ -z "$ip_addr" ]]; then
        log_error "Could not detect server IP address"
        exit 1
    fi

    echo "$ip_addr"
}

# Generate external kubeconfig
generate_kubeconfig() {
    local server_ip=$1
    local output_file=${2:-"k3s-external.yaml"}

    log_info "Generating external kubeconfig..."

    # Check if K3s kubeconfig exists
    if [[ ! -f /etc/rancher/k3s/k3s.yaml ]]; then
        log_error "K3s kubeconfig not found at /etc/rancher/k3s/k3s.yaml"
        exit 1
    fi

    # Copy kubeconfig and replace localhost with server IP
    sed "s/127.0.0.1/${server_ip}/g" /etc/rancher/k3s/k3s.yaml > "$output_file"

    # Set proper permissions
    chmod 600 "$output_file"

    log_success "Kubeconfig generated: $output_file"
}

# Display usage instructions
display_instructions() {
    local server_ip=$1
    local output_file=$2

    echo
    log_success "========================================="
    log_success "External Kubeconfig Generated!"
    log_success "========================================="
    echo

    log_info "Server IP: $server_ip"
    log_info "Kubeconfig file: $output_file"
    echo

    log_info "To use this kubeconfig on your Mac/laptop:"
    echo
    echo "  1. Copy the kubeconfig file to your local machine:"
    echo "     scp $(whoami)@${server_ip}:$(pwd)/${output_file} ~/.kube/k3s-config"
    echo
    echo "  2. Use the kubeconfig:"
    echo "     export KUBECONFIG=~/.kube/k3s-config"
    echo "     kubectl get nodes"
    echo
    echo "  3. Or merge with existing kubeconfig:"
    echo "     KUBECONFIG=~/.kube/config:~/.kube/k3s-config kubectl config view --flatten > ~/.kube/config-merged"
    echo "     mv ~/.kube/config-merged ~/.kube/config"
    echo
    echo "  4. Switch context (if merged):"
    echo "     kubectl config use-context default"
    echo

    log_info "Testing connectivity from this server:"
    echo "  kubectl --kubeconfig=$output_file get nodes"
    echo

    log_warning "Security Notes:"
    echo "  - This kubeconfig contains cluster admin credentials"
    echo "  - Keep it secure and don't commit to git"
    echo "  - Only use on trusted networks"
    echo "  - Consider setting up proper RBAC for production"
    echo
}

# Main function
main() {
    local server_ip
    local output_file="k3s-external.yaml"

    log_info "K3s External Kubeconfig Generator"
    echo

    check_root
    check_k3s_installed

    # Get server IP
    server_ip=$(get_server_ip)
    log_success "Detected server IP: $server_ip"

    # Allow custom output file
    if [[ $# -gt 0 ]]; then
        output_file="$1"
    fi

    # Generate kubeconfig
    generate_kubeconfig "$server_ip" "$output_file"

    # Display instructions
    display_instructions "$server_ip" "$output_file"

    log_success "Done!"
}

main "$@"
