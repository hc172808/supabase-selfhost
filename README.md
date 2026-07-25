# Supabase Self Hosted

Self-hosted Supabase deployment using Docker Compose.

## Requirements

- Ubuntu 22.04/24.04
- Debian 12
- Docker
- 4 CPU cores
- 8GB RAM recommended

## Install

Clone:

```bash
git clone https://github.com/hc172808/supabase-selfhost.git
cd supabase-selfhost
chmod +x install.sh
./install.sh
Update
./update.sh
Backup
./backup.sh
Security

Never commit:

.env
database volumes
backups

---

After copying these:

```bash
git add .
git commit -m "Add Supabase self host installer"
git push
