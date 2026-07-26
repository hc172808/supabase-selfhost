# Supabase Self-Hosted Installer

## What this is
A production-ready shell script installer for self-hosting Supabase on a Linux server using Docker Compose. Runs on Ubuntu 22.04/24.04 or Debian 12.

## Files
| File | Purpose |
|---|---|
| `install.sh` | Full installer — run this once on your server |
| `update.sh` | Pull latest Supabase images and restart |
| `backup.sh` | Dump Postgres to `/opt/supabase/backups/` |
| `scripts/generate-keys.sh` | Manually generate secrets |
| `docker-compose.yml` | Full Supabase service stack |
| `.env.example` | All configuration variables with documentation |

## Supabase services (docker-compose.yml)
| Service | Description |
|---|---|
| Studio | Web dashboard (proxied via Caddy → HTTPS) |
| Kong | API gateway |
| Auth (GoTrue) | User authentication + email |
| REST (PostgREST) | Auto-generated REST API from DB schema |
| Realtime | WebSocket subscriptions |
| Storage | File uploads |
| PostgreSQL | Database |
| Meta | DB management API |
| Imgproxy | Image transformations |
| Supavisor | Connection pooler |
| Logflare / Vector | Logging |

## What install.sh sets up automatically

### Security
- **UFW firewall** — only ports 22 (SSH), 80 (HTTP), 443 (HTTPS) open
- **Fail2ban** — bans IPs after repeated SSH or HTTP auth failures
- **Root SSH login disabled**
- **Caddy + Let's Encrypt** — HTTPS for `supabase.netlifegy.com`, auto-renewing
- **Automatic OS security updates** via `unattended-upgrades`

### Reliability
- **4 GB swap space** — prevents OOM crashes on 8 GB servers
- **Docker log rotation** — 10 MB × 5 files per container, prevents disk fill
- **Docker enabled on boot** — stack survives reboots
- **Health check every 5 min** — auto-restarts stack if down (`/usr/local/bin/supabase-health`)

### Automation
- **Daily DB backup at 2am** — stored in `/opt/supabase/backups/`
- **7-day backup retention** — old backups purged automatically

### Configuration
- All secrets auto-generated (Postgres password, JWT, encryption keys, dashboard password)
- SMTP pre-configured for **Resend** — only the API key needs to be added

## Server requirements
- Ubuntu 22.04/24.04 or Debian 12
- 4 CPU cores, 8 GB RAM (installer adds 4 GB swap as buffer)
- Domain `supabase.netlifegy.com` pointing to the server's IP before running

## How to deploy

```bash
git clone <this-repo>
cd <repo>
chmod +x install.sh
sudo ./install.sh
```

## After install — one required step

Add your Resend API key (free at [resend.com](https://resend.com)):

```bash
nano /opt/supabase/.env
# Set: SMTP_PASS=re_xxxxxxxxxxxxxxxxxxxx
docker compose -f /opt/supabase/docker-compose.yml up -d
```

## Useful commands (run on the server as root)

```bash
# View running containers
docker compose -C /opt/supabase ps

# View logs
docker compose -C /opt/supabase logs -f

# Restart stack
docker compose -C /opt/supabase up -d

# Update to latest Supabase version
cd /opt/supabase && ./update.sh

# Manual backup
/opt/supabase/backup.sh

# Check firewall status
ufw status

# Check Fail2ban bans
fail2ban-client status sshd
```

## ⚠️ Cannot run on Replit
Replit does not support Docker. This installer must be run on a Linux VPS.

## User preferences
