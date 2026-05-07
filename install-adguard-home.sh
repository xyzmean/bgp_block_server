#!/bin/bash
# AdGuard Home Installation Script
# Supports Debian/Ubuntu and Arch Linux

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
AGH_VERSION="v0.107.54"
INSTALL_DIR="/opt/AdGuardHome"
SERVICE_NAME="AdGuardHome"
WEB_PORT="3000"
WEBSPORT="8443"

log() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
    exit 1
}

# Detect OS
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        OS_VERSION=$VERSION_ID
    else
        error "Cannot detect OS"
    fi
    log "Detected OS: $OS $OS_VERSION"
}

# Check if running as root
check_root() {
    if [ "$EUID" -ne 0 ]; then
        error "Please run as root"
    fi
}

# Stop existing service if running
stop_existing() {
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        log "Stopping existing AdGuard Home service..."
        systemctl stop "$SERVICE_NAME"
    fi
}

# Download and install AdGuard Home
install_adguard() {
    log "Downloading AdGuard Home ${AGH_VERSION}..."

    case "$(uname -m)" in
        x86_64)  ARCH="amd64" ;;
        aarch64) ARCH="arm64" ;;
        armv7l)  ARCH="armv7" ;;
        armv6l)  ARCH="armv6" ;;
        *)       error "Unsupported architecture" ;;
    esac

    DOWNLOAD_URL="https://github.com/AdguardTeam/AdGuardHome/releases/download/${AGH_VERSION}/AdGuardHome_linux_${ARCH}.tar.gz"
    TEMP_DIR="/tmp/AdGuardHome"

    # Download
    wget -q "$DOWNLOAD_URL" -O "/tmp/AdGuardHome.tar.gz" || error "Download failed"

    # Create install directory
    mkdir -p "$INSTALL_DIR"

    # Extract
    log "Extracting files..."
    tar -xzf "/tmp/AdGuardHome.tar.gz" -C "$TEMP_DIR" 2>/dev/null || {
        mkdir -p "$TEMP_DIR"
        tar -xzf "/tmp/AdGuardHome.tar.gz" -C "$TEMP_DIR"
    }

    # Install
    cp -r "$TEMP_DIR"/AdGuardHome/* "$INSTALL_DIR/"
    chmod +x "$INSTALL_DIR/AdGuardHome"

    # Cleanup
    rm -rf "$TEMP_DIR" "/tmp/AdGuardHome.tar.gz"

    log "AdGuard Home installed to $INSTALL_DIR"
}

# Create systemd service
create_service() {
    log "Creating systemd service..."

    cat > "/etc/systemd/system/${SERVICE_NAME}.service" << EOF
[Unit]
Description=AdGuard Home
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=${INSTALL_DIR}
ExecStart=${INSTALL_DIR}/AdGuardHome -s run
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME"
}

# Configure AdGuard Home ports
configure_ports() {
    log "Configuring AdGuard Home ports..."

    # Create/Update config with custom ports
    CONFIG_FILE="${INSTALL_DIR}/AdGuardHome.yaml"

    if [ -f "$CONFIG_FILE" ]; then
        sed -i "s/port: 80/port: $WEB_PORT/" "$CONFIG_FILE" 2>/dev/null || true
        sed -i "s/port: 443/port: $WEBSPORT/" "$CONFIG_FILE" 2>/dev/null || true
    fi
}

# Configure firewall
configure_firewall() {
    log "Configuring firewall..."

    # UFW (Debian/Ubuntu)
    if command -v ufw &> /dev/null; then
        ufw allow 53/tcp comment 'AdGuard DNS'
        ufw allow 53/udp comment 'AdGuard DNS'
        ufw allow "$WEB_PORT/tcp" comment "AdGuard Web"
        ufw allow "$WEBSPORT/tcp" comment "AdGuard HTTPS"
    fi

    # firewalld (RHEL/CentOS/Fedora)
    if command -v firewall-cmd &> /dev/null; then
        firewall-cmd --permanent --add-port=53/tcp
        firewall-cmd --permanent --add-port=53/udp
        firewall-cmd --permanent --add-port="${WEB_PORT}/tcp"
        firewall-cmd --permanent --add-port="${WEBSPORT}/tcp"
        firewall-cmd --reload
    fi
}

# Start service
start_service() {
    log "Starting AdGuard Home service..."
    systemctl start "$SERVICE_NAME"

    # Wait for service to start
    sleep 3

    if systemctl is-active --quiet "$SERVICE_NAME"; then
        log "Service started successfully!"
    else
        error "Service failed to start. Check: journalctl -u $SERVICE_NAME"
    fi
}

# Print access info
print_info() {
    local IP=$(hostname -I | awk '{print $1}')
    echo ""
    echo "============================================"
    echo -e "${GREEN}AdGuard Home installed successfully!${NC}"
    echo "============================================"
    echo ""
    echo "Web interface: http://${IP}:${WEB_PORT}"
    echo "             https://${IP}:${WEBSPORT}"
    echo ""
    echo "DNS ports: 53/tcp, 53/udp"
    echo ""
    echo "Service commands:"
    echo "  systemctl status $SERVICE_NAME"
    echo "  systemctl restart $SERVICE_NAME"
    echo "  systemctl stop $SERVICE_NAME"
    echo ""
    echo "Config file: ${INSTALL_DIR}/AdGuardHome.yaml"
    echo ""
}

# Main installation
main() {
    log "Starting AdGuard Home installation..."

    check_root
    detect_os
    stop_existing
    install_adguard
    create_service
    configure_firewall
    start_service
    configure_ports
    systemctl restart "$SERVICE_NAME"
    print_info
}

main "$@"
