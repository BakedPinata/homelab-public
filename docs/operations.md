# Operations

LAN, addresses, ports and NAS shares: `docs/network.md`.

## How the internet gets in
- **Cloudflare:** one DNS-only (grey cloud) wildcard record, `*.<domain>` → the static WAN IP. No per-host records: they would override the wildcard.
- **UX7:** one port forward, WAN TCP 443 → `192.168.10.103:8443` (Traefik's `public` entrypoint). No port 80: certificates use DNS-01, and browsers try https first.
- **Traefik:** a name answers publicly only if it has a router on `public`. Everything else gets 404, so going public or internal never needs a DNS change.
- **Close the public door in an emergency:** disable the UX7 forward. LAN and Tailscale keep working.

## Make an app public
1. Choose the login (R9): the app's own login with 2FA, or an Authentik gate if it's browser-only. Admin pages stay internal.
2. Add a second router next to the internal one:
   ```yaml
      - traefik.http.routers.<app>-public.rule=Host(`<app>.${DOMAIN}`)
      - traefik.http.routers.<app>-public.entrypoints=public
      - traefik.http.routers.<app>-public.middlewares=public-chain@file
   ```
   A separate router keeps `public-chain` (and any gate) off LAN traffic. Devices off this server: same thing in `services/traefik/config/dynamic/devices.yaml` (see `speed-public`).
3. Gate (browser-only apps): follow [services/authentik](../services/authentik/README.md#put-a-sign-in-page-in-front-of-an-app) (Authentik application, `authentik@file`, outpost router, CrowdSec whitelist). Exempt any API paths that native clients use and that check their own credentials with a separate router without the gate.
4. Update `docs/access.md`, deploy, and test from a phone on mobile data with Wi-Fi and Tailscale off.

## Make an app internal
Remove its `-public` (and `-outpost`) routers, update `docs/access.md`, and deploy. From mobile data the name now returns 404. Help anyone who still needs it install Tailscale.

## Test before going live
```bash
curl -sI --connect-to <app>.<domain>:443:192.168.10.103:8443 https://<app>.<domain>/
```
Keep the port out of the URL: Authentik matches applications on the exact host, so `https://<app>.<domain>:8443/` gets a 404 from a gate that works. Expect 302 to `auth.<domain>` from a gated app, 404 from an internal-only one.

## Deploys
A push to `main` runs `validate` on GitHub's runners. When it passes, `deploy` runs on the server's self-hosted runner: `scripts/deploy.sh <commit>` fast-forwards `~/homelab` and deploys each stack changed since the last good deploy (Traefik first; README-only changes deploy nothing). Per stack: `.env` check, DB dump, pull, `up --wait`. Services that mount a changed file (`traefik.yaml`, `mosquitto.conf`, `couchdb.ini`, the CrowdSec files) are recreated; mounted folders (Traefik's dynamic config, Authentik blueprints) are read live. A failed job emails you.
- **Guards:** the script refuses (and touches nothing) if `~/homelab` has uncommitted changes to tracked files, isn't on `main`, or has commits that aren't pushed. Commit and push, then use **Re-run jobs** on the failed run.
- **Rollback:** if a stack doesn't become healthy, its files from the last good deploy are put back, it's redeployed, the files go back to `main`, and the job fails. The containers keep the old config until fixed forward, so push the fix soon: a restart or reboot would load the new files. A rollback can't undo a database migration; the dump from that run (`/srv/backups/db`) is the way back.
- **Last good deploy:** the local ref `refs/homelab/deployed` (`git log -1 refs/homelab/deployed`). It moves only when every stack succeeds, so the next run retries what failed. Deploying by hand from `main` is fine: the next run just finds nothing to change.
- **Not automatic:** `nas/` stacks (Portainer, a note is printed), `.env` changes (`docker compose up -d` by hand), and stacks removed from the repo (take them down by hand first).
- **Check what would run:** `scripts/deploy.sh --dry-run origin/main`.

### Runner setup (once, or after a rebuild)
The runner runs as your user, which is in the `docker` group, so it can do anything on this server. It's registered on the private repo only, never the public one.
1. GitHub: private repo → Settings → Actions → Runners → **New self-hosted runner** (Linux, x64). Keep the page open for the download commands and the token.
2. On the server, as your user: run the page's download commands in `~/actions-runner`, then
   `./config.sh --url <repo URL> --token <token> --name <host> --labels homelab --unattended`
   and `sudo ./svc.sh install $USER && sudo ./svc.sh start`.
3. Check every stack matches `main` (each line should say no change):
   `for d in services/*/; do echo "$d"; docker compose -f "$d/compose.yaml" --dry-run up -d 2>&1 | grep -E 'Recreate|Creat'; done`
   then `scripts/deploy.sh --mark origin/main`.
4. Re-run the queued deploy job, or push a README change, and check it ends with `Deployed <commit>`.

## Updates
Renovate (GitHub App, private repo only) checks every pinned version and opens a PR per update; merging it deploys. Rules are in `renovate.json5`; the **Dependency Dashboard** issue lists everything pending.
- **Setup (once, or after a rebuild):** install the app from `github.com/apps/renovate` on the private repo only. In the Mend portal (`developer.mend.io`): Dependency Updates not Silent, **Automated PRs** on, **Require config file** on, **Create onboarding PRs** off.
- **Merge themselves** once a release is 3 days old and validate passes: CI tooling, the tools and media stacks (minor/patch), and the weekly linuxserver.io rebuilds (same app version, new `-lsNNN`, one grouped PR; lscr.io doesn't always give a release date, and a rebuild without one merges as soon as validate passes).
- **Everything else** waits for you: read the release notes linked in the PR, then merge. Merge one stack at a time so a failure points at one change.
- **Database majors** (Postgres, MariaDB, CouchDB, Valkey) only get a PR once you tick them on the **Dependency Dashboard** issue: they need a dump and restore, not a pull. Closing such a PR skips that major until the next one. Immich's database image is never updated by Renovate: follow Immich's release notes.
- **A failed update** rolls back and emails you, and the version stays bumped in `main`. Revert the PR's commit (or fix forward), and Renovate won't offer that version again until a newer one comes out.
- The host OS updates itself (`unattended-upgrades`: security and regular updates, no automatic reboot).

## Public repo
The private repo is the source of truth. After `validate` passes on a push to `main`, `publish-public` (GitHub's runners) copies every tracked file except those in `.publicignore` (`project/`, `CLAUDE.md`, `.claude/`, the deploy and publish workflows) to `<owner>/homelab-public` as one commit by `github-actions[bot]`. The private history and your git identity never go public. A file meant to stay private goes in `.publicignore` before its first push.
- **Denylist:** the `PUBLIC_DENYLIST` secret holds one regex per line (case-insensitive): real domain, names, email, username. If any file name or content matches, the publish fails and lists the files (never the match); fix the file and push. A missing or empty secret also fails it.
- **Public PRs:** `scripts/import-pr.sh <n>` applies public PR *n* as branch `public-pr-<n>` (author kept), opens a private PR so validate runs, and returns to `main`. It refuses a PR touching `.publicignore` paths and lists changes to `scripts/` and `.github/` for close review: merging deploys them on the server. After merging, close the public PR (the command is printed). The next publish brings the change across.
- **Check locally:** `git init -q /tmp/pub && PUBLIC_DENYLIST='<pattern>' scripts/publish-public.sh HEAD /tmp/pub`.

### Setup (once, or after a rebuild)
1. Create `<owner>/homelab-public` (public; issues and wiki off). Never register the self-hosted runner or install Renovate on it.
2. Make an SSH key pair; add the public half to the public repo as a deploy key **with write access**, and the private half to the private repo as the secret `PUBLIC_DEPLOY_KEY`. Delete the local copy.
3. Set `PUBLIC_DENYLIST` on the private repo: `gh secret set PUBLIC_DENYLIST < file`, or with no file it prompts for one line (join patterns with `|`).
4. Push to `main` (or re-run the latest `publish-public`) and check the public repo.
