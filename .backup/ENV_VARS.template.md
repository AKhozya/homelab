# Homelab Environment Variables and Secrets Reference
# This is a TEMPLATE - actual values are in .backup/ENV_VARS.md (gitignored)

## Cloudflare
CLOUDFLARE_API_TOKEN=<your-cloudflare-api-token>
CLOUDFLARE_EMAIL=<your-email>
CLOUDFLARE_ZONE=h0melab.work

## Telegram Alerting
TELEGRAM_BOT_TOKEN=<your-telegram-bot-token>
TELEGRAM_CHAT_ID=<your-telegram-chat-id>

## SOPS/Age Encryption
# Age public key: <shown in sops-age secret>
# Private key is stored in .backup/secrets/age.agekey after running backup

## DNS Records
# A records pointing to cluster nodes:
# grafana.h0melab.work -> <control-plane-ip> or <worker-ip>
# am.h0melab.work -> <control-plane-ip> or <worker-ip>

## Node IPs
CONTROL_PLANE_IP=<your-control-plane-ip>
WORKER_NODE_IP=<your-worker-ip>

## Cloudflare Tunnels
# Tunnel credentials are stored in Kubernetes secrets
# Public URLs:
#   - https://linkding.h0melab.work
#   - https://audiobookshelf.h0melab.work

## Grafana
# Admin credentials stored in monitoring/grafana-admin-secret
# Username: admin
# Password: (stored in secret, extract with backup script)

## Firewall Rules (UFW)
# On both nodes:
# sudo ufw allow from <your-subnet>/24
# Example: sudo ufw allow from 192.168.1.0/24

## K3s Installation
# Control plane: curl -sfL https://get.k3s.io | sh -
# Worker: K3S_URL=https://<control-plane-ip>:6443 K3S_TOKEN=<token> curl -sfL https://get.k3s.io | sh -

## Storage
# Using local-path provisioner (built into K3s)
# PVCs are stored in /var/lib/rancher/k3s/storage/ on nodes

## Backup Locations
# Secrets: .backup/secrets/ (created by secrets-backup.sh)
# PV data: /var/lib/rancher/k3s/storage/ on each node
# Recommended: rsync or backup this directory for data persistence

## How to Use
# 1. Copy this template to .backup/ENV_VARS.md
# 2. Fill in your actual values
# 3. Keep .backup/ENV_VARS.md secure and never commit it
