# Supabase on Proxmox with Cloudflare Tunnel

This guide covers the setup used by this project: Supabase runs in a Debian or Ubuntu Proxmox LXC container, and the Cloudflare Tunnel connector runs on a different server on the same LAN.

## 1. Network layout and ports

Expected request path:

```text
Visitor HTTPS
  -> Cloudflare
  -> Cloudflare Tunnel connector on its own server
  -> Supabase CT LAN address, TCP 80
  -> Caddy in the CT
  -> Kong on 127.0.0.1:8000
  -> Supabase services
```

For this Tunnel setup:

- The Tunnel server must be able to reach the Supabase CT's LAN IP on **TCP 80**.
- Do not forward public internet ports 80 or 443 to the CT. The Tunnel connection is outbound from the Tunnel server.
- Do not expose ports 8000, 8443, 5432, or 6543. Kong and database/pooler ports are loopback-bound.
- The Tunnel service must use `http://<SUPABASE-CT-LAN-IP>:80`. Do **not** use `localhost` when `cloudflared` runs on another server; that points back to the Tunnel server itself.

Use a static DHCP reservation or static address for both servers.

## 2. Create the Proxmox CT

Use Debian 12+ or Ubuntu 22.04+, with systemd as PID 1. For a production-like setup, allow at least 4 CPU cores, 8 GB RAM, and 40 GB disk, with more disk for database and storage growth.

Before installing Docker inside the CT:

1. Enable **Nesting** and **Keyctl** in the CT's **Options → Features**.
2. Enable the CT's **Start at boot** option in Proxmox.
3. Keep the CT on a stable LAN address.
4. Configure CT memory and swap from Proxmox, not by creating a swap file inside the CT.

The Proxmox host firewall is separate from UFW inside the CT. If the Proxmox firewall is active, allow inbound TCP 80 to the CT from the Tunnel server's LAN IP. If you use SSH, allow the SSH port only from your admin network.

## 3. Configure Cloudflare Tunnel

In Cloudflare Zero Trust, add a Public Hostname:

- Hostname: `supabase.netlifegy.com`
- Service type: HTTP
- Origin/service URL: `http://<SUPABASE-CT-LAN-IP>:80`

The Tunnel connector runs on a different server, so `127.0.0.1` or `localhost` is not the Supabase CT. If the connector runs inside a Docker container, test from that container's network: the source address seen by the CT may be the Docker host or bridge address.

The Tunnel connector must remain running. The Cloudflare edge provides HTTPS to visitors; Caddy uses HTTP only on the internal LAN path.

## 4. Install Supabase

From a root shell inside the CT:

```bash
apt-get update
apt-get install -y git
git clone https://github.com/hc172808/supabase-selfhost.git
cd supabase-selfhost
./install.sh supabase.netlifegy.com tunnel
```

The installer:

- Verifies Docker can run inside the CT.
- Starts Postgres first and allows time for first-run migrations.
- Starts and health-checks Supabase, Studio, and Kong.
- Configures Caddy to proxy port 80 to Kong at `127.0.0.1:8000`.
- Enables Docker, Caddy, and the Supabase Compose systemd unit.
- Preserves `/opt/supabase/.env` and persistent database/storage files when rerun.

The installer cannot configure Proxmox, Cloudflare DNS, or the Cloudflare Tunnel connector. It also does not automatically enable UFW: the firewall helper needs your Tunnel server address and an explicit SSH choice.

### Important: self-hosted Studio is one project

The self-hosted Studio and Supabase Cloud use different dashboards. `/project` is a Studio route; Supabase Cloud's `/dashboard` is the management portal for Cloud organizations and projects. The route difference is normal.

Supabase documents that self-hosted Studio represents a single project and does not support adding multiple organizations or projects. This stack labels that one project using `STUDIO_DEFAULT_ORGANIZATION` and `STUDIO_DEFAULT_PROJECT` in `.env`; changing those values changes the displayed names, not the number of projects.

