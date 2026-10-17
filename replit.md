# Supabase Self-Hosted Deployment

## Deployment target

This project deploys the official Supabase Docker Compose stack inside a Debian 12 or Ubuntu 22.04/24.04 Proxmox LXC container. It is not a Replit-hosted service and should not be installed on the Proxmox host.

For a Proxmox CT, enable `nesting=1,keyctl=1` in CT Features, use systemd as PID 1, and provide sufficient CPU, memory, and disk. Configure CT swap and firewall policy on the Proxmox host.

## Deployment

Run as root inside the CT. For this project's Cloudflare Tunnel setup:

```bash
./install.sh supabase.netlifegy.com tunnel
```

`install.sh` installs Docker/Caddy, checks that nested Docker can run a test container, securely creates `.env`, validates Compose, starts and health-checks Supabase, then enables a systemd unit to start the Compose stack after Docker on boot. It also configures scheduled local backups and a health check. Tunnel mode configures Caddy as an HTTP origin; Cloudflare provides visitor HTTPS. It does not configure the Tunnel connector or its Public Hostname.

For Tunnel mode, Caddy listens on port 80 and proxies requests to Kong without requiring a specific origin Host header. Set the Cloudflare Tunnel service to `http://127.0.0.1:80` when `cloudflared` runs on the CT host, or `http://<CT-IP>:80` when it runs elsewhere. No public inbound 80/443 forwarding is needed. The Compose file binds Kong and database/pooler ports to loopback. Direct mode instead uses Caddy for public HTTPS and requires DNS plus inbound TCP 80/443. Do not rely on UFW inside the CT to filter Docker ports.

## Runtime files

- `docker-compose.yml`, `.env.example`, and `volumes/` contain the Supabase stack and its required official config/init files.
- `install.sh` performs the deployment.
- `update.sh` pulls and applies Compose image updates.
- `backup.sh` creates a compressed PostgreSQL custom-format dump.
- `.env` and `volumes/db/data/` contain sensitive/persistent data and must not be committed.

Email sending requires a Resend API key and a verified sender domain in `/opt/supabase/.env`. Backups are local and should be copied off-host for disaster recovery.

The installer cannot create or configure the Proxmox CT, Proxmox firewall, Cloudflare DNS/Tunnel, CT start-at-boot policy, or Resend credentials.
