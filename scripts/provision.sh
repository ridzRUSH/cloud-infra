#!/bin/bash
set -euo pipefail

# --------------------------------------------
# Provisioning script – idempotent, safe
# Supports Ubuntu/Debian & RHEL/Rocky
# --------------------------------------------

# Colours for pretty output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# ---------- detect OS ----------
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
    VERSION=$VERSION_ID
else
    log_error "Cannot detect OS. Only Ubuntu/Debian/Rocky supported."
fi

log_info "Detected OS: $OS $VERSION"

# ---------- set package manager ----------
case $OS in
    ubuntu|debian)
        PKG_UPDATE="apt update"
        PKG_INSTALL="apt install -y"
        PKG_REMOVE="apt remove -y"
        PKG_LIST=("python3" "ufw" "curl" "sudo" "systemd" "logrotate")
        # also install python3-venv if needed (not required for built-in http.server)
        ;;
    rocky|rhel|centos)
        PKG_UPDATE="dnf check-update || true"
        PKG_INSTALL="dnf install -y"
        PKG_REMOVE="dnf remove -y"
        PKG_LIST=("python3" "firewalld" "curl" "sudo" "systemd" "logrotate")
        ;;
    *)
        log_error "Unsupported OS: $OS"
        ;;
esac

# ---------- helper: command exists? ----------
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# ---------- update & install packages ----------
log_info "Updating package index..."
eval "$PKG_UPDATE" || log_warn "Update had issues (maybe non-zero exit), continuing..."

log_info "Installing required packages: ${PKG_LIST[*]}"
eval "$PKG_INSTALL ${PKG_LIST[*]}" || log_error "Package installation failed."

# ---------- set hostname ----------
HOSTNAME="infra-demo"
if [ "$(hostname)" != "$HOSTNAME" ]; then
    log_info "Setting hostname to $HOSTNAME"
    hostnamectl set-hostname "$HOSTNAME" || echo "$HOSTNAME" > /etc/hostname
    # ensure /etc/hosts entry
    if ! grep -q "$HOSTNAME" /etc/hosts; then
        echo "127.0.1.1 $HOSTNAME" >> /etc/hosts
    fi
else
    log_info "Hostname already $HOSTNAME"
fi

# ---------- set timezone to UTC ----------
if [ -f /etc/timezone ]; then
    current_tz=$(cat /etc/timezone)
    if [ "$current_tz" != "UTC" ]; then
        log_info "Setting timezone to UTC"
        timedatectl set-timezone UTC || echo "UTC" > /etc/timezone
    else
        log_info "Timezone already UTC"
    fi
else
    timedatectl set-timezone UTC 2>/dev/null || echo "UTC" > /etc/timezone
fi

# ---------- create admin user 'ops' ----------
if id "ops" &>/dev/null; then
    log_info "User 'ops' already exists."
else
    log_info "Creating user 'ops' with sudo privileges."
    useradd -m -s /bin/bash -G sudo ops
    echo "ops:changeme" | chpasswd
    log_warn "Password for 'ops' is 'changeme'. Please change immediately!"
fi

# ---------- create service user 'infra-demo' ----------
if id "infra-demo" &>/dev/null; then
    log_info "User 'infra-demo' already exists."
else
    log_info "Creating system user 'infra-demo' for the service."
    useradd -r -s /usr/sbin/nologin -d /opt/infra-demo infra-demo
fi

# ---------- create directories ----------
mkdir -p /opt/infra-demo
mkdir -p /var/log/infra-demo
mkdir -p /etc/infra-demo

# ---------- copy app files ----------
log_info "Deploying Python app..."
cat > /opt/infra-demo/app.py << 'EOF'
#!/usr/bin/env python3
import os
import sys
import http.server
import socketserver
import logging
from datetime import datetime

PORT = int(os.environ.get('PORT', 8080))
LOG_PATH = os.environ.get('LOG_PATH', '/var/log/infra-demo/app.log')

# Configure logging
logging.basicConfig(
    filename=LOG_PATH,
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s'
)

class HealthHandler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/health':
            self.send_response(200)
            self.send_header('Content-type', 'text/plain')
            self.end_headers()
            self.wfile.write(b'OK')
            logging.info('Health check OK')
        else:
            self.send_response(404)
            self.end_headers()
            self.wfile.write(b'Not Found')

