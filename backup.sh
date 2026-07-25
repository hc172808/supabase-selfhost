#!/bin/bash

set -e

BACKUP_DIR="/opt/supabase/backups"

mkdir -p "$BACKUP_DIR"

DATE=$(date +"%Y-%m-%d_%H-%M")

echo "Creating database backup..."

docker exec supabase-db \
pg_dump -U postgres postgres \
> "$BACKUP_DIR/database-$DATE.sql"

echo "Backup saved:"
echo "$BACKUP_DIR/database-$DATE.sql"
