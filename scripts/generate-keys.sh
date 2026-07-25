#!/bin/bash

echo "Generating secrets..."

echo
echo "POSTGRES_PASSWORD:"
openssl rand -hex 32

echo
echo "JWT_SECRET:"
openssl rand -hex 64

echo
echo "Save these values in your .env file"
