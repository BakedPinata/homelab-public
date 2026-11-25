#!/usr/bin/env bash
# Email the owner that a systemd unit failed, with the end of its log (R21a), or send any message.
# Run by homelab-notify@<unit>.service (OnFailure= in bootstrap-host.sh), by scripts/watchdog.sh, or by hand to test.
# Mail settings: the ALERT_* keys in services/duplicati/.env (Duplicati sends its own failures with the same account).
# Usage: scripts/notify.sh <unit>
#        scripts/notify.sh -s <subject> < message
set -euo pipefail
umask 077
cd "$(dirname "$0")/.."

usage="usage: notify.sh <unit> | notify.sh -s <subject> < message"
if [[ ${1:-} == -s ]]; then
  subject=${2:?$usage}; body=$(cat)
else
  unit=${1:?$usage}
  subject="$unit failed on $(hostname)"
  body="$unit failed at $(date '+%F %T'). Last log lines:

$(journalctl -u "$unit" -n 30 --no-pager -o short-iso 2>&1 || true)"
fi
env=services/duplicati/.env
# Read only the keys needed (not sourced, so nothing in the file runs)
get() { grep -m1 "^$1=" "$env" | cut -d= -f2-; }
host=$(get ALERT_SMTP_HOST); port=$(get ALERT_SMTP_PORT)
user=$(get ALERT_SMTP_USER); pass=$(get ALERT_SMTP_PASSWORD); to=$(get ALERT_EMAIL_TO)
[[ -n $host && -n $user && -n $pass && -n $to ]] || { echo "FAIL ALERT_* keys missing in $env" >&2; exit 1; }

msg=$(mktemp); trap 'rm -f "$msg"' EXIT
{
  echo "From: homelab <$user>"
  echo "To: $to"
  echo "Subject: [homelab] $subject"
  echo "Date: $(date -R)"
  echo
  echo "$body"
} > "$msg"

# Credentials go to curl on stdin, so they never show in the process list
printf 'user = "%s:%s"\n' "$user" "$pass" |
  curl -sS --ssl-reqd -K - --url "smtps://$host:$port" \
    --mail-from "$user" --mail-rcpt "$to" --upload-file "$msg"
echo "OK   sent to $to"
