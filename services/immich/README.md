# Immich

Photo and video library for the owner and family, at `https://immich.<domain>` (the mobile apps use that address as the server URL). Photos stay on the NAS Photos share; the database is on local disk, never on the share (R16).

## Sign-in
Authentik application `immich` (OAuth2/OpenID provider, bound to `family`). Redirect URIs: `app.immich:///oauth-callback` (phone apps), `https://immich.<domain>/auth/login`, `https://immich.<domain>/user-settings`.

In Immich, **Administration → Settings → Authentication Settings → OAuth**:
- Issuer URL `https://auth.<domain>/application/o/immich/`; client ID and secret from the Authentik provider page; scope `openid email profile`.
- Button text "Sign in with Authentik". **Auto register** off: only existing Immich users get in.
- Immich links a sign-in to the Immich user with the same email, so each person's Authentik email must match their Immich one.

- **Auto Launch** on: the login page goes straight to Authentik.

Public access needs **Password Login** off (Immich's own login has no 2FA, R9).

**Locked out** (the login page says "Login has been disabled": OAuth and password login are both off, or Authentik is down):
1. `docker exec immich_server immich-admin enable-password-login`
2. Sign in with an Immich admin's email and password (`immich-admin reset-admin-password` if forgotten), fix the OAuth settings and test **Sign in with Authentik** in a private window.
3. Turn Password Login off again (UI, or `docker exec immich_server immich-admin disable-password-login`).

Check what the login page offers: `https://immich.<domain>/api/server/features` (`oauth`, `passwordLogin`).

## Data
- NAS `/media/Photos` (mounted as `/data`): `library/` (originals, about 240 GB), `upload/`, `profile/`, plus `thumbs/` and `encoded-video/` (rebuilt from the originals if lost). Protected by NAS snapshots, not `nas-full`.
- `/srv/appdata/immich/db`: live Postgres. Back up the dump, not these files.
- `/srv/appdata/immich/model-cache`: machine-learning models, downloaded again if lost.

## Backups
Two dumps, both nightly:
- `scripts/backup-db.sh` (label `homelab.backup.db`) to `/srv/backups/db/immich_postgres/`, picked up by Duplicati.
- Immich's own (Administration → Settings → Backup) to `/media/Photos/backups/`, named with the Immich and Postgres versions. Restore needs that same Immich version.

## Restore the database
Restores into an empty database, on the Immich version the dump was made with (the file name says it).
1. Stop the stack and move `/srv/appdata/immich/db` aside, so Postgres starts empty.
2. Start only the database: `docker compose up -d --wait database`
3. Load the dump. The `sed` lets Immich's vector extension resolve its types (Immich's own restore steps do the same):
   ```bash
   gunzip --stdout <dump>.sql.gz \
     | sed "s/SELECT pg_catalog.set_config('search_path', '', false);/SELECT pg_catalog.set_config('search_path', 'public, pg_catalog', true);/g" \
     | docker exec -i immich_postgres sh -c 'psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"'
   ```
4. `docker compose up -d --wait`, then check photos, albums and people.

## Upgrades
Read the release notes for every version in between: Immich flags breaking changes there, and some upgrades must stop at a given version. Then change both Immich tags in `compose.yaml` (and the Postgres image only if the new release's compose file changes it).
