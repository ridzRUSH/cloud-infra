#!/bin/bash
set -e

# Colour output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

pass()  { echo -e "${GREEN}✓ PASS${NC}: $1"; }
fail()  { echo -e "${RED}✗ FAIL${NC}: $1"; exit 1; }
warn()  { echo -e "${YELLOW}⚠ WARN${NC}: $1"; }

# Load environment to get PORT
if [ -f /etc/infra-demo/infra-demo.env ]; then
    source /etc/infra-demo/infra-demo.env
else
    warn "Environment file missing, using default port 8080"
    PORT=8080
fi

# ----------  Service status ----------
if systemctl is-active --quiet infra-demo; then
    pass "Service 'infra-demo' is active"
else
    fail "Service 'infra-demo' is not active"
fi

if systemctl is-enabled --quiet infra-demo; then
    pass "Service 'infra-demo' is enabled"
else
    fail "Service 'infra-demo' is not enabled"
fi

# ----------  Health endpoint ----------
if curl -s -o /dev/null -w "%{http_code}" "http://localhost:$PORT/health" | grep -q 200; then
    pass "Health endpoint responds with 200 OK"
else
    fail "Health endpoint not responding or returned non-200"
fi

# ----------  Firewall ----------
if command -v ufw >/dev/null; then
    if ufw status | grep -q "Status: active"; then
        pass "UFW is active"
    else
        fail "UFW is not active"
    fi
    if ufw status | grep -q "$PORT/tcp"; then
        pass "Port $PORT is allowed in UFW"
    else
        fail "Port $PORT not allowed in UFW"
    fi
elif command -v firewall-cmd >/dev/null; then
    if firewall-cmd --state | grep -q "running"; then
        pass "firewalld is running"
    else
        fail "firewalld is not running"
    fi
    if firewall-cmd --list-ports | grep -q "$PORT/tcp"; then
        pass "Port $PORT is allowed in firewalld"
    else
        fail "Port $PORT not allowed in firewalld"
    fi
else
    warn "No firewall tool detected, skipping firewall checks"
fi

# ---------- User existence ----------
if id ops &>/dev/null; then
    pass "User 'ops' exists"
    if groups ops | grep -q sudo; then
        pass "User 'ops' has sudo privileges"
    else
        warn "User 'ops' is not in sudo group"
    fi
else
    fail "User 'ops' does not exist"
fi

# ----------  Permissions on config/log ----------
if [ -f /etc/infra-demo/infra-demo.env ]; then
    perms=$(stat -c "%a" /etc/infra-demo/infra-demo.env 2>/dev/null || stat -f "%Lp" /etc/infra-demo/infra-demo.env)
    owner=$(stat -c "%U" /etc/infra-demo/infra-demo.env 2>/dev/null || stat -f "%Su" /etc/infra-demo/infra-demo.env)
    if [ "$perms" = "600" ] && [ "$owner" = "infra-demo" ]; then
        pass "Environment file has correct permissions (600) and owner (infra-demo)"
    else
        warn "Environment file permissions: $perms, owner: $owner (expected 600, infra-demo)"
    fi
else
    warn "Environment file not found"
fi

if [ -d /var/log/infra-demo ]; then
    owner=$(stat -c "%U" /var/log/infra-demo 2>/dev/null || stat -f "%Su" /var/log/infra-demo)
    if [ "$owner" = "infra-demo" ]; then
        pass "Log directory owned by infra-demo"
    else
        warn "Log directory owner: $owner (expected infra-demo)"
    fi
else
    warn "Log directory /var/log/infra-demo not found"
fi

# ----------  Recent logs (no errors) ----------
if journalctl -u infra-demo --since "5 minutes ago" | grep -q "ERROR"; then
    warn "Service logs contain ERROR entries in the last 5 minutes"
else
    pass "No ERROR in recent service logs"
fi

# ----------  Maintenance timer ----------
if systemctl is-active --quiet infra-maintenance.timer; then
    pass "Maintenance timer is active"
else
    warn "Maintenance timer is not active"
fi

# ----------  Reboot survival  ----------
#  we only check uptime and service status
uptime_seconds=$(awk '{print int($1)}' /proc/uptime)
if [ "$uptime_seconds" -gt 60 ]; then
    pass "System has been up for more than 1 minute (reboot survival plausible)"
else
    warn "System uptime is very short; maybe reboot just happened?"
fi

echo -e "\n${GREEN}All critical checks passed.${NC}"
exit 0
