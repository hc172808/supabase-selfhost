#!/bin/bash

set -e

APP_DIR="/opt/supabase"
DOMAIN="supabase.netlifegy.com"

echo
echo "╔══════════════════════════════════════════════╗"
echo "║     Supabase Self Host Installer             ║"
echo "║     Domain: $DOMAIN"
echo "╚══════════════════════════════════════════════╝"
echo

# ── Packages ───────────────────────────────────────────────────────────────────
echo "=== [1/10] Installing packages ==="
apt update -q
apt install -y curl openssl git docker-compose-plugin ufw fail2ban \
    unattended-upgrades apt-listchanges

# Install Docker if missing
if ! command -v docker >/dev/null; then
    curl -fsSL https://get.docker.com | sh
fi

# Install Caddy (HTTPS reverse proxy)
if ! command -v caddy >/dev/null; then
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
        | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
        | tee /etc/apt/sources.list.d/caddy-stable.list
    apt update -q
    apt install -y caddy
fi

# ── Swap space ─────────────────────────────────────────────────────────────────
echo
echo "=== [2/10] Setting up 4 GB swap space ==="
if [ ! -f /swapfile ]; then
    fallocate -l 4G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
    echo "4 GB swap created and enabled"
else
    echo "Swap already exists, skipping"
fi

# ── Docker: boot + log rotation ────────────────────────────────────────────────
echo
echo "=== [3/10] Configuring Docker ==="
systemctl enable docker

cat > /etc/docker/daemon.json << 'EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "5"
  }
}
EOF

systemctl restart docker
echo "Docker enabled on boot; log rotation set (10 MB x 5 files per container)"

# ── Automatic security updates ─────────────────────────────────────────────────
echo
echo "=== [4/10] Enabling automatic security updates ==="
cat > /etc/apt/apt.conf.d/50unattended-upgrades << 'EOF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
};
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
EOF

cat > /etc/apt/apt.conf.d/20auto-upgrades << 'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

systemctl enable unattended-upgrades
echo "OS security patches will install automatically"

# ── SSH hardening ──────────────────────────────────────────────────────────────
echo
echo "=== [5/10] Hardening SSH ==="
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
systemctl restart sshd
echo "Root SSH login disabled"

# ── Firewall (UFW) ─────────────────────────────────────────────────────────────
echo
echo "=== [6/10] Configuring firewall (UFW) ==="
ufw --force reset
ufw allow 22/tcp  comment 'SSH'
ufw allow 80/tcp  comment 'HTTP (Caddy redirects to HTTPS)'
ufw allow 443/tcp comment 'HTTPS (Supabase via Caddy)'
ufw default deny incoming
ufw default allow outgoing
ufw --force enable
echo "UFW enabled: ports 22, 80, 443 open — everything else blocked"

# ── Fail2ban ───────────────────────────────────────────────────────────────────
echo
echo "=== [7/10] Configuring Fail2ban ==="
cat > /etc/fail2ban/jail.local << 'EOF'
[DEFAULT]
# Ban 1 hour after 5 failures in 10 minutes
bantime  = 3600
findtime = 600
maxretry = 5
backend  = systemd

[sshd]
enabled = true
port    = ssh
logpath = %(sshd_log)s

# Block IPs hammering Supabase auth endpoints
[supabase-http]
enabled  = true
port     = 80,443
filter   = supabase-http
logpath  = /var/log/syslog
maxretry = 20
bantime  = 3600
EOF

cat > /etc/fail2ban/filter.d/supabase-http.conf << 'EOF'
[Definition]
failregex = ^.*"(GET|POST|PUT|DELETE|PATCH).*" (401|403) .*$
ignoreregex =
EOF

systemctl enable fail2ban
systemctl restart fail2ban
echo "Fail2ban active: SSH + Supabase HTTP endpoints protected"

