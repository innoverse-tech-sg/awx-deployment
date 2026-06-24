# AWX Deployment Script

Production-ready deployment script for [AWX](https://github.com/ansible/awx) 
(the open-source Red Hat Ansible Automation Platform) on k3s Kubernetes.

## What This Script Does

- Deploys a lightweight k3s Kubernetes cluster
- Installs AWX Operator and AWX instance
- Configures SSL via Let's Encrypt (or self-signed for offline)
- Hardens the server (UFW firewall, fail2ban, SSH key-only auth)
- Sets up automated daily backups
- Configures Nginx reverse proxy

## Requirements

- Ubuntu 22.04 LTS
- 4 GB RAM minimum
- 2 vCPUs
- 40 GB disk
- A domain name (for SSL) — or use self-signed for internal/offline deployments

## Quick Start

```bash
# Clone this repo
git clone https://github.com/innoverse/awx-deployment.git
cd awx-deployment

# Edit variables at the top of the script
nano deploy-awx.sh

# Run
sudo bash deploy-awx.sh
