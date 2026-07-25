#!/bin/bash

set -e

APP_DIR="/opt/supabase"

echo "=== Supabase Self Host Installer ==="

apt update
apt install -y curl openssl git docker-compose-plugin

if ! command -v docker >/dev/null; then
    curl -fsSL https://get.docker.com | sh
fi

mkdir -p "$APP_DIR"

cp -r . "$APP_DIR"

cd "$APP_DIR"

if [ ! -f .env ]; then

    echo "Creating .env"

    cp .env.example .env

    sed -i "s/POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=$(openssl rand -hex 32)/" .env
    sed -i "s/JWT_SECRET=.*/JWT_SECRET=$(openssl rand -hex 64)/" .env

fi


echo "Starting Supabase..."

docker compose pull
docker compose up -d


echo
echo "================================="
echo "Supabase Started"
echo "================================="

IP=$(hostname -I | awk '{print $1}')

echo "Studio:"
echo "http://$IP:8000"
