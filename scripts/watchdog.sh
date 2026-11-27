#!/usr/bin/env bash
# Email the owner when something stops working, and again when it's fixed.
# Checks: NAS shares in /etc/fstab not mounted; containers not running, unhealthy or crash-looping;
# Docker not responding; disks at 90% or more; the UPS unreadable, its monitor down, or its battery
# due. Also emails the UPS events that homelab-ups-event queues (on battery, back on mains, shutdown).
# A problem is reported once it shows on two runs in a row and cleared after two clean runs,
# so deploys and one-off restarts don't alert. If the email fails, the next run tries again.
# One self-fix: Traefik without its plugins is restarted once the internet is back (and emailed).
# Run every 5 minutes by homelab-watchdog.timer (bootstrap-host.sh), or by hand.
# Usage: scripts/watchdog.sh [--dry-run]   (--dry-run prints the problems, sends and saves nothing)
set -euo pipefail
export LC_ALL=C   # sort and comm must agree on order
cd "$(dirname "$0")/.."

state=${XDG_STATE_HOME:-$HOME/.local/state}/homelab-watchdog
mkdir -p "$state"; touch "$state/seen" "$state/reported" "$state/restarts"
UPS=${UPS:-ups@localhost}   # the EcoFlow River on this host's USB (bootstrap-host.sh)
spool=${UPS_SPOOL:-/var/spool/homelab-ups}   # UPS events queued by homelab-ups-event (bootstrap-host.sh)

problems() {
  local d
  for d in $(findmnt --fstab -t cifs -rn -o TARGET); do
    mountpoint -q "$d" || echo "NAS share not mounted: $d"
  done
  if ! docker info >/dev/null 2>&1; then
    echo "Docker is not responding"
  else
    # name status exit-code restart-count health
    docker ps -aq | xargs -r docker inspect -f \
      '{{slice .Name 1}} {{.State.Status}} {{.State.ExitCode}} {{.RestartCount}} {{if .State.Health}}{{.State.Health.Status}}{{end}}' \
      > "$state/containers.new" || true   # a container removed meanwhile is skipped
    awk 'FILENAME == ARGV[1] { before[$1] = $2; next }
      $2 != "running" && $2 != "restarting" { print "Container " $1 ": " $2 " (exit code " $3 ")"; next }
      $2 == "restarting" || ($1 in before && $4 > before[$1]) { print "Container " $1 ": crash-looping"; next }
      $5 == "unhealthy" { print "Container " $1 ": unhealthy" }' \
      "$state/restarts" "$state/containers.new"
    awk '{ print $1, $4 }' "$state/containers.new" > "$state/restarts.new"
    # Traefik downloads its plugins at start; with no internet it runs without them and every
    # public router (they all use crowdsec@file) is dropped, so public sites give 404 (2026-11-25)
    if started=$(docker inspect -f '{{.State.StartedAt}}' traefik 2>/dev/null) &&
       grep -q 'Plugins are disabled' <(docker logs --since "$started" traefik 2>&1 | head -n 200); then
      echo "Traefik started without its plugins: public sites give 404 (docker restart traefik)"
    fi
  fi
  # UPS (on this host's USB; the NAS is a network client of it, docs/operations.md#ups)
  if command -v upsc >/dev/null; then
    local u
    for u in nut-server nut-monitor; do
      systemctl is-active --quiet "$u" || echo "UPS service $u not running: no clean shutdown on power loss"
    done
    local ups
    if ! ups=$(upsc "$UPS" ups.status 2>/dev/null); then
      echo "UPS not readable (USB cable or NUT driver): no clean shutdown on power loss"
    else
      if [[ " $ups " == *" RB "* ]]; then echo "UPS says its battery needs replacing"; fi
      if [[ " $ups " == *" OVER "* ]]; then echo "UPS overloaded"; fi
    fi
  fi
  df -P / /srv 2>/dev/null | awk 'NR > 1 && $5 + 0 >= 90 { print "Disk " $6 " is " $5 " full" }' | sort -u
}

now=$(problems | sort -u)
rm -f "$state/containers.new"
if [[ ${1:-} == --dry-run ]]; then rm -f "$state/restarts.new"; echo "${now:-No problems}"; exit 0; fi
if [[ -f $state/restarts.new ]]; then mv "$state/restarts.new" "$state/restarts"; fi

# UPS events (on battery, back on mains, shutdown): one email for all queued, removed once sent
events=()
[[ -d $spool ]] && events=("$spool"/*.*)
if [[ -e ${events[0]:-} ]]; then
  last=$(cut -d' ' -f3- "${events[-1]}")
  if { echo "UPS events, oldest first:"; echo; cat "${events[@]}" | sed 's/^/- /'; } |
     ${NOTIFY:-scripts/notify.sh} -s "UPS: $last"; then
    rm -f "${events[@]}"
  fi
fi

# Self-fix: restart Traefik once the internet is back so it loads its plugins (at most every 30 min)
actions=""
if [[ $now == *"Traefik started without its plugins"* ]] && getent hosts plugins.traefik.io >/dev/null &&
   [[ -z $(find "$state/traefik-restarted" -mmin -30 2>/dev/null) ]]; then
  touch "$state/traefik-restarted"
  if docker restart traefik >/dev/null; then
    actions="Restarted traefik: it had started without its plugins (no internet at the time). If it happens again, the next email lists it as a problem."
  else
    actions="Tried to restart traefik (started without its plugins), but the restart failed."
  fi
fi

prev=$(sort -u "$state/seen"); reported=$(sort -u "$state/reported")
printf '%s\n' "$now" | sed '/^$/d' > "$state/seen"
lines() { printf '%s\n' "$@" | sed '/^$/d' | sort -u; }
# Reported: seen on both of the last two runs, or already reported and seen on either
confirmed=$(comm -12 <(lines "$prev") <(lines "$now"))
still=$(comm -12 <(lines "$reported") <(lines "$prev" "$now"))
next=$(lines "$confirmed" "$still")
new=$(comm -13 <(lines "$reported") <(lines "$next"))
fixed=$(comm -23 <(lines "$reported") <(lines "$next"))
[[ -z $new && -z $fixed && -z $actions ]] && exit 0

count=$(lines "$next" | wc -l)
if (( count > 0 )); then subject="$count problem(s) on $(hostname)"
elif [[ -n $actions ]]; then subject="Watchdog fixed something on $(hostname)"
else subject="All clear on $(hostname)"; fi
{
  echo "Watchdog run at $(date '+%F %T')."
  [[ -n $actions ]] && printf '\nDone:\n- %s\n' "$actions"
  [[ -n $new ]] && printf '\nNew:\n%s\n' "$(sed 's/^/- /' <<< "$new")"
  [[ -n $fixed ]] && printf '\nFixed:\n%s\n' "$(sed 's/^/- /' <<< "$fixed")"
  open=$(comm -12 <(lines "$reported") <(lines "$next"))
  [[ -n $open ]] && printf '\nStill open:\n%s\n' "$(sed 's/^/- /' <<< "$open")"
  if grep -q 'NAS share' <<< "$new"; then
    printf '\nNAS share missing: sudo mount -a -t cifs, then restart the containers that use it (docs/operations.md#alerts).\n'
  fi
} | ${NOTIFY:-scripts/notify.sh} -s "$subject"   # NOTIFY: a stand-in mailer for tests
lines "$next" > "$state/reported"
