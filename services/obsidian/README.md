# Obsidian

The owner's notes vault. Self-hosted LiveSync keeps every copy in step through CouchDB.

| Container | Address | Does |
|---|---|---|
| `obsidian` | `https://obsidian.<domain>` | Obsidian desktop in a browser tab (Selkies). It syncs through LiveSync like any other device |
| `obsidian_couchdb` | `https://couchdb.<domain>` | Sync server for the LiveSync plugin on every device |

## Access
- **Browser view:** public behind the Authentik gate, bound to the owner's user only. The LAN skips the gate and gets the desktop with no login.
- **CouchDB:** public with its own login, because the phone app can't pass a gate and CouchDB has no 2FA (R9 exception, decided 2026-10-20). What makes up for it: the sync user has rights on the `vault` database only, passwords are 48 hex characters, LiveSync encrypts notes end to end (the server only holds ciphertext), and `public-chain` (CrowdSec, rate limit) sits in front. Fauxton (`/_utils`) and the admin account stay internal (Fauxton asks for the admin login on the LAN too).
- CouchDB settings for LiveSync (single node, CORS for the apps, login on everything except `/_up`) are in `couchdb.ini`, loaded through `COUCHDB_INI_FILES` (why: `compose.yaml`).

## First setup
1. Fill in `.env` (both passwords: `openssl rand -hex 24`), then `docker compose up -d --wait`.
2. Create the sync user and the `vault` database, with that user as its only admin (the last `curl` alone restores its rights after a rebuild):
   ```bash
   docker exec obsidian_couchdb sh -c '
     a="$COUCHDB_USER:$COUCHDB_PASSWORD"; u=http://localhost:5984; j="Content-Type: application/json"
     curl -fsu "$a" -X PUT "$u/_users/org.couchdb.user:$LIVESYNC_USER" -H "$j" \
       -d "{\"name\":\"$LIVESYNC_USER\",\"password\":\"$LIVESYNC_PASSWORD\",\"roles\":[],\"type\":\"user\"}"
     curl -fsu "$a" -X PUT "$u/vault"
     curl -fsu "$a" -X PUT "$u/vault/_security" -H "$j" \
       -d "{\"admins\":{\"names\":[\"$LIVESYNC_USER\"],\"roles\":[]},\"members\":{\"names\":[\"$LIVESYNC_USER\"],\"roles\":[]}}"'
   ```
3. Authentik gate: [services/authentik](../authentik/README.md#put-a-sign-in-page-in-front-of-an-app) steps 1 and 2 for `https://obsidian.<domain>`; bind the owner's **user**, not a group. Traefik labels and the CrowdSec whitelist entry are already in place.
4. Browser view (`https://obsidian.<domain>` from the LAN): create a vault under `/config`. **Settings → Community plugins** → turn them on → install and enable **Self-hosted LiveSync**. Onboarding: **I am setting this up for the first time** → **Configure a remote manually**. Turn on end-to-end encryption and **Obfuscate Properties**, with a new passphrase saved in Vaultwarden (without it no device can read the notes). Remote: CouchDB, URL `https://couchdb.<domain>` (no trailing `/`, no database), database `vault`, and the **admin** login for now (see [Rebuild](#rebuild-the-remote)). Skip **Check server requirements** (the settings are in `couchdb.ini`). Let Config Doctor raise the chunk size while the database is empty. **Restart and Initialise Server** → **I Understand, Overwrite Server**. Then restore the sync user's rights (step 2, last `curl`), switch LiveSync to the `LIVESYNC_*` login, and make a test note.
5. Phone: in LiveSync on the browser view, run **Copy settings as a new setup URI** (command palette); it asks for a second passphrase that protects the URI. On Android: Obsidian → new empty vault → install Self-hosted LiveSync → **Use the copied setup URI** → paste it and enter that passphrase.
6. Test from the phone on mobile data with Wi-Fi and Tailscale off: edit a note and see it change in the browser view.

## Data
- `/srv/appdata/obsidian/config`: the vault as plain files, plus the LiveSync settings (including the sync password and the encryption passphrase). `.XDG/` is the web desktop's runtime folder (sockets, locks), rebuilt at every start and excluded from Duplicati.
- `/srv/appdata/obsidian/couchdb/data`: the encrypted sync database. `couchdb/etc/docker.ini`: the admin's password hash and the node's uuid. Changing `COUCHDB_*` in `.env` later does nothing; change the admin password with `curl -u <admin> -X PUT http://localhost:5984/_node/_local/_config/admins/<admin> -d '"<new>"'` from inside the container.

## Rebuild the remote
LiveSync's **Overwrite remote** / **Rebuild everything** (and first-time initialisation) deletes and recreates `vault`. Only a server admin can delete a database, so with the sync user it fails ("You are not a server admin", then "Replication is not ready because application initialisation has not completed"). Do it from the browser view on the LAN:
1. Switch LiveSync's remote login to the admin (`COUCHDB_*`) and run the rebuild.
2. The new `vault` is admin-only (sync user gets 403): run the last `curl` of [First setup](#first-setup) step 2.
3. Switch LiveSync back to the `LIVESYNC_*` login. Make a new setup URI and set each other device up again (**Restart and Fetch Data**).

**A device that never uploads** (log: "Replication is not ready because application initialisation has not completed", `vault` stays at one document) has a broken local index, for example after a failed first setup. Fetch from the remote on that device: it rebuilds its local database, then uploads the vault files the remote lacks. A fetch doesn't delete `vault`, so its rights stay (this happened on 2026-10-20 and fixed it).

## Backups and restore
Duplicati `nas-full` copies the whole folder nightly. CouchDB only ever appends to its files, so copies made while it runs are usable; no dump is needed. Every device also holds the whole vault.
- **Lost or broken CouchDB:** stop the stack, restore `couchdb/` from Duplicati (or start empty and redo step 2), start it. If devices complain that the remote doesn't match, LiveSync's **Rebuild everything** from the most complete device uploads it again.
- **Lost vault on one device:** set up LiveSync again; it downloads everything.

## Gotchas
- The admin username must be at least 2 characters: the image's admin check (`[admins]\n[^;]\w+`) misses a 1-letter name and refuses to start ("Admin Party").
- The first start logs `database_does_not_exist ... _users` twice while it creates the system databases. Later starts are clean.
- A sync burst that trips the rate limit or a CrowdSec scenario shows in the phone app as failed requests: check `docker exec crowdsec cscli decisions list` before changing anything.
