#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

TUNNEL_SOURCE=""
SSH_SOURCE=""
SSH_PORT="22"
SSH_PORT_SET=false
NO_SSH=false
DEDICATED_CT_CONFIRMED=false
DRY_RUN=false

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
Usage:
  sudo bash scripts/setup-firewall.sh \
    --confirm-dedicated-ct \
    --tunnel-source <LAN-IP-or-CIDR> \
    (--ssh-source <admin-IP-or-CIDR> [--ssh-port <port>] | --no-ssh) \
    [--dry-run]

Examples:
  # Tunnel connector and SSH administration are on known LAN addresses:
  sudo bash scripts/setup-firewall.sh --confirm-dedicated-ct \
    --tunnel-source 192.168.18.31/32 \
    --ssh-source 192.168.18.10/32 --ssh-port 22

  # Manage the CT only from the Proxmox console:
  sudo bash scripts/setup-firewall.sh --confirm-dedicated-ct \
    --tunnel-source 192.168.18.31/32 --no-ssh

This configures UFW inside the CT for Cloudflare Tunnel mode. It does not
configure the Proxmox host firewall.
Pass --dry-run to validate and print the plan without installing or changing anything.
EOF
}

while (($#)); do
    case "$1" in
        --tunnel-source)
            (($# >= 2)) || fail "--tunnel-source needs an IP address or CIDR."
            TUNNEL_SOURCE="$2"
            shift 2
            ;;
        --ssh-source)
            (($# >= 2)) || fail "--ssh-source needs an IP address or CIDR."
            SSH_SOURCE="$2"
            shift 2
            ;;
        --ssh-port)
            (($# >= 2)) || fail "--ssh-port needs a port number."
            SSH_PORT="$2"
            SSH_PORT_SET=true
            shift 2
            ;;
        --no-ssh)
            NO_SSH=true
            shift
            ;;
        --confirm-dedicated-ct)
            DEDICATED_CT_CONFIRMED=true
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            fail "Unknown option: $1"
            ;;
    esac
done

[[ "$DEDICATED_CT_CONFIRMED" == true ]] \
    || fail "This changes the CT's incoming firewall policy. Review the guide and pass --confirm-dedicated-ct only if this CT is dedicated to Supabase."
[[ -n "$TUNNEL_SOURCE" ]] || fail "Provide the Tunnel connector's LAN source using --tunnel-source."
[[ ! ( -n "$SSH_SOURCE" && "$NO_SSH" == true ) ]] \
    || fail "Use either --ssh-source or --no-ssh, not both."
[[ -n "$SSH_SOURCE" || "$NO_SSH" == true ]] \
    || fail "Provide --ssh-source for remote SSH access, or explicitly pass --no-ssh if you will use the Proxmox console."
[[ "$SSH_PORT" =~ ^[0-9]+$ ]] && (( SSH_PORT >= 1 && SSH_PORT <= 65535 )) \
    || fail "SSH port must be between 1 and 65535."

if [[ "$NO_SSH" == true && -n "${SSH_CONNECTION:-}" ]]; then
    fail "You appear to be connected over SSH. Do not use --no-ssh in this session; allow your admin source with --ssh-source."
fi

command -v python3 >/dev/null 2>&1 || fail "python3 is required. Install it with apt before running this script."

normalize_network() {
    python3 - "$1" <<'PY'
import ipaddress
import sys

try:
    print(ipaddress.ip_network(sys.argv[1], strict=False))
except ValueError as exc:
    print(f"Invalid IP address or CIDR: {exc}", file=sys.stderr)
    sys.exit(1)
PY
}

TUNNEL_SOURCE="$(normalize_network "$TUNNEL_SOURCE")" \
    || fail "Invalid --tunnel-source value."
if [[ -n "$SSH_SOURCE" ]]; then
    SSH_SOURCE="$(normalize_network "$SSH_SOURCE")" \
        || fail "Invalid --ssh-source value."
fi

if [[ -n "${SSH_CONNECTION:-}" ]]; then
    read -r CURRENT_SSH_CLIENT _ _ CURRENT_SSH_SERVER_PORT <<< "$SSH_CONNECTION"
    CURRENT_SSH_SOURCE="$(normalize_network "$CURRENT_SSH_CLIENT")" \
        || fail "Could not safely determine the current SSH client address."
    if [[ "$SSH_PORT_SET" != true ]]; then
        SSH_PORT="$CURRENT_SSH_SERVER_PORT"
    fi
else
    CURRENT_SSH_SOURCE=""
    CURRENT_SSH_SERVER_PORT=""
fi

show_plan() {
    echo
    echo "Planned UFW policy:"
    echo "  Default incoming: DENY"
    echo "  Default outgoing: ALLOW"
    echo "  Allow TCP 80 from Tunnel source: $TUNNEL_SOURCE"
    if [[ "$NO_SSH" == true ]]; then
        echo "  SSH: no allow rule (manage this CT from the Proxmox console)"
    else
        echo "  Allow TCP $SSH_PORT from SSH admin source: $SSH_SOURCE"
        if [[ -n "$CURRENT_SSH_SOURCE" ]]; then
            echo "  Also allow current SSH client $CURRENT_SSH_SOURCE on port $CURRENT_SSH_SERVER_PORT"
        fi
    fi
    echo "  Existing non-Supabase UFW rules: retained"
}

if [[ "$DRY_RUN" == true ]]; then
    show_plan
    echo
    echo "Dry run only: no packages or firewall rules were changed."
    exit 0
fi

[[ "$EUID" -eq 0 ]] || fail "Run this script as root, for example with sudo."
[[ -f /etc/os-release ]] || fail "This script supports Debian or Ubuntu inside the Proxmox CT."
# shellcheck disable=SC1091
. /etc/os-release
case "${ID:-}" in
    debian|ubuntu) ;;
    *) fail "Unsupported operating system '${ID:-unknown}'. Use Debian or Ubuntu." ;;
esac

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ufw

show_plan
read -r -p "Type APPLY to continue: " confirmation
[[ "$confirmation" == "APPLY" ]] || fail "No firewall changes applied."

BACKUP_DIR="/root/ufw-backup-$(date +%Y%m%d-%H%M%S)"
install -d -m 0700 "$BACKUP_DIR"
cp -a /etc/ufw "$BACKUP_DIR/"
if [[ -f /etc/default/ufw ]]; then
    cp -a /etc/default/ufw "$BACKUP_DIR/default-ufw"
fi
printf 'Saved current UFW configuration to %s\n' "$BACKUP_DIR"

# Remove only rules created by a previous run of this script.
mapfile -t MANAGED_RULES < <(
    ufw status numbered 2>/dev/null \
        | awk -F'[][]' '/Supabase managed:/ {gsub(/[[:space:]]/, "", $2); if ($2 ~ /^[0-9]+$/) print $2}' \
        | sort -rn
)
for rule_number in "${MANAGED_RULES[@]}"; do
    ufw --force delete "$rule_number"
done

ufw allow in from "$TUNNEL_SOURCE" to any port 80 proto tcp \
    comment 'Supabase managed: Tunnel origin'
if [[ "$NO_SSH" != true ]]; then
    ufw allow in from "$SSH_SOURCE" to any port "$SSH_PORT" proto tcp \
        comment 'Supabase managed: SSH admin'
    if [[ -n "$CURRENT_SSH_SOURCE" ]]; then
        ufw allow in from "$CURRENT_SSH_SOURCE" to any port "$CURRENT_SSH_SERVER_PORT" proto tcp \
            comment 'Supabase managed: Current SSH session'
    fi
fi

ufw default deny incoming
ufw default allow outgoing
ufw logging low
if ! ufw --force enable; then
    echo "UFW could not be enabled in this LXC. Use the Proxmox CT firewall instead." >&2
    echo "Saved UFW configuration: $BACKUP_DIR" >&2
    exit 1
fi

echo
ufw status numbered
echo
echo "UFW is active. Verify the Tunnel connector can reach this CT on TCP 80."
echo "This does not configure the Proxmox host firewall or filter Docker-published ports."
