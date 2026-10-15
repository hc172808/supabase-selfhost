#!/usr/bin/env bash

set -Eeuo pipefail
cd /opt/supabase

docker compose --env-file .env config --quiet
echo "Pulling configured Supabase images..."
docker compose pull
docker compose up -d
echo "Update complete."
