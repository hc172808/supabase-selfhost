#!/usr/bin/env bash

set -Eeuo pipefail

CADDY_USER="caddy"
CADDY_GROUP="caddy"
LOG_DIR="/var/log/caddy"
ACCESS_LOG="$LOG_DIR/access.log"
CADDYFILE="/etc/caddy/Caddyfile"
PREPARE_ONLY=false

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

case "${1:-}" in
    "")
        ;;
    --prepare-only)
        PREPARE_ONLY=true
        ;;
    *)
        fail "Usage: $0 [--prepare-only]"
        ;;
esac

if [[ "${EUID}" -ne 0 ]]; then
    fail "Run this script as root (for example: sudo $0)."
fi

for command_name in caddy systemctl install touch chown chmod; do
    command -v "$command_name" >/dev/null 2>&1 \
        || fail "Required command is missing: $command_name"
done

id "$CADDY_USER" >/dev/null 2>&1 \
    || fail "The Caddy service user '$CADDY_USER' does not exist."
getent group "$CADDY_GROUP" >/dev/null 2>&1 \
    || fail "The Caddy service group '$CADDY_GROUP' does not exist."
[[ -f "$CADDYFILE" ]] || fail "Caddy configuration not found: $CADDYFILE"

if [[ -L "$LOG_DIR" ]]; then
    fail "Refusing to change permissions through a symlink: $LOG_DIR"
fi
if [[ -e "$LOG_DIR" && ! -d "$LOG_DIR" ]]; then
    fail "Caddy log path exists but is not a directory: $LOG_DIR"
fi

install -d -o "$CADDY_USER" -g "$CADDY_GROUP" -m 0750 "$LOG_DIR"

if [[ -L "$ACCESS_LOG" ]]; then
    fail "Refusing to change permissions through a symlink: $ACCESS_LOG"
fi
if [[ -e "$ACCESS_LOG" && ! -f "$ACCESS_LOG" ]]; then
    fail "Caddy access-log path exists but is not a regular file: $ACCESS_LOG"
fi

# touch preserves existing log contents; chown/chmod make it writable by Caddy.
touch "$ACCESS_LOG"
chown "$CADDY_USER:$CADDY_GROUP" "$ACCESS_LOG"
chmod 0640 "$ACCESS_LOG"

caddy validate --config "$CADDYFILE"

if [[ "$PREPARE_ONLY" == true ]]; then
    echo "Caddy access-log permissions are ready; service reload deferred."
    exit 0
fi

if systemctl is-active --quiet caddy; then
    systemctl reload caddy
else
    systemctl enable --now caddy
fi

systemctl is-active --quiet caddy \
    || fail "Caddy is not active. Check: journalctl -u caddy -n 100"
echo "Caddy access-log permissions are ready and the service is active."
