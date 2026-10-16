#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

APP_DIR="/opt/supabase"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DOMAIN="${1:-${SUPABASE_DOMAIN:-supabase.netlifegy.com}}"

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

trap 'status=$?; printf "ERROR: installer stopped at line %s (exit %s).\n" "$LINENO" "$status" >&2; exit "$status"' ERR

if [[ "${EUID}" -ne 0 ]]; then
    fail "Run this inside the Proxmox container as root: sudo ./install.sh [domain]"
fi

if [[ ! "$DOMAIN" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || [[ "$DOMAIN" != *.* ]]; then
    fail "Invalid domain '$DOMAIN'. Pass a hostname such as supabase.example.com."
fi

for required in docker-compose.yml .env.example backup.sh volumes/api/kong.yml \
    volumes/api/kong-entrypoint.sh volumes/db/jwt.sql volumes/db/roles.sql \
    volumes/db/realtime.sql volumes/db/webhooks.sql volumes/db/_supabase.sql \
    volumes/db/logs.sql volumes/db/pooler.sql volumes/pooler/pooler.exs \
    volumes/functions/main/index.ts volumes/logs/vector.yml; do
    [[ -f "$SCRIPT_DIR/$required" ]] || fail "Required project file is missing: $required"
done

if [[ ! -f /etc/os-release ]]; then
    fail "This installer requires Debian 12+ or Ubuntu 22.04+."
fi
# shellcheck disable=SC1091
. /etc/os-release
case "${ID:-}" in
    debian|ubuntu) ;;
    *) fail "Unsupported operating system '${ID:-unknown}'. Use Debian or Ubuntu in the Proxmox CT." ;;
esac
if [[ "$ID" == "debian" ]] && ! dpkg --compare-versions "${VERSION_ID:-0}" ge 12; then
    fail "Debian 12 or newer is required."
fi
if [[ "$ID" == "ubuntu" ]] && ! dpkg --compare-versions "${VERSION_ID:-0}" ge 22.04; then
    fail "Ubuntu 22.04 or newer is required."
fi

if ! command -v systemctl >/dev/null 2>&1 ||
    [[ "$(ps -p 1 -o comm= | tr -d ' ')" != "systemd" ]]; then
    fail "The container must run systemd as PID 1. Recreate it from a standard Debian/Ubuntu Proxmox CT template."
fi

VIRT="$(systemd-detect-virt --container 2>/dev/null || true)"
if [[ "$VIRT" == "lxc" ]]; then
    echo "Detected LXC. In Proxmox, enable nesting and keyctl for this CT before deploying."
    echo "Docker must pass the hello-world container test below; if not, fix CT features/storage first."
fi

echo
echo "Supabase deployment inside this Linux container"
echo "Domain: $DOMAIN"
echo "Target: $APP_DIR"
echo
echo "Note: this cannot configure the Proxmox host, Cloudflare DNS, or host firewall."

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl gnupg openssl python3 rsync cron \
    unattended-upgrades apt-listchanges

install -m 0755 -d /etc/apt/keyrings

add_docker_repository() {
    [[ -n "${VERSION_CODENAME:-}" ]] || fail "Could not determine the OS codename from /etc/os-release."
    curl -fsSL "https://download.docker.com/linux/${ID}/gpg" \
        -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/%s %s stable\n' \
        "$(dpkg --print-architecture)" "$ID" "$VERSION_CODENAME" \
        > /etc/apt/sources.list.d/docker.list
    chmod 0644 /etc/apt/sources.list.d/docker.list
    apt-get update
}

if ! command -v docker >/dev/null 2>&1; then
    add_docker_repository
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
elif ! docker compose version >/dev/null 2>&1; then
    add_docker_repository
    apt-get install -y docker-compose-plugin
fi

if ! command -v caddy >/dev/null 2>&1; then
    curl -fsSL 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
        | gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    chmod 0644 /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -fsSL 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
        > /etc/apt/sources.list.d/caddy-stable.list
    chmod 0644 /etc/apt/sources.list.d/caddy-stable.list
    apt-get update
    apt-get install -y caddy
fi

command -v docker >/dev/null 2>&1 || fail "Docker Engine installation did not provide the docker command."
docker compose version >/dev/null 2>&1 || fail "Docker Compose plugin is missing."

systemctl enable --now docker
if ! docker info >/dev/null 2>&1; then
    fail "Docker daemon did not start. Check Proxmox CT features (nesting=1,keyctl=1), then run: journalctl -u docker -n 100"
fi

echo "Checking Docker works inside this CT..."
if ! docker run --rm hello-world; then
    fail "Docker could not run a test container. Check Proxmox nesting/keyctl features and the CT's storage/overlay support."
