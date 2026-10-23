#!/usr/bin/env bash
# Dump database containers to $BACKUP_DIR/<container>/, then prune old dumps.
# Default: every running container labelled homelab.backup.db=true (MariaDB or Postgres).
# SQLite apps also set homelab.backup.sqlite=<path of the DB file inside the container>.
# Credentials come from the container's own environment and are never printed.
# Usage: scripts/backup-db.sh [container ...]
# Env: BACKUP_DIR (default /srv/backups/db), KEEP_DAYS (default 14)
set -euo pipefail
umask 077

BACKUP_DIR="${BACKUP_DIR:-/srv/backups/db}"
KEEP_DAYS="${KEEP_DAYS:-14}"
stamp=$(date +%Y%m%d-%H%M%S)
SQLITE_IMAGE=keinos/sqlite3:3.54.1   # SQLite apps rarely ship the sqlite3 CLI

if [[ $# -gt 0 ]]; then containers=("$@"); else
  mapfile -t containers < <(docker ps --filter label=homelab.backup.db=true --format '{{.Names}}' | sort)
fi
[[ ${#containers[@]} -gt 0 ]] || { echo "FAIL no database containers found"; exit 1; }

dump() {
  local sqlite
  sqlite=$(docker inspect -f '{{index .Config.Labels "homelab.backup.sqlite"}}' "$1")
  if [[ -n $sqlite ]]; then
    # Reads the live file through the app's own mounts; .dump runs in one read transaction
    docker run --rm --network none --user 0 --volumes-from "$1" "$SQLITE_IMAGE" \
      sqlite3 "file:$sqlite?mode=ro" .dump && echo "-- sqlite dump complete"
  elif docker exec "$1" sh -c 'command -v mariadb-dump' >/dev/null; then
    docker exec "$1" sh -c 'mariadb-dump -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" --single-transaction --routines --triggers "$MYSQL_DATABASE"'
  elif docker exec "$1" sh -c 'command -v pg_dump' >/dev/null; then
    docker exec "$1" sh -c 'pg_dump -U "$POSTGRES_USER" --clean --if-exists "$POSTGRES_DB"'
  else
    echo "no mariadb-dump, pg_dump or homelab.backup.sqlite label in $1" >&2; return 1
  fi
}

status=0
for c in "${containers[@]}"; do
  dir="$BACKUP_DIR/$c"; out="$dir/$c-$stamp.sql.gz"
  mkdir -p "$dir"
  # Each tool ends a finished dump with a "dump complete(d)" comment (newer pg_dump adds lines after it)
  if dump "$c" | gzip > "$out.partial" && zcat "$out.partial" | tail -n 5 | grep -qi 'dump complete'; then
    mv "$out.partial" "$out"
    ln -f "$out" "$dir/latest.sql.gz"   # stable name for the offsite job
    find "$dir" -name "$c-*.sql.gz" -mtime +"$KEEP_DAYS" -delete
    echo "OK   $c $(du -h "$out" | cut -f1)"
  else
    rm -f "$out.partial"
    echo "FAIL $c"; status=1
  fi
done
exit $status