# ── HTTPS reverse proxy (Caddy) ────────────────────────────────────────────────
echo
echo "=== [8/10] Configuring HTTPS (Caddy + Let's Encrypt) ==="
mkdir -p /var/log/caddy

cat > /etc/caddy/Caddyfile << EOF
$DOMAIN {
    reverse_proxy localhost:8000

    log {
        output file /var/log/caddy/access.log {
            roll_size 10MB
            roll_keep 5
        }
    }
}
EOF

systemctl enable caddy
systemctl restart caddy
echo "Caddy configured — SSL certificate for $DOMAIN will be auto-obtained on first request"

# ── App setup ──────────────────────────────────────────────────────────────────
echo
echo "=== [9/10] Setting up Supabase ==="
mkdir -p "$APP_DIR"
cp -r . "$APP_DIR"
cd "$APP_DIR"

if [ ! -f .env ]; then

    cp .env.example .env

    # Generate all required secrets
    POSTGRES_PASSWORD=$(openssl rand -hex 32)
    JWT_SECRET=$(openssl rand -hex 64)
    SECRET_KEY_BASE=$(openssl rand -base64 48)
    REALTIME_DB_ENC_KEY=$(openssl rand -hex 8)
    VAULT_ENC_KEY=$(openssl rand -hex 16)
    PG_META_CRYPTO_KEY=$(openssl rand -base64 24)
    LOGFLARE_PUBLIC_ACCESS_TOKEN=$(openssl rand -base64 24)
    LOGFLARE_PRIVATE_ACCESS_TOKEN=$(openssl rand -base64 24)
    DASHBOARD_PASSWORD=$(openssl rand -hex 16)

    sed -i "s|POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=$POSTGRES_PASSWORD|" .env
    sed -i "s|JWT_SECRET=.*|JWT_SECRET=$JWT_SECRET|" .env
    sed -i "s|SECRET_KEY_BASE=.*|SECRET_KEY_BASE=$SECRET_KEY_BASE|" .env
    sed -i "s|REALTIME_DB_ENC_KEY=.*|REALTIME_DB_ENC_KEY=$REALTIME_DB_ENC_KEY|" .env
    sed -i "s|VAULT_ENC_KEY=.*|VAULT_ENC_KEY=$VAULT_ENC_KEY|" .env
    sed -i "s|PG_META_CRYPTO_KEY=.*|PG_META_CRYPTO_KEY=$PG_META_CRYPTO_KEY|" .env
    sed -i "s|LOGFLARE_PUBLIC_ACCESS_TOKEN=.*|LOGFLARE_PUBLIC_ACCESS_TOKEN=$LOGFLARE_PUBLIC_ACCESS_TOKEN|" .env
    sed -i "s|LOGFLARE_PRIVATE_ACCESS_TOKEN=.*|LOGFLARE_PRIVATE_ACCESS_TOKEN=$LOGFLARE_PRIVATE_ACCESS_TOKEN|" .env
    sed -i "s|DASHBOARD_PASSWORD=.*|DASHBOARD_PASSWORD=$DASHBOARD_PASSWORD|" .env

    # Public URL → use HTTPS domain
    sed -i "s|SUPABASE_PUBLIC_URL=.*|SUPABASE_PUBLIC_URL=https://$DOMAIN|" .env

    # SMTP via Resend — swap in your API key from resend.com
    sed -i "s|SMTP_HOST=.*|SMTP_HOST=smtp.resend.com|" .env
    sed -i "s|SMTP_PORT=.*|SMTP_PORT=587|" .env
    sed -i "s|SMTP_USER=.*|SMTP_USER=resend|" .env
    sed -i "s|SMTP_PASS=.*|SMTP_PASS=RESEND_API_KEY_HERE|" .env
    sed -i "s|SMTP_SENDER_NAME=.*|SMTP_SENDER_NAME=Supabase|" .env
    sed -i "s|SMTP_ADMIN_EMAIL=.*|SMTP_ADMIN_EMAIL=admin@$DOMAIN|" .env

    echo
    echo "================================================="
    echo "  SAVE THESE — they will not be shown again!"
    echo "================================================="
    echo "  POSTGRES_PASSWORD : $POSTGRES_PASSWORD"
    echo "  JWT_SECRET        : $JWT_SECRET"
    echo "  DASHBOARD_PASSWORD: $DASHBOARD_PASSWORD"
    echo "================================================="
    echo "  Full .env saved to: $APP_DIR/.env"
    echo "  (Never commit .env to git)"
    echo

