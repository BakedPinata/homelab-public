# Duplicati

Encrypted, versioned backups of this server. UI: `https://duplicati.<domain>` (internal) or port 8200 (password in `.env`). Database dumps come from `scripts/backup-db.sh`, which Duplicati then backs up.

## Jobs
Jobs live in Duplicati's own settings, not in git. Create them in the UI with these settings:

| Job | Destination | Schedule | Sources (under `/source`) | Keep |
|---|---|---|---|---|
| `nas-full` | Local folder `/backups/nas-full` | 03:00 daily (after the 02:00 dumps) | `appdata/`, `backups/db/`, `services/*/.env` | Smart retention |
| `offsite-critical` | **Not set up yet**: see [Offsite](#offsite-todo) | daily | `services/*/.env`, `backups/db/*/latest.sql.gz`, Vaultwarden, Home Assistant, Zigbee2MQTT, Authentik; photo originals if chosen | Smart retention |

- `nas-full` filters (job → **Source data → Filters**; pick the type from the dropdown, paths as the container sees them). Live database files are excluded because the dumps cover them:

  | Type | Value | Why |
  |---|---|---|
  | Excludes folder | `/source/appdata/authentik/db/` | live Postgres (dumped) |
  | Excludes folder | `/source/appdata/bookstack/db/` | live MariaDB (dumped) |
  | Excludes folder | `/source/appdata/grimmory/db/` | live MariaDB (dumped) |
  | Excludes folder | `/source/appdata/immich/db/` | live Postgres (dumped) |
  | Excludes folder | `/source/appdata/immich/model-cache/` | downloaded models, fetched again if lost |
  | Excludes expression | `/source/appdata/vaultwarden/db.sqlite3*` | live SQLite and its `-wal`/`-shm` (dumped) |
  | Excludes expression | `/source/appdata/home/homeassistant/home-assistant_v2.db*` | live SQLite (dumped) |
  | Excludes folder | `/source/appdata/duplicati/` | Duplicati's own settings |
  | Excludes expression | `/source/appdata/adguard/work/data/sessions.db` | locked while AdGuard runs; UI logins only |
  | Excludes expression | `/source/appdata/adguard/work/data/stats.db` | locked while AdGuard runs; dashboard stats only |
  | Excludes expression | `/source/appdata/home/homeassistant/.ha_run.lock` | lock file |
  | Excludes expression | `/source/appdata/home/esphome/.esphome/.device-builder.lock` | lock file |
  | Excludes folder | `/source/appdata/obsidian/config/.XDG/` | web desktop runtime (sockets, locks, print spool), rebuilt at start |

  - There is no "Excludes file" type: for one file, use "Excludes expression" with the exact path and no wildcard.
  - Use exact paths, not `*/db/`: Seerr's `media/seerr/db` isn't dumped, so the files are its only backup. A new service with a dumped database adds its own line.
  - A filter that doesn't match fails silently (a stray space is enough). After editing, check with **Restore** → latest version: the excluded paths must be absent.
  - Databases rarely lock their files, so a live database is copied without any warning, possibly half-written. Exclude it because it is dumped, not because it warns.
- **"File locked" warning** in the nightly email: Duplicati skipped that file and backed up the rest. Exclude the file if one of these holds, otherwise leave it and fix the cause:
  - **Nothing of value lost**: a lock file, cache, session or stats store. Ask: what would restoring without it cost? A re-login or an empty graph is fine; settings or user data is not.
  - **A dump covers it.** All three must hold:
    1. The container is dumped: `docker ps --filter label=homelab.backup.db=true --format '{{.Names}}'` lists it. For SQLite, the `homelab.backup.sqlite` label must name that same file: `docker inspect -f '{{index .Config.Labels "homelab.backup.sqlite"}}' <container>`.
    2. The dump is fresh: `ls -l /srv/backups/db/<container>/latest.sql.gz` shows today's 02:00 run. The script keeps only dumps that finished, and the timer emails on failure.
    3. The dump has the data: `zcat /srv/backups/db/<container>/latest.sql.gz | grep -c 'CREATE TABLE'` is above 0. The quarterly restore test proves it fully.
  - Neither holds (real data, no dump): don't exclude. Give the service a dump first (labels above), then exclude.
- Keep advanced option `hardlink-policy` at `All` (the default): `latest.sql.gz` is a hardlink, and other policies skip it.
- Dropping a source: remove it from the job (**Source data**) before removing its mount from `compose.yaml` and redeploying, or the job fails on the missing folder.
- Photos are not in `nas-full`: they already live on the NAS, protected by NAS snapshots.
- Encryption: AES-256 with a passphrase per job. Set once when the job is created; Duplicati stores it, so nightly runs need nothing.

## Failure emails (R21a)
Fill the `ALERT_*` keys in `.env`. Then, in the UI, open **Settings → Advanced options** (these apply to every job), add each option below and save. Duplicati doesn't read `.env`: type the values themselves, copied from it.

| Option | Value |
|---|---|
| `send-mail-url` | `smtps://smtp.gmail.com:465` |
| `send-mail-username` / `send-mail-password` | the values of `ALERT_SMTP_USER` / `ALERT_SMTP_PASSWORD` |
| `send-mail-from` / `send-mail-to` | the values of `ALERT_SMTP_USER` / `ALERT_EMAIL_TO` |
| `send-mail-level` | `Warning,Error,Fatal` |

Test:
1. In the same place, add `send-mail-any-operation`, tick it (true) and save.
2. Home page: `nas-full` → **Run now**. When it finishes, a "Success" email arrives.
3. Remove `send-mail-any-operation` and save, so only warnings and failures email.

A run that never starts (container down) sends nothing; phase 7 monitoring covers that.

The 02:00 dump timer emails through `scripts/notify.sh`, using the same keys. Test it with `scripts/notify.sh homelab-backup-db.service`.

## Passphrases: what to keep where
| Secret | Needed for | Keep in |
|---|---|---|
| Job passphrase (one per job) | Restoring, especially on a new server. **Lost = backups unreadable.** | Vaultwarden, and later `dr.env` (recovery pack) |
| `DUPLICATI_SETTINGS_ENCRYPTION_KEY` | Starting this container with its saved jobs | `.env`, Vaultwarden |
| `DUPLICATI_UI_PASSWORD` | Logging in to the UI | `.env`, Vaultwarden |

After creating or changing a job, export it (job menu → Export → "Encrypt file", using the job passphrase) and attach it to the job's Vaultwarden entry.

## Restore on a new server
1. Bootstrap the host, start this stack, and log in.
2. Import the exported job, or choose Restore → "Direct restore from backup files" with the destination and passphrase.
3. Restore to a scratch folder, then move files into place with the services stopped.

**Quarterly test:** direct restore (step 2) of one dump and one appdata folder into `/tmp/restore-test` inside the container, then compare checksums against `/source`. Only files changed since the backup should differ.

## Offsite (todo)
Choose a target, then add `offsite-critical`. Duplicati supports all of these natively. Prices checked October 2026, in USD/EUR, excluding tax:

| Option | Price | Good | Watch out |
|---|---|---|---|
| **Hetzner Storage Box BX11** | €3.20/mo flat for 1 TB | Cheapest if photos go offsite (~250 GB); SFTP; unlimited traffic; built-in snapshots | Germany/Finland only; fixed 1 TB steps (next is 5 TB at €10.90) |
| **Backblaze B2** | $6.95/TB/mo, pay per GB; first 10 GB free | Near free for critical data only (a few GB); S3 API; object lock (ransomware protection) | US/EU regions only |
| Wasabi | $7.99/TB/mo | Sydney region; no egress fees | Billed for 1 TB minimum and 90 days per file: Duplicati's compaction deletes trigger the 90-day charge |

Recommendation: Hetzner BX11 if photo originals go offsite, Backblaze B2 if only critical data does.