if __name__ == '__main__':
    try:
        with socketserver.TCPServer(("", PORT), HealthHandler) as httpd:
            logging.info(f'Service started on port {PORT}')
            httpd.serve_forever()
    except Exception as e:
        logging.error(f'Failed to start: {e}')
        sys.exit(1)
EOF

# ensure correct ownership
chown -R infra-demo:infra-demo /opt/infra-demo
chmod 755 /opt/infra-demo/app.py

# ---------- environment file ----------
log_info "Creating environment file /etc/infra-demo/infra-demo.env"
cat > /etc/infra-demo/infra-demo.env << 'EOF'
PORT=8080
LOG_PATH=/var/log/infra-demo/app.log
EOF
chown infra-demo:infra-demo /etc/infra-demo/infra-demo.env
chmod 600 /etc/infra-demo/infra-demo.env

# ---------- copy systemd service files ----------
log_info "Installing systemd unit files..."
cp systemd/infra-demo.service /etc/systemd/system/
cp systemd/infra-maintenance.service /etc/systemd/system/
cp systemd/infra-maintenance.timer /etc/systemd/system/

# ---------- maintenance script ----------
log_info "Deploying maintenance script..."
cat > /usr/local/bin/infra-maintenance.sh << 'EOF'
#!/bin/bash
# Clean old logs (older than 7 days) and collect a health snapshot
LOG_DIR="/var/log/infra-demo"
find "$LOG_DIR" -name "*.log" -type f -mtime +7 -delete 2>/dev/null
# Also compress current log if large
if [ -f "$LOG_DIR/app.log" ] && [ $(stat -c%s "$LOG_DIR/app.log") -gt 1048576 ]; then
    gzip "$LOG_DIR/app.log"
    touch "$LOG_DIR/app.log"
    chown infra-demo:infra-demo "$LOG_DIR/app.log"
fi
echo "Maintenance run at $(date)" >> /var/log/infra-maintenance.log
EOF
chmod +x /usr/local/bin/infra-maintenance.sh

# ---------- enable & start service ----------
log_info "Reloading systemd and starting services..."
systemctl daemon-reload
systemctl enable infra-demo.service
systemctl start infra-demo.service
systemctl enable infra-maintenance.timer
systemctl start infra-maintenance.timer

# ---------- firewall configuration ----------
log_info "Configuring firewall..."
if command_exists ufw; then
    ufw default deny incoming >/dev/null
    ufw default allow outgoing >/dev/null
    ufw allow ssh >/dev/null
    # read port from env file
    source /etc/infra-demo/infra-demo.env
    ufw allow "$PORT"/tcp >/dev/null
    echo "y" | ufw enable >/dev/null
    log_info "UFW enabled with SSH and port $PORT open."
elif command_exists firewall-cmd; then
    systemctl start firewalld
    systemctl enable firewalld
    firewall-cmd --permanent --add-service=ssh
    source /etc/infra-demo/infra-demo.env
    firewall-cmd --permanent --add-port="$PORT"/tcp
    firewall-cmd --reload
    log_info "firewalld configured with SSH and port $PORT open."
else
    log_warn "No firewall tool found. Skipping firewall configuration."
fi

# ---------- SSH hardening ----------
log_info "Hardening SSH (disabling root login)..."
SSHD_CONFIG="/etc/ssh/sshd_config"
if grep -q "^PermitRootLogin" "$SSHD_CONFIG"; then
    sed -i 's/^PermitRootLogin.*/PermitRootLogin no/' "$SSHD_CONFIG"
else
    echo "PermitRootLogin no" >> "$SSHD_CONFIG"
fi
# Optionally disable password auth? For local VM we leave it enabled.
# Uncomment next line to enforce key-only (not recommended for local lab)
# sed -i 's/^#PasswordAuthentication yes/PasswordAuthentication no/' "$SSHD_CONFIG"

systemctl restart sshd || systemctl restart ssh

# ---------- set permissions on sensitive directories ----------
chown root:root /etc/infra-demo
chmod 750 /etc/infra-demo
chown infra-demo:infra-demo /var/log/infra-demo
chmod 755 /var/log/infra-demo

# ---------- idempotency: second run should do nothing ----------
log_info "Provisioning completed successfully."
