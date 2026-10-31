# Time tracker (proof of concept)

A temporary test instance of a work-in-progress time tracker PWA, at `https://timetracker.<domain>`. It's built here from the app's private repo at a pinned commit; the app's own `poc/README.md` covers what it does and what to test. The container is nginx serving static files: entries live on the phone and in the user's own Google Sheet, so there is nothing to back up. When testing ends, [remove it](#remove-it).

## Access
- **Internet:** behind the Authentik gate (the driver's phone is on mobile data). `/manifest.webmanifest` and the two icons skip the gate (`timetracker-install` router): browsers fetch them without cookies, so "Install app" would fail otherwise. They hold only the app's name and icons.
- **LAN and Tailscale:** no gate.
- **Inside the app:** a PIN on the device, then Google sign-in for syncing. Google only lets in the test users listed on its Audience page.

## Setup (once)
1. **GitHub token:** Settings → Developer settings → Fine-grained tokens → Generate. Repository access: only the app's repo. Permissions: **Contents: Read-only**. Pick an expiry that outlasts the test, and note the date: when it expires, builds fail but the running app doesn't.
2. **`.env`:** copy `.env.sample` and fill it in: the repo's https URL, the token, and the Google Client ID.
3. **Google client** (Google Auth Platform → Clients → the web client): add `https://timetracker.<domain>` to **Authorized JavaScript origins** and `https://timetracker.<domain>/` to **Authorized redirect URIs**. LAN and internet use the same name, so one origin covers both. Changes take up to five minutes.
4. **Authentik:** follow [Put a sign-in page in front of an app](../authentik/README.md#put-a-sign-in-page-in-front-of-an-app) steps 1–2 (slug `timetracker`, external host `https://timetracker.<domain>`). In the provider's **Advanced protocol settings**, set **Token validity** to `days=30`: it's how long the gate session lasts (see [Gotchas](#gotchas)). Bind the owner's user, and the driver's once they have an Authentik account (invite them, [Users, groups and app access](../authentik/README.md#users-groups-and-app-access)). That page's steps 3–4 (Traefik routers, CrowdSec whitelist) are already done here.
5. Commit and push. The deploy builds the image (about a minute the first time) and starts it. Test from outside as in [Test before going live](../../docs/operations.md#test-before-going-live): expect a 302 to `auth.<domain>` for `/`, and a 200 for `/manifest.webmanifest`.
6. On the phone: open the address in Chrome, sign in to Authentik, choose a PIN, then the menu → **Add to Home screen** → **Install**.

## Update to a newer commit
1. Get the branch's latest commit: `git ls-remote <repo URL> proof-of-concept`.
2. In `compose.yaml`, replace the full commit in `context` and the first seven characters in `image`.
3. Commit and push. The deploy builds and swaps the container; a failed build or healthcheck rolls back to the old commit.
4. Reopen the app on the phone: it shows "New version ready". If it doesn't, read the service-worker gotcha below.

By hand instead (here, then commit soon: deploys refuse while changes are uncommitted): `docker compose up -d --wait`. `pull_policy: build` makes every `up` rebuild, which takes seconds when nothing changed.

Tidy up after a few updates: `docker image ls timetracker-poc`, `docker image rm` the old tags, and `docker builder prune` to drop the build cache (the .NET SDK is about 1 GB).

## Gotchas
- **Service worker and the gate:** the app's service worker answers every page load from its cache, including Authentik's `/outpost.goauthentik.io/callback`. The first sign-in works (no worker yet). Once the gate session expires, the installed app keeps working (logging, and syncing straight to Google), but it can't sign in to the gate again, so it gets no updates and keeps its last Client ID. Ways back:
  - Open the app on home Wi-Fi (split DNS uses the internal route, no gate), or on Tailscale.
  - Better, in the app repo: have the worker skip those paths (add `|| url.pathname.startsWith('/outpost.goauthentik.io/')` to the `fetch` handler's `return` condition in `service-worker.published.js`), and ship it while the session is still valid. After that, when updates stop, open `https://timetracker.<domain>/outpost.goauthentik.io/start?rd=https://timetracker.<domain>/` in Chrome to sign in again (untested: try it once after shipping the fix).
  - Never clear the site's data to fix it: that deletes rows that haven't synced.
- **Build warning** "Compose is configured to build using Bake, but buildx isn't installed": harmless. Compose builds with the daemon's BuildKit.
- **Build can't read the repo** ("repository does not contain ref", or an auth error): check the token hasn't expired and still covers the repo, and that `context` holds the full 40-character commit (BuildKit doesn't accept short ones).
- The app's Dockerfile uses unpinned base images (`dotnet/sdk:10.0`, `nginx:stable-alpine`), so a rebuild of the same commit can pick up newer ones. Renovate can't see them: they're in the app repo. Pin them there before this becomes more than a test.

## Remove it
Sync the phone first: rows that haven't synced exist only on the device. Then, in this order:
1. **Take it down** (deploys don't remove stacks): in `services/timetracker`, `docker compose down`. Its Traefik routes go with the container.
2. **Images and cache:** `docker image rm $(docker image ls -q timetracker-poc)`, then `docker builder prune`.
3. **Repo:** delete `services/timetracker/`, its row in `docs/access.md`, and `'timetracker-public@docker'` in `services/traefik/config/crowdsec-whitelist.yaml`. Add a `project/LOG.md` entry, then commit and push (the deploy recreates CrowdSec for the whitelist and warns that the stack was removed, as expected).
4. **Authentik:** Outposts → authentik Embedded Outpost → Edit: remove the application. Then delete the `timetracker` application and its provider. The driver's Authentik account stays unless they use nothing else: deactivate or delete it on their page.
5. **GitHub:** delete the fine-grained token.
6. **Google:** remove `https://timetracker.<domain>` from the client's origins and redirect URIs (or delete the Google project if the test is over).
7. **Phone:** uninstall the app, then Chrome → Site settings → `timetracker.<domain>` → **Delete data**.

Nothing else refers to it: no DNS record (the wildcard covers it), no appdata, no database dumps, nothing in Duplicati.
