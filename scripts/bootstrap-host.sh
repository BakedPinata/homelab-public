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

echo "== Docker waits up to 5 minutes for the NAS mounts (but still starts if they fail)"
# After a power cut the network can report online before the link is up (2026-11-25: 74 s early),
# so the boot-time mounts fail and containers start on empty folders. Retry until mounted.
cat > /usr/local/sbin/homelab-wait-for-nas <<'EOF'
#!/bin/sh
# Run before Docker starts (docker.service.d/wait-for-nas.conf, from scripts/bootstrap-host.sh).
end=$(( $(date +%s) + 300 ))
while :; do
  missing=$(findmnt --fstab -t cifs -rn -o TARGET | while read -r d; do mountpoint -q "$d" || echo "$d"; done)
  [ -z "$missing" ] && exit 0
  [ "$(date +%s)" -ge "$end" ] && break
  mount -a -t cifs 2>/dev/null
  sleep 5
done
echo "NAS shares still not mounted, starting Docker anyway:" $missing >&2
EOF
chmod 755 /usr/local/sbin/homelab-wait-for-nas
mkdir -p /etc/systemd/system/docker.service.d
cat > /etc/systemd/system/docker.service.d/wait-for-nas.conf <<EOF
[Unit]
Wants=${units[*]}
After=${units[*]}

[Service]
ExecStartPre=/usr/local/sbin/homelab-wait-for-nas
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
echo "== Watchdog emails (scripts/watchdog.sh, every 5 minutes)"
cat > /etc/systemd/system/homelab-watchdog.service <<EOF
[Unit]
Description=Check NAS mounts, containers and disks; email on change
OnFailure=homelab-notify@%n.service

[Service]
Type=oneshot
User=$OWNER
ExecStart=$REPO/scripts/watchdog.sh
EOF
cat > /etc/systemd/system/homelab-watchdog.timer <<EOF
[Unit]
Description=Homelab watchdog every 5 minutes

[Timer]
OnBootSec=5min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
EOF
echo "== UPS: shut down cleanly on battery (NUT client of the NAS, docs/operations.md#ups)"
# The UPS's USB cable is on the NAS, which shares it (DSM: Network UPS server; Synology's fixed
# login monuser/secret, read-only, allowed IPs only). Shut down after 2 minutes on battery, on low
# battery, or when the NAS enters Safe Mode (5 minutes, set in DSM) and sends FSD. Losing contact
# (USB unplugged, NAS rebooting, network) never shuts down while the UPS was last on mains.
apt-get install -y -qq nut-client
sed -i 's/^MODE=.*/MODE=netclient/' /etc/nut/nut.conf
grep -q '^MODE=' /etc/nut/nut.conf || echo 'MODE=netclient' >> /etc/nut/nut.conf
cat > /etc/nut/upsmon.conf <<EOF
# Written by scripts/bootstrap-host.sh
MONITOR ups@${NAS#//} 1 monuser secret secondary
MINSUPPLIES 1
SHUTDOWNCMD "/sbin/shutdown -h +0"
NOTIFYCMD /usr/sbin/upssched
POLLFREQ 5
POLLFREQALERT 5
DEADTIME 15
FINALDELAY 5
NOTIFYFLAG ONLINE SYSLOG+EXEC
NOTIFYFLAG ONBATT SYSLOG+EXEC
NOTIFYFLAG LOWBATT SYSLOG+EXEC
NOTIFYFLAG FSD SYSLOG+EXEC
NOTIFYFLAG SHUTDOWN SYSLOG+EXEC
NOTIFYFLAG COMMBAD SYSLOG
NOTIFYFLAG COMMOK SYSLOG
NOTIFYFLAG NOCOMM SYSLOG
NOTIFYFLAG REPLBATT SYSLOG
EOF
chown root:nut /etc/nut/upsmon.conf; chmod 640 /etc/nut/upsmon.conf
cat > /etc/nut/upssched.conf <<'EOF'
# Written by scripts/bootstrap-host.sh
CMDSCRIPT /usr/local/sbin/homelab-ups-event
PIPEFN /run/nut/upssched.pipe
LOCKFN /run/nut/upssched.lock
AT ONBATT * START-TIMER onbatt-shutdown 120
AT ONLINE * CANCEL-TIMER onbatt-shutdown
AT ONBATT * EXECUTE onbatt
AT ONLINE * EXECUTE online
AT LOWBATT * EXECUTE lowbatt
AT FSD * EXECUTE fsd
AT SHUTDOWN * EXECUTE shutdown
EOF
# Runs as user nut. Events queue in the spool; scripts/watchdog.sh emails them (within 5 minutes,
# or after the next boot if the internet was down).
install -d -o nut -g "$(id -gn "$OWNER")" -m 2770 /var/spool/homelab-ups
cat > /usr/local/sbin/homelab-ups-event <<'EOF'
#!/bin/sh
# Called by upssched with one event (/etc/nut/upssched.conf, from scripts/bootstrap-host.sh).
umask 007
case $1 in
  onbatt) msg="On battery: mains lost. The server shuts down in 2 minutes unless it returns." ;;
  online) msg="Back on mains." ;;
  onbatt-shutdown) msg="On battery for 2 minutes: shutting the server down." ;;
  lowbatt) msg="Battery low: shutting the server down." ;;
  fsd) msg="The NAS is entering Safe Mode: shutting the server down." ;;
  shutdown) msg="Server shutdown started." ;;
  *) msg="Event: $1" ;;
esac
logger -t homelab-ups "$msg"
printf '%s %s\n' "$(date '+%F %T')" "$msg" > "/var/spool/homelab-ups/$(date +%s%N).$1"
[ "$1" = onbatt-shutdown ] && /usr/sbin/upsmon -c fsd
exit 0
EOF
chmod 755 /usr/local/sbin/homelab-ups-event
systemctl enable nut-monitor
systemctl restart nut-monitor
sleep 3
upsc "ups@${NAS#//}" ups.status 2>/dev/null | grep -q . || echo "WARNING: can't read the UPS from the NAS (DSM: Network UPS server on, this host's IP allowed?)"
# The timer's shutdown is a signal from user nut to upsmon: check that path with a harmless reload
runuser -u nut -- /usr/sbin/upsmon -c reload || echo "WARNING: user nut can't signal upsmon, so the 2-minute shutdown won't work"

systemctl daemon-reload
systemctl enable --now homelab-backup-db.timer homelab-watchdog.timer

echo "Done. Log out and back in if you were just added to the docker group."
