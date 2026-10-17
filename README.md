# Supabase Self-Hosted on Proxmox

This repository deploys the official Supabase Docker Compose stack **inside a Debian or Ubuntu Proxmox LXC container**. It does not install Supabase on the Proxmox host or configure Proxmox networking/DNS for you.

For the step-by-step Cloudflare Tunnel runbook, separate firewall and Fail2ban scripts, troubleshooting, and API-key guidance, see [SETUP_GUIDE.md](SETUP_GUIDE.md).

## Before running the installer

### Proxmox CT

Create a Debian 12 or Ubuntu 22.04/24.04 CT with:

- 4 CPU cores and at least 8 GB RAM recommended
- At least 40 GB disk, with more space if you expect significant database or file storage
- A stable CT IP address
- **Nesting** and **keyctl** enabled in the CT Features
- A systemd-based template

In the Proxmox UI, stop the CT, open **Options → Features**, enable **Nesting** and **Keyctl**, and start it again. The equivalent CT configuration includes:

```text
features: nesting=1,keyctl=1
```

Do not create a swap file inside the CT. Configure memory and swap limits on the Proxmox host.

### Cloudflare Tunnel

For a Cloudflare Tunnel deployment, the installer configures Caddy as a plain-HTTP origin behind Cloudflare. Cloudflare provides HTTPS to visitors; the origin does not need public inbound ports.

Run the installer with Tunnel mode:

```bash
./install.sh supabase.netlifegy.com tunnel
```

In Cloudflare Zero Trust, create a Public Hostname for `supabase.netlifegy.com` and set its service to:

- `http://127.0.0.1:80` if `cloudflared` runs directly inside this same CT.
- `http://<CT-IP>:80` if the tunnel connector runs on another CT or machine that can reach this CT.

If `cloudflared` is running in a Docker container, use the CT's reachable IP rather than `127.0.0.1`. Keep the tunnel connector running and do not forward ports 80 or 443 from the internet to the CT for this setup. The installer cannot create or configure the Cloudflare Tunnel itself. It saves the selected mode in `/opt/supabase/.env`; rerunning the installer without a mode argument retains that choice.

### Direct origin (without Tunnel)

1. Create a Cloudflare DNS `A` record for `supabase.netlifegy.com` pointing to your public origin. Keep the orange-cloud proxy enabled.
2. Set Cloudflare **SSL/TLS encryption mode** to **Full (strict)**.
3. Configure the Proxmox host firewall and any upstream router to allow TCP 80 and 443 from Cloudflare to the CT. Allow SSH only if you intentionally expose SSH to the CT; the Proxmox console is another option.
4. If restricting origin access to Cloudflare IP ranges, keep those ranges current.

The installer binds Supabase's Kong API ports and database/pooler ports to `127.0.0.1`. Caddy is the only public web listener in the CT and handles HTTPS. Proxmox firewall rules, not UFW inside the CT, control public access. Docker-published ports can bypass a container firewall.

## Deploy

From a shell in the CT as root (or with `sudo`):

```bash
apt-get update
apt-get install -y git
git clone https://github.com/hc172808/supabase-selfhost.git
cd supabase-selfhost
chmod +x install.sh
./install.sh supabase.netlifegy.com tunnel
```

The command above selects Cloudflare Tunnel mode. For a direct public origin instead, run `./install.sh supabase.netlifegy.com direct`. The installer checks that systemd and Docker work, including running a Docker test container. It installs Docker, Caddy, automatic OS security updates, Docker log limits, scheduled database backups, and a health check. It also enables a systemd unit that runs `docker compose up -d` after Docker starts. It generates unique database, JWT, API, encryption, dashboard, and storage credentials and stores them in `/opt/supabase/.env` with restricted permissions.

If Docker cannot run the test container, stop and correct the Proxmox CT features/storage before retrying. Do not switch to a privileged CT as the first troubleshooting step.

## After deployment

Email delivery is not usable until you add a Resend API key:

```bash
nano /opt/supabase/.env
# Replace SMTP_PASS=RESEND_API_KEY_HERE with your Resend SMTP API key.
# Use a sender address on a domain verified with Resend.
cd /opt/supabase
docker compose up -d
```

The dashboard password is randomly generated and stored in `/opt/supabase/.env` as `DASHBOARD_PASSWORD`. Keep that file private. Do not commit it or send it in chat.

## Useful commands inside the CT

```bash
cd /opt/supabase
docker compose ps
docker compose logs -f
docker compose up -d
./update.sh
./backup.sh
```

Daily compressed database backups are stored locally under `/opt/supabase/backups/` and retained for seven days. Copy backups off the Proxmox host for disaster recovery; local backups alone do not protect against host or disk failure.

Enable the CT's **Start at boot** option in Proxmox. The installer can enable Docker inside the CT, but it cannot set Proxmox CT startup policy.

The Compose stack starts automatically after Docker starts inside the CT. To check its systemd unit:

```bash
systemctl status supabase-compose.service
```

## Limitations

- Run this on a Proxmox CT, not in Replit and not on the Proxmox host.
- The script does not create the CT, change Proxmox firewall rules, configure Cloudflare DNS/Tunnel, or provide a Resend API key.
- Direct PostgreSQL/pooler access is loopback-only by default. Use an SSH tunnel for administration rather than exposing database ports publicly.
- Test restores from backups before storing important production data.
