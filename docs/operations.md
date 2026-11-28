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
- **Not Renovate:** the `timetracker` stack builds from the owner's own private repo, which would put the owner's name in a published file. That repo opens the update PR instead (`services/timetracker`).
- **A failed update** rolls back and emails you, and the version stays bumped in `main`. Revert the PR's commit (or fix forward), and Renovate won't offer that version again until a newer one comes out.
- The host OS updates itself (`unattended-upgrades`: security and regular updates, no automatic reboot).

## Alerts
Everything emails the owner through `scripts/notify.sh` (the `ALERT_*` keys in `services/duplicati/.env`): a failed DB dump, deploy or Duplicati job, and the **watchdog**. `homelab-watchdog.timer` runs `scripts/watchdog.sh` every 5 minutes. It reports NAS shares that aren't mounted, containers that are stopped, unhealthy or crash-looping, Docker not responding, and disks at 90% or more. It emails once when a problem has shown on two runs in a row, again when it's fixed, and stays quiet in between. `scripts/watchdog.sh --dry-run` shows what it sees now. It also emails UPS events ([UPS](#ups)). It can't report the server itself being off or offline.
- **NAS share not mounted:** `sudo mount -a -t cifs`, then `docker restart` the containers using it (`immich_server`, `duplicati`, `grimmory`, `nzbget`, `sonarr`, `radarr`). Until then they see an empty local folder: Immich refuses to start and Duplicati won't start at all, which is intended. At boot, Docker waits up to 5 minutes for the shares (`homelab-wait-for-nas`, `scripts/bootstrap-host.sh`), so this only happens when the NAS is down for longer.
- **Traefik started without its plugins:** every public site gives `404 page not found` (internal ones still work). Traefik downloads the CrowdSec plugin at start, and every public router uses `crowdsec@file`, so with no internet at that moment they are all dropped. The watchdog restarts Traefik itself once the internet is back (at most every 30 minutes) and emails you; if that didn't help, the next email lists it as a problem. By hand: `docker restart traefik`.

## UPS
An EcoFlow RIVER 3 Plus (LFP, 286 Wh, switchover under 10 ms) powers the NAS, this server and the US-8-60W switch (with the access point on its PoE); the Flex Mini is not on it. A Tapo plug on its mains input ("Homelab (Tapo 2)" in Home Assistant) shows the draw, about 100 W, so a full battery lasts roughly 2 hours. Its USB cable goes to **this server**: NUT 2.8.4 here has a driver for it, DSM's doesn't. The NAS is a network client of this server.
- **Policy:** ride out outages; at **20% battery** this server tells the NAS to shut down (it enters Safe Mode about a minute later and logs off), then powers itself off. Losing contact with the UPS (USB unplugged, NUT restarting) never shuts anything down while it was last on mains.
- **Coming back:** the River can't switch its outlets off (NUT's EcoFlow driver has no shutdown command), so nothing sees power return. Before powering off, this server sets an RTC alarm and wakes every 15 minutes. `homelab-ups-gate` runs before Docker: still on battery and under 30%, it powers off again; otherwise it boots, reports mains to the NAS, and sends it a wake-on-LAN. A NAS in Safe Mode keeps polling and **reboots itself** about 45 seconds after the server reports mains again (tested 2026-11-27); Docker waits for its shares as usual.
- **Setup:** `scripts/bootstrap-host.sh` installs and configures NUT (driver, server, monitor), the gate, the RTC wake and the email events. **DSM** (Control Panel → Hardware & Power): UPS support on, type "Synology UPS server", server IP this server's, Safe Mode **until low battery** (our forced shutdown at 20% is what triggers it), network UPS server off; Wake on LAN on (General). **Home Assistant**'s NUT integration points at this server's IP, port 3493. **EcoFlow app:** AC output never times out.
- **Emails:** the watchdog emails UPS events (on battery, back on mains, shutting down, a 15-minute check that powered off again) within 5 minutes, or after the next boot if the internet was down. It also reports the UPS unreadable, `nut-server` or `nut-monitor` down, or a replace-battery flag. Logs: `journalctl -t homelab-ups -u nut-server -u nut-monitor -u 'nut-driver@*'`.
- **Tests:** `upsc ups@localhost` shows the River. `sudo rtcwake -m off -s 120` must bring this server back in 2 minutes (if not, enable RTC or "resume by alarm" in the BIOS). Pull the River's mains plug for a minute: on battery, then back on mains, nothing shuts down. A full test runs the battery to 20%; at about 100 W that takes over an hour and a half.
- **Readings:** on mains the River reports a meaningless runtime (about 34 hours); on battery it is sensible (about 2¼ hours at 80%, falling with the charge, 2026-11-27). NUT raises low battery at 20% charge or under 10 minutes runtime, whichever comes first; at this load the charge comes first.
- **Watch for:** after a low-battery shutdown, if mains returns while the charge is still under 20%, the status shows `OL LB` until it charges past 20% (a few minutes). If the NAS stays in Safe Mode after that, reboot it by hand and note it here. If the River ever drains completely, check that its AC output comes back on by itself.

## NAS over SSH
For jobs Portainer and DSM can't do, such as upgrading the Portainer server itself. Use it, then log out; never change `nas/` stacks this way (they belong to Portainer).
- **Turn it on (DSM, once):** Control Panel → Terminal & SNMP → Terminal: **Enable SSH service**, port 22, Apply. Only members of the **administrators** group can log in: use your own DSM admin account (the built-in `admin` is disabled). DSM's 2-factor login doesn't apply to SSH, so keep it LAN-only: Control Panel → Security → Firewall, if enabled, allows port 22 from `192.168.10.0/24` only. Port 22 is never forwarded on the router.
- **Connect** from this server, or a PC's terminal (PowerShell on Windows, Terminal on macOS): `ssh <dsm-admin>@192.168.10.7`, and type the DSM password. The first time, it asks to trust the NAS's key: answer `yes` (it's saved in `~/.ssh/known_hosts`). If it later warns that the key **changed** and the NAS wasn't reinstalled, stop and find out why; after a reinstall, `ssh-keygen -R 192.168.10.7` and connect again.
- **Root and Docker:** your shell starts as your own user. Docker needs root: prefix with `sudo` (`sudo docker ps`) and give the same password, or `sudo -i` for a root shell (`exit` to leave). If `sudo docker` says command not found, use `sudo /usr/local/bin/docker`. The `Docker` share is at the path in the `adguard` stack's `NAS_DOCKER_PATH` (e.g. `/volume1/docker`); this server mounts it at `/media/docker`.
- **Key login (optional, saves the password):** DSM keeps `~/.ssh` only with user homes on: Control Panel → User & Group → Advanced → **Enable user home service**. Then from the client: `ssh-copy-id <dsm-admin>@192.168.10.7`, and on the NAS `chmod 755 ~ && chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys` (DSM's sshd ignores the key if the home folder is group-writable). `sudo` still asks for the password.
- **Shortcut:** in the client's `~/.ssh/config`: `Host nas`, `HostName 192.168.10.7`, `User <dsm-admin>` (one per line), then just `ssh nas`.
- **Leave:** `exit`. If you only turn SSH on when needed, turn it off again in the same DSM page.

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
