#!/bin/bash
# EC2 first-boot script (Amazon Linux 2023). Passed as user-data by deploy/aws/setup.sh.
# Output: /var/log/cloud-init-output.log
set -euxo pipefail

# Docker engine + compose plugin (AL2023 ships docker but not the compose plugin).
dnf install -y docker
systemctl enable --now docker
mkdir -p /usr/local/lib/docker/cli-plugins
curl -fsSL "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-$(uname -m)" \
  -o /usr/local/lib/docker/cli-plugins/docker-compose
chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
docker compose version

# 1 GB swap: t3.micro has 1 GB RAM; the JVM + Python service fit, swap is a safety net.
if [ ! -f /swapfile ]; then
  dd if=/dev/zero of=/swapfile bs=1M count=1024
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  echo '/swapfile none swap defaults 0 0' >> /etc/fstab
fi

# App directory: files are synced here from the deploy bucket by the deploy workflow.
mkdir -p /opt/taskmanager
chmod 700 /opt/taskmanager

# The SSM agent is preinstalled on AL2023; it is how setup.sh and GitHub Actions run commands here.
systemctl enable --now amazon-ssm-agent
touch /var/lib/cloud/taskmanager-bootstrap-done