You cannot add your Supabase Cloud projects to this self-hosted Studio. To manage Cloud projects, use [Supabase Cloud Dashboard](https://supabase.com/dashboard/). For multiple independent self-hosted projects, deploy a separate Supabase stack for each one—preferably in separate CTs with distinct hostnames. Do not rerun this install script on the same CT to create another project; this stack uses one Compose project, fixed container names, and one `/opt/supabase` configuration.

## 5. Optional CT firewall (UFW)

The firewall script changes the CT's **default incoming policy to deny**. Run it only if this CT is dedicated to Supabase. It asks for confirmation, backs up its current UFW configuration, and requires an explicit decision about SSH so it does not silently lock out remote access.

Run from the Proxmox console if possible. Replace the example addresses with your real addresses:

```bash
cd /path/to/supabase-selfhost

# Preview the rules first; this does not install UFW or change the firewall:
sudo bash scripts/setup-firewall.sh \
  --confirm-dedicated-ct \
  --tunnel-source <TUNNEL-SERVER-LAN-IP>/32 \
  --ssh-source <ADMIN-LAN-IP>/32 \
  --ssh-port 22 \
  --dry-run

# If you administer by SSH:
sudo bash scripts/setup-firewall.sh \
  --confirm-dedicated-ct \
  --tunnel-source <TUNNEL-SERVER-LAN-IP>/32 \
  --ssh-source <ADMIN-LAN-IP>/32 \
  --ssh-port 22

# If you use only the Proxmox console, use this instead of --ssh-source:
sudo bash scripts/setup-firewall.sh \
  --confirm-dedicated-ct \
  --tunnel-source <TUNNEL-SERVER-LAN-IP>/32 \
  --no-ssh
```

Use the actual source IP that the CT sees for the Tunnel connection. A `/32` limits a rule to one IPv4 address; use the Tunnel server's actual LAN address, not the CT's address. The script allows TCP 80 only from that source and allows SSH only from the admin source you specify.

Afterward, verify the rules:

```bash
sudo ufw status numbered
```

If you lose access, use the Proxmox console and run `sudo ufw disable` to restore CT-level connectivity. This does not change the Proxmox host firewall.

UFW inside an LXC is supplemental. Docker-published ports can bypass a container firewall; this Compose setup keeps its API and database ports on loopback, and the Proxmox firewall should remain the network-level control.

## 6. Optional Fail2ban for SSH

Run the firewall setup first if you want Fail2ban to use UFW for bans. Then:

```bash
sudo bash scripts/setup-fail2ban.sh --ssh-port 22
sudo fail2ban-client status
sudo fail2ban-client status sshd
```

Use your real SSH port if it is not 22. Fail2ban protects SSH login attempts only. If the CT has no active SSH server, the script installs and starts Fail2ban but leaves the SSH jail disabled; rerun it after enabling SSH. It does not protect Supabase Auth/API logins or replace Cloudflare protections.

## 7. Check services and automatic startup

Inside the CT:

```bash
systemctl is-enabled docker caddy supabase-compose
systemctl status supabase-compose.service --no-pager
cd /opt/supabase
docker compose ps -a
```

The installer enables a systemd unit that runs `docker compose up -d` after Docker starts. Also confirm the Proxmox CT itself has **Start at boot** enabled; an enabled service inside a stopped CT cannot start.

## 8. Troubleshooting the errors seen during setup

### Cloudflare shows 502 or 522

From the Tunnel server, test the LAN path:

```bash
curl -v --connect-timeout 5 http://<SUPABASE-CT-LAN-IP>:80/
```

- **Connection refused or timeout:** check the CT IP, Caddy status, Proxmox firewall, and any LAN firewall. Permit the Tunnel server to reach the CT on TCP 80.
- **Caddy's “Congratulations” welcome page:** Caddy is running its packaged default site instead of the Supabase reverse proxy. The Tunnel reaches the CT, but Caddy's configuration has not been applied or reloaded.
- **`502 Bad Gateway` with `Server: Caddy`:** the request reached Caddy, but its upstream Kong service at `127.0.0.1:8000` is unavailable. Check `docker compose ps -a`.

### Kong is `Created`, but not `Up`

If Postgres and Studio are healthy but `supabase-kong` shows `Created`, start Kong and its dependent Edge Functions service:

```bash
cd /opt/supabase
docker compose up -d kong functions
docker compose ps -a
```

Kong must be `Up`/healthy for Caddy to serve the dashboard. If it fails to start, inspect:

```bash
docker compose logs --tail=100 kong
```

### Postgres is still initializing

First startup runs database migrations and can take several minutes. Do not delete `volumes/db/data`, run `docker compose down -v`, or repeatedly interrupt the CT. Inspect:

```bash
cd /opt/supabase
docker compose ps -a
docker compose logs --tail=150 db
```

The installer now starts Postgres before the rest of the stack and waits for its health check.

## 9. Supabase API keys: what to do

For the initial setup, **leave the new-key fields blank**. This project currently uses Supabase's backward-compatible legacy mode:

- `JWT_SECRET`, `ANON_KEY`, and `SERVICE_ROLE_KEY` are generated by the installer and are the active keys.
- `SUPABASE_PUBLISHABLE_KEY`, `SUPABASE_SECRET_KEY`, `JWT_KEYS`, `JWT_JWKS`, `ANON_KEY_ASYMMETRIC`, and `SERVICE_ROLE_KEY_ASYMMETRIC` are optional in this configuration.
- Do not regenerate `JWT_SECRET` on an initialized database. Changing it invalidates or disrupts existing JWT-based sessions and service integrations.
- Never expose `SERVICE_ROLE_KEY`, `SUPABASE_SECRET_KEY`, `JWT_KEYS`, or the `.env` file to a browser or public repository.

The new publishable/secret API keys and ES256 signing keys can be added later as a planned migration. That requires the matching Supabase Compose environment wiring as well as generating keys; merely filling those `.env` fields is not enough. The upstream generator is documented at [Supabase self-hosted auth keys](https://supabase.com/docs/guides/self-hosting/self-hosted-auth-keys). This project does not currently include `utils/add-new-auth-keys.sh`, so do not run that path from this checkout.

## 10. Backups and email

- Daily local PostgreSQL backups are stored under `/opt/supabase/backups/`; copy them off the Proxmox host and test a restore before relying on them.
- Auth email delivery requires a Resend API key and a sender address verified with Resend. Put the key in `/opt/supabase/.env`, keep it private, then run `cd /opt/supabase && docker compose up -d auth`.