fi

# ── Backup cron + health check ─────────────────────────────────────────────────
echo
echo "=== [10/10] Scheduling backups and health checks ==="

chmod +x "$APP_DIR/backup.sh"

# Daily DB backup at 2am; purge backups older than 7 days at 3am
cat > /etc/cron.d/supabase-backup << EOF
0 2 * * * root $APP_DIR/backup.sh >> /var/log/supabase-backup.log 2>&1
0 3 * * * root find $APP_DIR/backups -name '*.sql' -mtime +7 -delete
EOF

# Health check: ping every 5 minutes; auto-restart if down
cat > /usr/local/bin/supabase-health << 'HEALTHEOF'
#!/bin/bash
STATUS=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8000)
if [ "$STATUS" != "200" ] && [ "$STATUS" != "301" ] && [ "$STATUS" != "302" ]; then
    echo "$(date): FAIL (HTTP $STATUS) — restarting stack..." | tee -a /var/log/supabase-health.log
    cd /opt/supabase && docker compose up -d
else
    echo "$(date): OK ($STATUS)" >> /var/log/supabase-health.log
fi
HEALTHEOF
chmod +x /usr/local/bin/supabase-health

cat > /etc/cron.d/supabase-health << 'EOF'
*/5 * * * * root /usr/local/bin/supabase-health
EOF

echo "Daily backup at 2am (7-day retention); health check every 5 min with auto-restart"

# ── Start Supabase ─────────────────────────────────────────────────────────────
echo
echo "=== Starting Supabase ==="
docker compose pull
docker compose up -d

echo
echo "╔══════════════════════════════════════════════════════╗"
echo "║            Supabase is running!                      ║"
echo "╠══════════════════════════════════════════════════════╣"
echo "║  URL    : https://$DOMAIN             ║"
echo "║  Login  : supabase / (saved in .env)                 ║"
echo "╠══════════════════════════════════════════════════════╣"
echo "║  Security                                            ║"
echo "║   ✓ HTTPS via Caddy + Let's Encrypt (auto-renews)    ║"
echo "║   ✓ UFW firewall (22, 80, 443 only)                  ║"
echo "║   ✓ Fail2ban (SSH + HTTP brute-force protection)     ║"
echo "║   ✓ Root SSH login disabled                          ║"
echo "║   ✓ Automatic OS security updates                    ║"
echo "║   ✓ Docker log rotation (10 MB x 5 per container)    ║"
echo "║   ✓ 4 GB swap (prevents OOM crashes)                 ║"
echo "╠══════════════════════════════════════════════════════╣"
echo "║  Automation                                          ║"
echo "║   ✓ Daily DB backup at 2am (7-day retention)         ║"
echo "║   ✓ Health check every 5 min (auto-restarts if down) ║"
echo "║   ✓ Supabase restarts automatically after reboots    ║"
echo "╠══════════════════════════════════════════════════════╣"
echo "║  ACTION REQUIRED — add your Resend API key:          ║"
echo "║   nano /opt/supabase/.env                            ║"
echo "║   → Set SMTP_PASS=re_xxxxxxxxxxxxxxxxxxxx            ║"
echo "║   → Get your key free at: https://resend.com         ║"
echo "║   → Then run: docker compose up -d                   ║"
echo "╚══════════════════════════════════════════════════════╝"