fi

# Merge log rotation settings without discarding unrelated Docker daemon options.
install -d -m 0755 /etc/docker
DOCKER_CONFIG_CHANGED="$(
python3 - <<'PY'
import json
import os
from pathlib import Path
import tempfile

path = Path("/etc/docker/daemon.json")
original = path.read_text() if path.exists() else "{}\n"
try:
    config = json.loads(original)
except json.JSONDecodeError as exc:
    raise SystemExit(f"Invalid {path}: {exc}. Fix it before deploying.")

driver = config.get("log-driver", "json-file")
if driver == "json-file":
    config["log-driver"] = "json-file"
    options = config.get("log-opts")
    if not isinstance(options, dict):
        options = {}
        config["log-opts"] = options
    options.update({"max-size": "10m", "max-file": "5"})

updated = json.dumps(config, indent=2) + "\n"
if updated == original:
    print("unchanged")
else:
    fd, temp_name = tempfile.mkstemp(dir=str(path.parent), prefix="daemon.json.")
    with os.fdopen(fd, "w") as stream:
        stream.write(updated)
    os.chmod(temp_name, 0o644)
    os.replace(temp_name, path)
    print("changed")
PY
)"
if [[ "$DOCKER_CONFIG_CHANGED" == "changed" ]]; then
    systemctl restart docker
    systemctl is-active --quiet docker || fail "Docker did not restart after applying log rotation settings."
fi
if docker info --format '{{.LoggingDriver}}' | grep -qx 'json-file'; then
    echo "Docker log rotation configured (10 MB x 5 files for json-file logging)."
else
    echo "Existing Docker logging driver retained; daemon log rotation was not changed."
fi

# A Proxmox CT does not own its own swap allocation or host firewall.
# Set CT memory/swap and network filtering in Proxmox instead.

# Configure unattended security updates inside the CT.
cat > /etc/apt/apt.conf.d/50unattended-upgrades <<'EOF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
};
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
EOF
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
systemctl enable --now unattended-upgrades

# Make deployment safe to rerun from a checkout without copying Git history,
# secrets, or persistent database/storage data over the live installation.
install -d -m 0755 "$APP_DIR"
if [[ "$SCRIPT_DIR" != "$APP_DIR" ]]; then
    rsync -a \
        --exclude='.git/' \
        --exclude='.local/' \
        --exclude='.agents/' \
        --exclude='.cache/' \
        --exclude='.replit' \
        --exclude='replit.md' \
        --exclude='.env' \
        --exclude='backups/***' \
        --exclude='volumes/db/data/***' \
        --exclude='volumes/storage/***' \
        "$SCRIPT_DIR/" "$APP_DIR/"
fi

cd "$APP_DIR"
mkdir -p backups volumes/db/data volumes/storage
chmod 0700 backups

set_env() {
    local key="$1"
    local value="$2"
    if grep -q "^${key}=" .env; then
        sed -i "s|^${key}=.*|${key}=${value}|" .env
    else
        printf '%s=%s\n' "$key" "$value" >> .env
    fi
}

