#!/bin/bash
# ================================================================
# AWX Production Deployment Script
# For: Ubuntu 22.04 LTS, 4GB RAM minimum
# Maintainer: Innoverse Pte Ltd | hello@innoverse-tech.org
# Description: Deploys AWX (open-source Red Hat AAP) on k3s
#              with SSL, firewall, fail2ban, and automated backups.
# ================================================================

set -euo pipefail

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# Check root
if [ "$EUID" -ne 0 ]; then error "Please run as root"; fi

# Variables — CHANGE THESE
DOMAIN="awx.yourcompany.com"
ADMIN_EMAIL="admin@yourcompany.com"
AWX_ADMIN_PASSWORD=$(openssl rand -base64 32)
PG_PASSWORD=$(openssl rand -base64 32)

log "Starting AWX deployment on $DOMAIN"

# ── System Update & Hardening ──
log "Updating system packages..."
apt update && apt upgrade -y

log "Configuring firewall..."
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable

log "Installing fail2ban..."
apt install fail2ban -y
systemctl enable --now fail2ban

# ── Dependencies ──
log "Installing required packages..."
apt install -y curl wget git nginx certbot python3-certbot-nginx

# ── k3s Installation ──
log "Installing k3s Kubernetes..."
curl -sfL https://get.k3s.io | sh -
sleep 30

mkdir -p /root/.kube
cp /etc/rancher/k3s/k3s.yaml /root/.kube/config
chmod 600 /root/.kube/config

log "Waiting for k3s to be ready..."
kubectl wait --for=condition=ready node --all --timeout=120s

# ── AWX Operator ──
log "Deploying AWX Operator..."
kubectl create namespace awx --dry-run=client -o yaml | kubectl apply -f -
kubectl config set-context --current --namespace=awx

kubectl apply -f https://raw.githubusercontent.com/ansible/awx-operator/devel/deploy/awx-operator.yaml
kubectl wait --for=condition=ready pod -l control-plane=controller-manager --timeout=300s

# ── AWX Secrets ──
log "Creating AWX secrets..."
kubectl create secret generic awx-admin-password \
  --from-literal=password="$AWX_ADMIN_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic awx-postgres-configuration \
  --from-literal=host=awx-postgres-13 \
  --from-literal=port=5432 \
  --from-literal=database=awx \
  --from-literal=username=awx \
  --from-literal=password="$PG_PASSWORD" \
  --from-literal=type=managed \
  --dry-run=client -o yaml | kubectl apply -f -

# ── AWX Instance ──
log "Deploying AWX instance..."
cat <<EOF | kubectl apply -f -
apiVersion: awx.ansible.com/v1beta1
kind: AWX
metadata:
  name: awx
  namespace: awx
spec:
  service_type: ClusterIP
  ingress_type: none
  hostname: $DOMAIN
  replicas: 1
  auto_upgrade: true
  admin_user: admin
  admin_password_secret: awx-admin-password
  postgres_configuration_secret: awx-postgres-configuration
  task_resource_requirements:
    requests:
      cpu: 500m
      memory: 1Gi
    limits:
      cpu: 2000m
      memory: 4Gi
  web_resource_requirements:
    requests:
      cpu: 250m
      memory: 512Mi
    limits:
      cpu: 1000m
      memory: 2Gi
EOF

log "Waiting for AWX to be ready (this takes 5-10 minutes)..."
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=awx --timeout=900s

# ── Nginx Reverse Proxy ──
log "Configuring Nginx reverse proxy..."
AWX_SERVICE_IP=$(kubectl get service awx-service -o jsonpath='{.spec.clusterIP}')

cat <<EOF > /etc/nginx/sites-available/awx
server {
    listen 80;
    server_name $DOMAIN;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name $DOMAIN;

    ssl_certificate     /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;

    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;

    client_max_body_size 200M;

    location / {
        proxy_pass http://$AWX_SERVICE_IP;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 86400;
    }
}
EOF

ln -sf /etc/nginx/sites-available/awx /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl reload nginx

# ── SSL Certificate ──
log "Requesting SSL certificate..."
certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "$ADMIN_EMAIL"

# ── Backup Cron ──
log "Setting up daily backup..."
cat <<'BACKUP' > /usr/local/bin/awx-backup.sh
#!/bin/bash
BACKUP_DIR="/opt/awx-backups"
mkdir -p $BACKUP_DIR
DATE=$(date +%Y%m%d_%H%M%S)
kubectl get secret awx-admin-password -n awx -o jsonpath='{.data.password}' | base64 --decode > $BACKUP_DIR/admin_password_$DATE.txt
kubectl get secret awx-postgres-configuration -n awx -o yaml > $BACKUP_DIR/pg_secret_$DATE.yaml
kubectl get awx awx -n awx -o yaml > $BACKUP_DIR/awx_config_$DATE.yaml
# Keep only last 7 backups
ls -t $BACKUP_DIR/admin_password_* | tail -n +8 | xargs -r rm
ls -t $BACKUP_DIR/pg_secret_* | tail -n +8 | xargs -r rm
ls -t $BACKUP_DIR/awx_config_* | tail -n +8 | xargs -r rm
BACKUP

chmod +x /usr/local/bin/awx-backup.sh
(crontab -l 2>/dev/null; echo "0 2 * * * /usr/local/bin/awx-backup.sh") | crontab -

# ── Summary ──
echo ""
echo "=============================================="
log "DEPLOYMENT COMPLETE"
echo "=============================================="
echo ""
echo "  AWX URL:      https://$DOMAIN"
echo "  Username:     admin"
echo "  Password:     $AWX_ADMIN_PASSWORD"
echo ""
echo "  SAVE THIS PASSWORD. It will not be shown again."
echo "  Backup stored at: /opt/awx-backups/"
echo ""
echo "  Innoverse Pte Ltd"
echo "  hello@innoverse-tech.org"
echo ""
echo "=============================================="