# Vaultwarden

Password manager for the owner and family, at `https://warden.<domain>` (`DOMAIN` in `.env`). Works with the Bitwarden apps and browser extensions (server URL: that address).

## Public access
Public through Traefik with `public-chain`: the apps can't pass an Authentik gate, so the vault's own login plus 2FA protects it. `/admin` only answers internally; it is disabled anyway, because no `ADMIN_TOKEN` is set. New users join by invitation only (sign-ups are off).

## Data
- `/srv/appdata/vaultwarden`: `db.sqlite3` (the vault), `attachments/`, `sends/`, `rsa_key*` (signs logins: losing it signs everyone out). `icon_cache/` rebuilds itself.

## Back up the database
Labelled `homelab.backup.sqlite`, so `scripts/backup-db.sh` dumps it nightly to `/srv/backups/db/vaultwarden/`. Dump now: `scripts/backup-db.sh vaultwarden`. Duplicati `nas-full` excludes the live `db.sqlite3*` files and keeps the rest of the folder.

## Restore the database
1. `docker compose stop vaultwarden`, then move `db.sqlite3*` aside.
2. Load the dump into a new file:
   ```bash
   gunzip < /srv/backups/db/vaultwarden/latest.sql.gz \
     | docker run --rm -i --user 0 -v /srv/appdata/vaultwarden:/data keinos/sqlite3:3.53.4 sqlite3 /data/db.sqlite3
   ```
3. `docker compose start vaultwarden` and log in.
