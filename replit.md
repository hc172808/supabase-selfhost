# Supabase Self-Hosted Installer

## What this is
A collection of shell scripts for self-hosting Supabase on a Linux server using Docker Compose.

## Project structure
- `install.sh` — main installer: installs Docker, copies files to `/opt/supabase`, generates secrets, runs `docker compose up -d`
- `update.sh` — pulls latest images and restarts the stack
- `backup.sh` — dumps the Postgres database to `/opt/supabase/backups/`
- `scripts/generate-keys.sh` — generates random `POSTGRES_PASSWORD` and `JWT_SECRET` values

## Supabase services started by `docker-compose.yml`
| Service | Description |
|---|---|
| Studio | Web dashboard (port 8000) |
| Kong | API gateway |
| Auth (GoTrue) | User authentication |
| REST (PostgREST) | Auto-generated REST API |
| Realtime | Websocket subscriptions |
| Storage | File storage |
| PostgreSQL | Database |
| Meta | DB management API |
| Imgproxy | Image transformations |
| Supavisor | Connection pooler |
| Logflare/Vector | Logging |

## Requirements (to run on a real server)
- Ubuntu 22.04/24.04 or Debian 12
- Docker (installed automatically by `install.sh` if missing)
- 4 CPU cores, 8 GB RAM recommended

## ⚠️ Cannot run on Replit
Replit does not support Docker or Docker Compose. This project must be deployed to a Linux VPS.

## How to run (on a compatible server)
```bash
git clone <this-repo>
cd <repo>
chmod +x install.sh
sudo ./install.sh
```

Supabase Studio will be available at `http://<server-ip>:8000` after install.

## User preferences
