#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

APP_DIR="/opt/supabase"
BACKUP_DIR="$APP_DIR/backups"
DATE="$(date +'%Y-%m-%d_%H-%M-%S')"
BACKUP="$BACKUP_DIR/database-$DATE.dump"
TEMP="$BACKUP.tmp"

mkdir -p "$BACKUP_DIR"
chmod 0700 "$BACKUP_DIR"
trap 'rm -f "$TEMP"' EXIT

echo "Creating compressed PostgreSQL custom-format backup..."
docker exec supabase-db pg_dump --username=postgres --dbname=postgres --format=custom > "$TEMP"
test -s "$TEMP"
mv "$TEMP" "$BACKUP"
trap - EXIT

echo "Backup saved: $BACKUP"