if [[ ! -f .env ]]; then
    echo "Creating protected environment file and generating unique secrets..."
    cp .env.example .env
    chmod 0600 .env

    POSTGRES_PASSWORD="$(openssl rand -hex 32)"
    JWT_SECRET="$(openssl rand -hex 64)"
    SECRET_KEY_BASE="$(openssl rand -base64 48)"
    REALTIME_DB_ENC_KEY="$(openssl rand -hex 8)"
    VAULT_ENC_KEY="$(openssl rand -hex 16)"
    PG_META_CRYPTO_KEY="$(openssl rand -base64 24)"
    LOGFLARE_PUBLIC_ACCESS_TOKEN="$(openssl rand -base64 24)"
    LOGFLARE_PRIVATE_ACCESS_TOKEN="$(openssl rand -base64 24)"
    DASHBOARD_PASSWORD="$(openssl rand -hex 16)"
    S3_PROTOCOL_ACCESS_KEY_ID="$(openssl rand -hex 16)"
    S3_PROTOCOL_ACCESS_KEY_SECRET="$(openssl rand -hex 32)"

    base64url() {
        openssl base64 -A | tr '+/' '-_' | tr -d '='
    }
    make_jwt() {
        local role="$1" now header payload signature
        now="$(date +%s)"
        header="$(printf '%s' '{"alg":"HS256","typ":"JWT"}' | base64url)"
        payload="$(printf '{"role":"%s","iss":"supabase","iat":%s,"exp":%s}' \
            "$role" "$now" "$((now + 315360000))" | base64url)"
        signature="$(printf '%s.%s' "$header" "$payload" \
            | openssl dgst -sha256 -hmac "$JWT_SECRET" -binary | base64url)"
        printf '%s.%s.%s' "$header" "$payload" "$signature"
    }
    ANON_KEY="$(make_jwt anon)"
    SERVICE_ROLE_KEY="$(make_jwt service_role)"

    set_env POSTGRES_PASSWORD "$POSTGRES_PASSWORD"
    set_env JWT_SECRET "$JWT_SECRET"
    set_env ANON_KEY "$ANON_KEY"
    set_env SERVICE_ROLE_KEY "$SERVICE_ROLE_KEY"
    set_env SECRET_KEY_BASE "$SECRET_KEY_BASE"
    set_env REALTIME_DB_ENC_KEY "$REALTIME_DB_ENC_KEY"
    set_env VAULT_ENC_KEY "$VAULT_ENC_KEY"
    set_env PG_META_CRYPTO_KEY "$PG_META_CRYPTO_KEY"
    set_env LOGFLARE_PUBLIC_ACCESS_TOKEN "$LOGFLARE_PUBLIC_ACCESS_TOKEN"
    set_env LOGFLARE_PRIVATE_ACCESS_TOKEN "$LOGFLARE_PRIVATE_ACCESS_TOKEN"
    set_env DASHBOARD_PASSWORD "$DASHBOARD_PASSWORD"
    set_env S3_PROTOCOL_ACCESS_KEY_ID "$S3_PROTOCOL_ACCESS_KEY_ID"
    set_env S3_PROTOCOL_ACCESS_KEY_SECRET "$S3_PROTOCOL_ACCESS_KEY_SECRET"
    set_env POOLER_TENANT_ID "supabase"
    set_env SMTP_HOST "smtp.resend.com"
    set_env SMTP_PORT "587"
    set_env SMTP_USER "resend"
    set_env SMTP_PASS "RESEND_API_KEY_HERE"
    set_env SMTP_SENDER_NAME "Supabase"
    set_env SMTP_ADMIN_EMAIL "noreply@$DOMAIN"
fi

# If an older/example .env is being reused, replace known public demo credentials
# and apply Resend defaults only where the sample values are still present.
if grep -q '^S3_PROTOCOL_ACCESS_KEY_ID=625729a08b95bf1b7ff351a663f3a23c$' .env; then
    set_env S3_PROTOCOL_ACCESS_KEY_ID "$(openssl rand -hex 16)"
fi
if grep -q '^S3_PROTOCOL_ACCESS_KEY_SECRET=850181e4652dd023b7a98c58ae0d2d34bd487ee0cc3254aed6eda37307425907$' .env; then
    set_env S3_PROTOCOL_ACCESS_KEY_SECRET "$(openssl rand -hex 32)"
fi
if grep -q '^DASHBOARD_PASSWORD=this_password_is_insecure_and_should_be_updated$' .env; then
    set_env DASHBOARD_PASSWORD "$(openssl rand -hex 16)"
fi
if grep -q '^POOLER_TENANT_ID=your-tenant-id$' .env; then
    set_env POOLER_TENANT_ID "supabase"
fi
if grep -q '^SMTP_HOST=supabase-mail$' .env; then
    set_env SMTP_HOST "smtp.resend.com"
    set_env SMTP_PORT "587"
    set_env SMTP_USER "resend"
    set_env SMTP_PASS "RESEND_API_KEY_HERE"
    set_env SMTP_SENDER_NAME "Supabase"
fi
if grep -q '^SMTP_ADMIN_EMAIL=admin@example.com$' .env; then
    set_env SMTP_ADMIN_EMAIL "noreply@$DOMAIN"
fi
if grep -q '^SMTP_PASS=fake_mail_password$' .env; then
    set_env SMTP_PASS "RESEND_API_KEY_HERE"
fi

# Refuse to launch an existing install that still contains template-only
# database/encryption credentials. Rotating these blindly can break an
# initialized database, so require a deliberate, backed-up repair instead.
if grep -Eq \
    '^POSTGRES_PASSWORD=your-super-secret-and-long-postgres-password$|^JWT_SECRET=your-super-secret-jwt-token-with-at-least-32-characters-long$|^SECRET_KEY_BASE=UpNVntn3cDxHJpq99YMc1T1AQgQpc8kfYTuRgBiYa15BLrx8etQoXz3gZv1/u2oq$|^REALTIME_DB_ENC_KEY=supabaserealtime$|^VAULT_ENC_KEY=your-32-character-encryption-key$|^PG_META_CRYPTO_KEY=your-encryption-key-32-chars-min$|^LOGFLARE_PUBLIC_ACCESS_TOKEN=your-super-secret-and-long-logflare-key-public$|^LOGFLARE_PRIVATE_ACCESS_TOKEN=your-super-secret-and-long-logflare-key-private$' \
    .env; then
    fail "The existing .env contains template credentials. Back up the database and configure unique secrets before deploying; do not delete .env or database data blindly."
