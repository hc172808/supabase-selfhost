#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

SSH_PORT="22"

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

while (($#)); do
    case "$1" in
        --ssh-port)
            (($# >= 2)) || fail "--ssh-port needs a port number."
            SSH_PORT="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: sudo bash scripts/setup-fail2ban.sh [--ssh-port PORT]"
            echo "Protects SSH login attempts when an SSH server is active."
            exit 0
            ;;
        *)
            fail "Unknown option: $1. Use --help for usage."
            ;;
    esac
done

[[ "$EUID" -eq 0 ]] || fail "Run this script as root, for example with sudo."
[[ "$SSH_PORT" =~ ^[0-9]+$ ]] && (( SSH_PORT >= 1 && SSH_PORT <= 65535 )) \
    || fail "SSH port must be between 1 and 65535."
[[ -f /etc/os-release ]] || fail "This script supports Debian or Ubuntu."
# shellcheck disable=SC1091
. /etc/os-release
case "${ID:-}" in
    debian|ubuntu) ;;
    *) fail "Unsupported operating system '${ID:-unknown}'. Use Debian or Ubuntu." ;;
esac

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y fail2ban

SSH_ACTIVE=false
if systemctl is-active --quiet ssh.service || systemctl is-active --quiet sshd.service; then
    SSH_ACTIVE=true
fi

BAN_ACTION=""
if command -v ufw >/dev/null 2>&1 \
    && ufw status 2>/dev/null | grep -q '^Status: active$' \
    && [[ -f /etc/fail2ban/action.d/ufw.conf ]]; then
    BAN_ACTION="banaction = ufw"
fi

install -d -m 0755 /etc/fail2ban/jail.d
if [[ "$SSH_ACTIVE" == true ]]; then
    cat > /etc/fail2ban/jail.d/supabase-sshd.local <<EOF
[DEFAULT]
bantime = 1h
findtime = 10m
maxretry = 5
${BAN_ACTION}

[sshd]
enabled = true
backend = systemd
port = $SSH_PORT
EOF
else
    cat > /etc/fail2ban/jail.d/supabase-sshd.local <<'EOF'
[sshd]
enabled = false
EOF
fi
chmod 0644 /etc/fail2ban/jail.d/supabase-sshd.local

fail2ban-client -t
systemctl enable --now fail2ban
systemctl restart fail2ban

echo
systemctl --no-pager --full status fail2ban || true
if [[ "$SSH_ACTIVE" == true ]]; then
    fail2ban-client status sshd
else
    echo "Fail2ban is installed and running, but SSH is not active, so its SSH jail is disabled."
    echo "If you later enable SSH, rerun this script to enable SSH protection."
fi
echo "Fail2ban protects SSH login attempts only; it does not replace the Proxmox firewall."
