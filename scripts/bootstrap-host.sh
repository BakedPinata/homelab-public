#!/usr/bin/env bash
# Prepare an Ubuntu host for the homelab. Safe to re-run.
# Usage: sudo scripts/bootstrap-host.sh
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "Run with sudo: sudo $0"; exit 1; }
OWNER="${SUDO_USER:?run via sudo from your normal user}"
OWNER_UID=$(id -u "$OWNER"); OWNER_GID=$(id -g "$OWNER")
NAS="//192.168.10.7"
# NAS share name : mount point under /media
SHARES=(Downloads:Downloads Video:Video Docker:docker photos:Photos BACKUPS:Backups)

echo "== Packages"
apt-get update -qq
apt-get install -y -qq docker.io docker-compose-v2 cifs-utils git gh gitleaks yamllint jq curl
usermod -aG docker "$OWNER"
systemctl enable --now docker

echo "== Directories"
install -d -o "$OWNER" -g "$OWNER" /srv/appdata /srv/backups /srv/backups/db

echo "== NAS mounts (/etc/fstab)"
[[ -f /home/$OWNER/.smbcredentials ]] || echo "WARNING: /home/$OWNER/.smbcredentials missing (username=... / password=..., chmod 600)"
cp --update=none /etc/fstab /etc/fstab.pre-homelab
units=()
for s in "${SHARES[@]}"; do
  share="${s%%:*}"; dir="/media/${s##*:}"
  mkdir -p "$dir"
  if ! grep -q "^$NAS/$share[[:space:]]" /etc/fstab; then
    echo "$NAS/$share $dir cifs credentials=/home/$OWNER/.smbcredentials,uid=$OWNER_UID,gid=$OWNER_GID,vers=3.0,_netdev,nofail 0 0" >> /etc/fstab
  elif ! grep "^$NAS/$share[[:space:]]" /etc/fstab | grep -q _netdev; then
    # Don't block boot if the NAS is down
    sed -i "\|^$NAS/$share[[:space:]]|s|vers=3.0|vers=3.0,_netdev,nofail|" /etc/fstab
  fi
  units+=("$(systemd-escape -p --suffix=mount "$dir")")
done
systemctl daemon-reload
mount -a -t cifs || true
for s in "${SHARES[@]}"; do
  dir="/media/${s##*:}"
  mountpoint -q "$dir" || echo "WARNING: $dir is not mounted (check the share name and .smbcredentials)"
done

echo "== Docker starts after the NAS mounts (but still starts if they fail)"
mkdir -p /etc/systemd/system/docker.service.d
cat > /etc/systemd/system/docker.service.d/wait-for-nas.conf <<EOF
[Unit]
Wants=${units[*]}
After=${units[*]}
EOF

echo "== Docker networks stay in 172.16.0.0/12"
# Docker's built-in pool falls back to 192.168.x/20 when 172.x runs out, which swallowed
# the LAN's 192.168.30.x and 40.x device networks (replies went into a bridge).
if [[ ! -f /etc/docker/daemon.json ]]; then
  cat > /etc/docker/daemon.json <<EOF
{
  "default-address-pools": [{ "base": "172.16.0.0/12", "size": 24 }]
}
EOF
  echo "Wrote /etc/docker/daemon.json: run 'systemctl restart docker' to apply"
elif ! grep -q default-address-pools /etc/docker/daemon.json; then
  echo "WARNING: add default-address-pools (172.16.0.0/12, size 24) to /etc/docker/daemon.json by hand"
fi

echo "== IP forwarding (Tailscale subnet router and exit node)"
cat > /etc/sysctl.d/99-tailscale.conf <<EOF
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF
sysctl -q -p /etc/sysctl.d/99-tailscale.conf

echo "== Rotate Traefik's access log (CrowdSec reads it)"
cat > /etc/logrotate.d/homelab-traefik <<EOF
/srv/appdata/traefik/logs/*.log {
  daily
  rotate 14
  compress
  delaycompress
  missingok
  notifempty
  copytruncate
}
EOF

echo "== Nightly DB dumps (scripts/backup-db.sh, 02:00)"
REPO=$(cd "$(dirname "$0")/.." && pwd)
cat > /etc/systemd/system/homelab-backup-db.service <<EOF
[Unit]
Description=Dump homelab databases to /srv/backups/db
Requires=docker.service
After=docker.service
OnFailure=homelab-notify@%n.service

[Service]
Type=oneshot
User=$OWNER
ExecStart=$REPO/scripts/backup-db.sh
EOF
cat > /etc/systemd/system/homelab-backup-db.timer <<EOF
[Unit]
Description=Nightly homelab DB dumps

[Timer]
OnCalendar=*-*-* 02:00
Persistent=true

[Install]
WantedBy=timers.target
EOF
echo "== Failure emails (scripts/notify.sh)"
cat > /etc/systemd/system/homelab-notify@.service <<EOF
[Unit]
Description=Email the owner that %i failed

[Service]
Type=oneshot
User=$OWNER
SupplementaryGroups=systemd-journal
ExecStart=$REPO/scripts/notify.sh %i
EOF
systemctl daemon-reload
systemctl enable --now homelab-backup-db.timer

echo "Done. Log out and back in if you were just added to the docker group."