fi

if grep -Fxq "$(grep '^ANON_KEY=' .env.example)" .env ||
    grep -Fxq "$(grep '^SERVICE_ROLE_KEY=' .env.example)" .env; then
    jwt_secret="$(grep '^JWT_SECRET=' .env | head -n1 | cut -d= -f2-)"
    if [[ -z "$jwt_secret" || "$jwt_secret" == your-* ]]; then
        fail "The existing .env has demo API keys but no unique JWT_SECRET. Back it up and configure unique secrets before deploying."
    fi
    base64url() {
        openssl base64 -A | tr '+/' '-_' | tr -d '='
    }
    make_jwt() {
        local role="$1" now header payload signature
        now="$(date +%s)"
        header="$(printf '%s' '{"alg":"HS256","typ":"JWT"}' | base64url)"
        payload="$(printf '{"role":"%s","iss":"supabase","iat":%s,"exp":%s}' \
            "$role" "$now" "$((now + 315360000))" | base64url)"
        signature="$(printf '%s.%s' "$header" "$payload" \
            | openssl dgst -sha256 -hmac "$jwt_secret" -binary | base64url)"
        printf '%s.%s.%s' "$header" "$payload" "$signature"
    }
    set_env ANON_KEY "$(make_jwt anon)"
    set_env SERVICE_ROLE_KEY "$(make_jwt service_role)"
fi

# Keep public callbacks and auth redirects aligned with the requested hostname.
set_env SUPABASE_PUBLIC_URL "https://$DOMAIN"
set_env API_EXTERNAL_URL "https://$DOMAIN/auth/v1"
set_env SITE_URL "https://$DOMAIN"
set_env KONG_HTTP_PORT "8000"
set_env KONG_HTTPS_PORT "8443"
chmod 0600 .env

# Use Caddy for public TLS; Docker's Kong and database ports stay on loopback.
cat > /etc/caddy/Caddyfile <<EOF
$DOMAIN {
    reverse_proxy 127.0.0.1:8000
    log {
        output file /var/log/caddy/access.log {
            roll_size 10MB
            roll_keep 5
        }
    }
}
EOF
chmod 0644 /etc/caddy/Caddyfile
install -d -o caddy -g caddy -m 0750 /var/log/caddy
caddy validate --config /etc/caddy/Caddyfile
systemctl enable caddy

echo "Validating resolved Supabase Compose configuration..."
docker compose --env-file .env config --quiet

echo "Pulling Supabase images and starting the stack..."
if ! docker compose pull; then
    fail "Image download failed. Check outbound internet/DNS from the CT and try again."
fi

# On a new deployment, Postgres runs all initialization migrations before
# accepting connections. Start it separately so the remaining services cannot
# race its first-boot health checks.
echo "Starting PostgreSQL first and allowing up to 15 minutes for initialization..."
if ! docker compose up -d db; then
    docker compose ps db >&2 || true
    docker compose logs --tail=200 db >&2 || true
    fail "PostgreSQL could not start. Review its logs above; do not delete volumes/db/data."
fi
db_healthy=false
for attempt in $(seq 1 180); do
    db_status="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' supabase-db 2>/dev/null || true)"
    if [[ "$db_status" == "healthy" ]]; then
        db_healthy=true
        break
    fi
    if (( attempt % 6 == 0 )); then
        echo "PostgreSQL is still initializing (status: ${db_status:-not created}; waited $((attempt * 5)) seconds)..."
    fi
    sleep 5
done
if [[ "$db_healthy" != true ]]; then
    docker compose ps db >&2 || true
    docker compose logs --tail=200 db >&2 || true
    fail "PostgreSQL did not become healthy within 15 minutes. Review the database logs above; do not delete volumes/db/data."
fi

echo "PostgreSQL is healthy; starting the remaining Supabase services..."
if ! docker compose up -d; then
    docker compose ps >&2 || true
    docker compose logs --tail=200 db studio kong >&2 || true
    fail "Docker Compose could not start the Supabase services. Review the errors above and check the Proxmox CT settings."
fi

