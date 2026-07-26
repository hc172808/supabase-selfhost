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

    echo "Creating .env from .env.example"

    cp .env.example .env

    # Generate required secrets
    POSTGRES_PASSWORD=$(openssl rand -hex 32)
    JWT_SECRET=$(openssl rand -hex 64)
    SECRET_KEY_BASE=$(openssl rand -base64 48)
    REALTIME_DB_ENC_KEY=$(openssl rand -hex 8)
    VAULT_ENC_KEY=$(openssl rand -hex 16)
    PG_META_CRYPTO_KEY=$(openssl rand -base64 24)
    LOGFLARE_PUBLIC_ACCESS_TOKEN=$(openssl rand -base64 24)
    LOGFLARE_PRIVATE_ACCESS_TOKEN=$(openssl rand -base64 24)

    sed -i "s|POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=$POSTGRES_PASSWORD|" .env
    sed -i "s|JWT_SECRET=.*|JWT_SECRET=$JWT_SECRET|" .env
    sed -i "s|SECRET_KEY_BASE=.*|SECRET_KEY_BASE=$SECRET_KEY_BASE|" .env
    sed -i "s|REALTIME_DB_ENC_KEY=.*|REALTIME_DB_ENC_KEY=$REALTIME_DB_ENC_KEY|" .env
    sed -i "s|VAULT_ENC_KEY=.*|VAULT_ENC_KEY=$VAULT_ENC_KEY|" .env
    sed -i "s|PG_META_CRYPTO_KEY=.*|PG_META_CRYPTO_KEY=$PG_META_CRYPTO_KEY|" .env
    sed -i "s|LOGFLARE_PUBLIC_ACCESS_TOKEN=.*|LOGFLARE_PUBLIC_ACCESS_TOKEN=$LOGFLARE_PUBLIC_ACCESS_TOKEN|" .env
    sed -i "s|LOGFLARE_PRIVATE_ACCESS_TOKEN=.*|LOGFLARE_PRIVATE_ACCESS_TOKEN=$LOGFLARE_PRIVATE_ACCESS_TOKEN|" .env

    echo
    echo "================================================="
    echo "IMPORTANT: Save these generated credentials!"
    echo "================================================="
    echo "POSTGRES_PASSWORD=$POSTGRES_PASSWORD"
    echo "JWT_SECRET=$JWT_SECRET"
    echo "================================================="
    echo "Full credentials saved to: $APP_DIR/.env"
    echo "(Never commit .env to git)"
    echo

fi


echo "Starting Supabase..."

docker compose pull
docker compose up -d


echo
echo "================================="
echo "Supabase Started!"
echo "================================="

IP=$(hostname -I | awk '{print $1}')

echo
echo "Studio (Dashboard):"
echo "  http://$IP:8000"
echo
echo "Default dashboard login:"
echo "  Username: supabase"
echo "  Password: (see DASHBOARD_PASSWORD in $APP_DIR/.env)"
echo
echo "API URL:  http://$IP:8000"
echo "================================================="
echo "Change DASHBOARD_PASSWORD in $APP_DIR/.env"
echo "then run: docker compose up -d"
echo "================================================="
