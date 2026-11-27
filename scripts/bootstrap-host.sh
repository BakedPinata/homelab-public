#!/usr/bin/env bash
# Prepare an Ubuntu host for the homelab. Safe to re-run.
# Usage: sudo scripts/bootstrap-host.sh
set -euo pipefail
# apt-get waits up to 5 minutes for the package lock (Ubuntu's daily apt job can hold it)

[[ $EUID -eq 0 ]] || { echo "Run with sudo: sudo $0"; exit 1; }
OWNER="${SUDO_USER:?run via sudo from your normal user}"
OWNER_UID=$(id -u "$OWNER"); OWNER_GID=$(id -g "$OWNER")
NAS="//192.168.10.7"
# NAS share name : mount point under /media
SHARES=(Downloads:Downloads Video:Video Docker:docker photos:Photos BACKUPS:Backups)

echo "== Packages"
apt-get -o DPkg::Lock::Timeout=300 update -qq
apt-get -o DPkg::Lock::Timeout=300 install -y -qq docker.io docker-compose-v2 cifs-utils git gh gitleaks yamllint jq curl
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
echo "== UPS: NUT server for the EcoFlow RIVER 3 Plus (USB here), clean shutdown at 20% (docs/operations.md#ups)"
# At 20% this host (primary) sets FSD: the NAS (DSM network UPS client of this host) enters Safe Mode,
# logs off, and this host shuts down. The River can't switch its outlets off (no killpower in NUT's
# EcoFlow driver), so nothing sees power return: this host sets an RTC alarm before shutting down,
# wakes every 15 minutes and powers off again while still on battery (homelab-ups-gate). Once mains is
# back it boots, reports OL, and the NAS leaves Safe Mode by rebooting itself (tested 2026-11-27).
# Losing contact with the UPS never shuts anything down while it was last on mains.
apt-get -o DPkg::Lock::Timeout=300 install -y -qq nut-server nut-client
sed -i 's/^MODE=.*/MODE=netserver/' /etc/nut/nut.conf
grep -q '^MODE=' /etc/nut/nut.conf || echo 'MODE=netserver' >> /etc/nut/nut.conf
cat > /etc/udev/rules.d/62-homelab-ups.rules <<'EOF'
# EcoFlow RIVER 3 Plus: let the NUT driver (user nut) open it
SUBSYSTEM=="usb", ATTR{idVendor}=="3746", ATTR{idProduct}=="ffff", MODE="0664", GROUP="nut"
EOF
udevadm control --reload; udevadm trigger --subsystem-match=usb --attr-match=idVendor=3746
cat > /etc/nut/ups.conf <<'EOF'
# Written by scripts/bootstrap-host.sh
maxretry = 3

[ups]
  driver = usbhid-ups
  port = auto
  vendorid = 3746
  productid = ffff
  desc = "EcoFlow RIVER 3 Plus"
  # The River never raises low battery itself (NUT issue 3068): derive it from the charge
  ignorelb
  override.battery.charge.low = 20
EOF
cat > /etc/nut/upsd.conf <<'EOF'
# Written by scripts/bootstrap-host.sh. LAN only: port 3493 isn't published to the internet.
LISTEN 0.0.0.0 3493
EOF
# monuser/secret: the fixed login a Synology uses as a network UPS client (secondary, read-only).
# The local monitor's own password is random, kept across re-runs.
pw=$(sed -n 's/^MONITOR ups@localhost 1 upsmon-local \([^ ]*\) primary$/\1/p' /etc/nut/upsmon.conf 2>/dev/null)
[[ -n $pw ]] || pw=$(head -c 18 /dev/urandom | base64 | tr -d '/+=')
cat > /etc/nut/upsd.users <<EOF
# Written by scripts/bootstrap-host.sh
[monuser]
  password = secret
  upsmon secondary
[upsmon-local]
  password = $pw
  upsmon primary