echo "Waiting for PostgreSQL, Studio, and Kong health checks (up to 15 minutes)..."
healthy=false
for attempt in $(seq 1 180); do
    db_status="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' supabase-db 2>/dev/null || true)"
    kong_status="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' supabase-kong 2>/dev/null || true)"
    studio_status="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' supabase-studio 2>/dev/null || true)"
    if [[ "$db_status" == "healthy" && "$kong_status" == "healthy" && "$studio_status" == "healthy" ]]; then
        healthy=true
        break
    fi
    if (( attempt % 6 == 0 )); then
        echo "Waiting for health checks (db: ${db_status:-unknown}, studio: ${studio_status:-unknown}, kong: ${kong_status:-unknown}; waited $((attempt * 5)) seconds)..."
    fi
    sleep 5
done
if [[ "$healthy" != true ]]; then
    docker compose ps >&2 || true
    docker compose logs --tail=200 db studio kong >&2 || true
    fail "Supabase database, Studio, and API gateway did not all become healthy within 15 minutes. Review the logs above."
fi

systemctl restart caddy
systemctl is-active --quiet caddy || fail "Caddy failed to start. Check: journalctl -u caddy -n 100"

https_ready=false
if getent ahosts "$DOMAIN" >/dev/null 2>&1; then
    echo "Checking local HTTPS certificate for $DOMAIN (up to 60 seconds)..."
    for _ in $(seq 1 12); do
        https_status="$(curl --silent --show-error --max-time 5 \
            --resolve "$DOMAIN:443:127.0.0.1" \
            --output /dev/null --write-out '%{http_code}' "https://$DOMAIN/" 2>/dev/null || true)"
        if [[ "$https_status" =~ ^[2-5][0-9][0-9]$ ]]; then
            https_ready=true
            break
        fi
        sleep 5
    done
else
    echo "WARNING: DNS for $DOMAIN does not resolve yet; Caddy cannot obtain its HTTPS certificate."
fi
if [[ "$https_ready" != true ]]; then
    echo "WARNING: HTTPS certificate is not verified yet. Check Cloudflare DNS, Proxmox/router TCP 80/443 rules, and: journalctl -u caddy"
fi

# Cron is not installed in many minimal Proxmox CT templates.
systemctl enable --now cron

chmod 0755 backup.sh update.sh
cat > /etc/cron.d/supabase-backup <<EOF
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
0 2 * * * root $APP_DIR/backup.sh 2>&1 | logger -t supabase-backup
0 3 * * * root find $APP_DIR/backups -type f -name '*.dump' -mtime +7 -delete
EOF
chmod 0644 /etc/cron.d/supabase-backup

cat > /usr/local/bin/supabase-health <<'HEALTHEOF'
#!/usr/bin/env bash
set -u
cd /opt/supabase || exit 1
unhealthy=0
for container in supabase-db supabase-kong; do
    state="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$container" 2>/dev/null || true)"
    case "$state" in
        healthy|starting|running) ;;
        *) unhealthy=1; break ;;
    esac
done
if (( unhealthy )); then
    logger -t supabase-health "Supabase database/API unhealthy; restarting Compose services"
    docker compose restart
fi
if ! systemctl is-active --quiet caddy; then
    logger -t supabase-health "Caddy is not active; restarting Caddy"
    systemctl restart caddy
fi
HEALTHEOF
chmod 0755 /usr/local/bin/supabase-health
cat > /etc/cron.d/supabase-health <<'EOF'
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
*/5 * * * * root /usr/local/bin/supabase-health
EOF
chmod 0644 /etc/cron.d/supabase-health

echo
echo "Deployment completed inside the Proxmox CT."
echo "Supabase URL : https://$DOMAIN"
if [[ "$https_ready" == true ]]; then
    echo "HTTPS        : verified locally with Caddy's certificate"
else
    echo "HTTPS        : pending DNS/network/certificate validation"
fi
echo "Credentials  : stored in $APP_DIR/.env (mode 600)"
if grep -q '^SMTP_PASS=RESEND_API_KEY_HERE$' .env; then
    echo "NEXT         : Set SMTP_PASS in $APP_DIR/.env to your Resend API key, then run:"
    echo "               cd $APP_DIR && docker compose up -d"
fi
echo
echo "Before opening the site, make sure:"
echo "  - Cloudflare DNS for $DOMAIN points/proxies to this CT's public origin."
echo "  - Cloudflare SSL/TLS mode is Full (strict)."
echo "  - Proxmox/router firewall permits TCP 80 and 443 to this CT."
echo "  - Proxmox CT has nesting=1,keyctl=1 and starts automatically on boot."
echo "  - Configure CT memory/swap and backups on the Proxmox host."
echo
echo "The installer does not change Proxmox host firewall, CT startup policy, or DNS."
