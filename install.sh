#!/bin/bash

set -e

APP_DIR="/opt/supabase"

echo "=== Supabase Self Host Installer ==="

apt update
apt install -y curl openssl git docker-compose-plugin ufw fail2ban

if ! command -v docker >/dev/null; then
    curl -fsSL https://get.docker.com | sh
fi

# ── Firewall (UFW) ─────────────────────────────────────────────────────────────
echo
echo "=== Configuring firewall (UFW) ==="

ufw --force reset

# Always allow SSH first so we don't lock ourselves out
ufw allow 22/tcp comment 'SSH'

# Supabase Studio + API gateway (Kong)
ufw allow 8000/tcp comment 'Supabase Studio / API'

# Deny everything else inbound; allow all outbound
ufw default deny incoming
ufw default allow outgoing

ufw --force enable
echo "UFW enabled. Open ports: 22 (SSH), 8000 (Supabase)"

# ── Fail2ban ───────────────────────────────────────────────────────────────────
echo
echo "=== Configuring Fail2ban ==="

# Write a local jail config (overrides defaults without touching /etc originals)
cat > /etc/fail2ban/jail.local << 'EOF'
[DEFAULT]
# Ban for 1 hour after 5 failures within 10 minutes
bantime  = 3600
findtime = 600
maxretry = 5
backend  = systemd

[sshd]
enabled  = true
port     = ssh
logpath  = %(sshd_log)s

# Protect Supabase Studio/API (Kong) from brute-force HTTP attacks
[supabase-http]
enabled  = true
port     = 8000
filter   = supabase-http
logpath  = /var/log/syslog
maxretry = 20
bantime  = 3600
EOF

# Write the Supabase HTTP filter (catches 401/403 spamming)
cat > /etc/fail2ban/filter.d/supabase-http.conf << 'EOF'
[Definition]
failregex = ^.*"(GET|POST|PUT|DELETE|PATCH).*" (401|403) .*$
ignoreregex =
EOF

systemctl enable fail2ban
systemctl restart fail2ban
echo "Fail2ban enabled. SSH and Supabase HTTP endpoints are protected."

# ── App setup ─────────────────────────────────────────────────────────────────
mkdir -p "$APP_DIR"

cp -r . "$APP_DIR"

cd "$APP_DIR"

if [ ! -f .env ]; then

    echo
    echo "=== Creating .env ==="

    cp .env.example .env

    # Generate required secrets
    POSTGRES_PASSWORD=$(openssl rand -hex 32)
    JWT_SECRET=$(openssl rand -hex 64)
    SECRET_KEY_BASE=$(openssl rand -base64 48)
    REALTIME_DB_ENC_KEY=$(openssl rand -hex 8)
    VAULT_ENC_KEY=$(openssl rand -hex 16)
    PG_META_CRYPTO_KEY=$(openssl rand -base64 24)
    LOGFLARE_PUBLIC_ACCESS_TOKEN=$(openssl rand -base64 24)
    LOGFLARE_PRIVATE_ACCESS_TOKEN=$(openssl rand -base64 24)

    sed -i "s|POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=$POSTGRES_PASSWORD|" .env
    sed -i "s|JWT_SECRET=.*|JWT_SECRET=$JWT_SECRET|" .env
    sed -i "s|SECRET_KEY_BASE=.*|SECRET_KEY_BASE=$SECRET_KEY_BASE|" .env
    sed -i "s|REALTIME_DB_ENC_KEY=.*|REALTIME_DB_ENC_KEY=$REALTIME_DB_ENC_KEY|" .env
    sed -i "s|VAULT_ENC_KEY=.*|VAULT_ENC_KEY=$VAULT_ENC_KEY|" .env
    sed -i "s|PG_META_CRYPTO_KEY=.*|PG_META_CRYPTO_KEY=$PG_META_CRYPTO_KEY|" .env
    sed -i "s|LOGFLARE_PUBLIC_ACCESS_TOKEN=.*|LOGFLARE_PUBLIC_ACCESS_TOKEN=$LOGFLARE_PUBLIC_ACCESS_TOKEN|" .env
    sed -i "s|LOGFLARE_PRIVATE_ACCESS_TOKEN=.*|LOGFLARE_PRIVATE_ACCESS_TOKEN=$LOGFLARE_PRIVATE_ACCESS_TOKEN|" .env

    echo
    echo "================================================="
    echo "IMPORTANT: Save these generated credentials!"
    echo "================================================="
    echo "POSTGRES_PASSWORD=$POSTGRES_PASSWORD"
    echo "JWT_SECRET=$JWT_SECRET"
    echo "================================================="
    echo "Full credentials saved to: $APP_DIR/.env"
    echo "(Never commit .env to git)"
    echo

fi

# ── Start Supabase ─────────────────────────────────────────────────────────────
echo
echo "=== Starting Supabase ==="

docker compose pull
docker compose up -d

echo
echo "================================="
echo "  Supabase is running!"
echo "================================="

IP=$(hostname -I | awk '{print $1}')

echo
echo "  Studio (Dashboard): http://$IP:8000"
echo "  API URL:            http://$IP:8000"
echo
echo "  Dashboard login:"
echo "    Username: supabase"
echo "    Password: see DASHBOARD_PASSWORD in $APP_DIR/.env"
echo
echo "  Security:"
echo "    UFW firewall : enabled (SSH + port 8000 open)"
echo "    Fail2ban     : enabled (SSH + Supabase HTTP protected)"
echo
echo "================================================="
echo "  ACTION REQUIRED:"
echo "  Change DASHBOARD_PASSWORD in $APP_DIR/.env"
echo "  then run:  docker compose up -d"
echo "================================================="