EOF
cat > /etc/nut/upsmon.conf <<EOF
# Written by scripts/bootstrap-host.sh
MONITOR ups@localhost 1 upsmon-local $pw primary
MINSUPPLIES 1
SHUTDOWNCMD "/usr/local/sbin/homelab-ups-poweroff"
NOTIFYCMD /usr/sbin/upssched
POWERDOWNFLAG /etc/killpower
POLLFREQ 5
POLLFREQALERT 5
DEADTIME 15
# Wait for the NAS to log off (it did ~60 s after FSD) before shutting down
HOSTSYNC 120
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
chown root:nut /etc/nut/ups.conf /etc/nut/upsd.conf /etc/nut/upsd.users /etc/nut/upsmon.conf
chmod 640 /etc/nut/upsd.users /etc/nut/upsmon.conf
cat > /etc/nut/upssched.conf <<'EOF'
# Written by scripts/bootstrap-host.sh
CMDSCRIPT /usr/local/sbin/homelab-ups-event
PIPEFN /run/nut/upssched.pipe
LOCKFN /run/nut/upssched.lock
AT ONBATT * EXECUTE onbatt
AT ONLINE * EXECUTE online
AT LOWBATT * EXECUTE lowbatt
AT FSD * EXECUTE fsd
AT SHUTDOWN * EXECUTE shutdown
EOF
# Events queue in the spool; scripts/watchdog.sh emails them (within 5 minutes, or after the next
# boot if the internet was down).
install -d -o nut -g "$(id -gn "$OWNER")" -m 2770 /var/spool/homelab-ups
cat > /usr/local/sbin/homelab-ups-event <<'EOF'
#!/bin/sh
# Called by upssched (as user nut) or homelab-ups-gate with one event (scripts/bootstrap-host.sh).
umask 007
case $1 in
  onbatt) msg="On battery: mains lost. Everything keeps running; it shuts down at 20% battery unless mains returns." ;;
  online) msg="Back on mains." ;;
  lowbatt) msg="Battery at 20%: shutting down (the NAS enters Safe Mode, then this server powers off)." ;;
  fsd) msg="Forced shutdown sent to the NAS." ;;
  shutdown) msg="Server shutdown started. It wakes every 15 minutes to check for mains." ;;
  boot-off) msg="Woke up still on battery: powering off again until the next check." ;;
  *) msg="Event: $1" ;;
esac
logger -t homelab-ups "$msg"
printf '%s %s\n' "$(date '+%F %T')" "$msg" > "/var/spool/homelab-ups/$(date +%s%N).$1"
exit 0
EOF
cat > /usr/local/sbin/homelab-ups-poweroff <<'EOF'
#!/bin/sh
# upsmon's SHUTDOWNCMD: the River never cuts its outlets, so set an RTC wake-up first (homelab-ups-gate).
/usr/sbin/rtcwake -m no -s 900 || logger -t homelab-ups "rtcwake failed: this server won't wake by itself"
exec /sbin/shutdown -h +0
EOF
nas_mac=$(ping -c1 -W1 "${NAS#//}" >/dev/null 2>&1; ip neigh show "${NAS#//}" | awk '{print $5}')
echo "NAS_MAC=$nas_mac" > /etc/default/homelab-ups
cat > /usr/local/sbin/homelab-ups-gate <<'EOF'
#!/bin/sh
# Runs before Docker at boot (homelab-ups-gate.service). On battery and under 30%: this boot is the
# 15-minute check after a low-battery shutdown, so set the next wake-up and power off again.
# Otherwise carry on, and wake the NAS in case it powered off (normally it waits in Safe Mode).
. /etc/default/homelab-ups
for i in $(seq 30); do st=$(upsc ups@localhost ups.status 2>/dev/null) && break; sleep 2; done
charge=$(upsc ups@localhost battery.charge 2>/dev/null | cut -d. -f1)
case " $st " in
  *" OB "*)
    if [ "${charge:-100}" -lt 30 ]; then
      runuser -u nut -- /usr/local/sbin/homelab-ups-event boot-off
      /usr/sbin/rtcwake -m no -s 900
      systemctl poweroff --no-block
      exit 0
    fi ;;
esac
[ -n "$NAS_MAC" ] && python3 -I -c 'import socket,sys
m=bytes.fromhex(sys.argv[1].replace(":",""))
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.setsockopt(socket.SOL_SOCKET,socket.SO_BROADCAST,1)
s.sendto(b"\xff"*6+m*16,("255.255.255.255",9))' "$NAS_MAC"
exit 0
EOF
chmod 755 /usr/local/sbin/homelab-ups-event /usr/local/sbin/homelab-ups-poweroff /usr/local/sbin/homelab-ups-gate
cat > /etc/systemd/system/homelab-ups-gate.service <<'EOF'
[Unit]
Description=Stay off while the UPS is still on low battery; else wake the NAS
After=nut-server.service nut-driver.target
Wants=nut-server.service
Before=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/homelab-ups-gate

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable nut-server nut-monitor homelab-ups-gate
systemctl restart nut-driver-enumerator.service 2>/dev/null || true
# Installing nut-server starts it on the package's empty config; it fails and hits systemd's start limit
systemctl reset-failed nut-server nut-monitor 2>/dev/null || true
systemctl restart nut-server nut-monitor
sleep 5
upsc ups@localhost ups.status 2>/dev/null | grep -q . || echo "WARNING: can't read the River (USB cable, or: journalctl -u 'nut-driver@*')"
[[ -n $nas_mac ]] || echo "WARNING: NAS MAC not found, so no wake-on-LAN at boot (edit /etc/default/homelab-ups)"

systemctl daemon-reload
systemctl enable --now homelab-backup-db.timer homelab-watchdog.timer

echo "Done. Log out and back in if you were just added to the docker group."
