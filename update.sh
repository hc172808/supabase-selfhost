#!/bin/bash

set -e

cd /opt/supabase

echo "Updating Supabase..."

docker compose pull

docker compose up -d

echo "Update complete"
