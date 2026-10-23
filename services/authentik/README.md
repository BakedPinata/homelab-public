# Authentik

Sign-in for apps that have no login of their own (forward auth), and single sign-on later (Immich, Portainer, BookStack). UI: `https://auth.<domain>`. The sign-in pages are public; the admin UI (`/if/admin`) is internal only.

## First-time setup
1. Fill `.env` from `.env.sample` (secret key, database password, Gmail app password), then `docker compose up -d`. First start takes a minute or two.
2. Open `https://auth.<domain>/` (it redirects to the setup flow; opening `/if/flow/initial-setup/` directly shows "access denied") and set the `akadmin` email and password (store them in Vaultwarden).
3. Your user menu → **Settings → MFA Devices**: enrol a TOTP app for `akadmin`.
4. Test email: `docker exec authentik_worker ak test_email <your address>`.
5. **Applications → Outposts → authentik Embedded Outpost → Edit**: under advanced settings check `authentik_host: https://auth.<domain>` (usually set already).

## Put a sign-in page in front of an app
Gates apply to public routes only; the LAN goes straight in. Which apps are gated: [docs/access.md](../../docs/access.md).

1. **Applications → Applications → New Application ▾ → with New Provider...**: provider type **Proxy Provider**, authorization flow `default-provider-authorization-implicit-consent`, mode **Forward auth (single application)**, external host `https://<app>.<domain>`. Bind the groups allowed in ([below](#users-groups-and-app-access)).
2. **Outposts → authentik Embedded Outpost → Edit**: add the application.
3. In Traefik, add `authentik@file` after `public-chain@file` on the app's public router, plus a router that sends the outpost path to Authentik (labels: see `services/media/compose.yaml`, Seerr; file routes: `speed-outpost` in `devices.yaml`). Until step 1 is done, the gated route returns 404.
4. Add the public router's name to `services/traefik/config/crowdsec-whitelist.yaml` and run `docker compose up -d crowdsec` in `services/traefik`. Without it, CrowdSec can ban signed-in users (Seerr's logout fires a burst of 403s).

## Users, groups and app access
- **Group:** a set of users. Groups are what you grant apps to. A group needs no blueprint.
- **Blueprint:** Authentik settings kept as YAML in `blueprints/` (in git). The worker applies a file as soon as it is created or saved, and re-checks every hour; edits made in the UI to those objects are overwritten. Here blueprints only hold the invitation sign-up flows. A sign-up flow puts new users into one fixed group, so each group you want to *invite* people into has its own small file (`invitation-<group>.yaml`); the form they share is in `invitation-shared.yaml`.

**Add a group** (example `coworkers`):
1. With invitations: `sed 's/family/coworkers/g' blueprints/invitation-family.yaml > blueprints/invitation-coworkers.yaml`, then commit. The server's checkout is mounted into Authentik, so it applies straight away (no redeploy): **Customization → Blueprints** shows it as successful, and a `coworkers` group and `coworkers-enrollment` flow appear.
2. Without invitations: **Directory → Groups → Create** is enough.
3. Give the group its apps (below). A new group can reach nothing until then. Add it to the Users column in [docs/access.md](../../docs/access.md).

**Add a user:**
- Invite (preferred): **Directory → Invitations → Create**: flow `<group>-enrollment`, **Single use** on, an expiry a few days out. Expand the invitation's row to copy the link and send it. They choose a username and password, join the group and are signed in.
- By hand: **Directory → Users → Create**, add them to a group, then on the user's page **Set password** (creating a user never asks for one).
- Another group for an existing user: the group's page → **Users → Add existing user**.
- Users change their own password under user menu → **Settings**.

**Give or remove app access:** **Applications → Applications → `<app>` → Policy / Group / User Bindings → Bind existing policy / group / user → Group**. Anyone in any bound group gets in. To remove access, delete the binding; to shut out one person, take them out of the group or **Deactivate** them on their page.
- **An application with no bindings lets every signed-in user in.** Always bind at least one group (today all of them bind `family`).
- Authentik decides only for gated apps and apps signed in through Authentik (BookStack, Grimmory, Immich). Apps with their own login (Vaultwarden, Plex for Seerr) also need an account in that app. LAN visitors skip the gate.
- Admin rights: keep **Superuser** (on a group's settings) to `akadmin`. Limited admin rights, such as only creating invitations, are roles (**Directory → Roles**); none are set up.

**OAuth2 providers made in code** (`ak shell`, not the UI) start with no allowed grant types, and sign-in fails with "Invalid grant_type for provider" in the server log. Set `grant_types` (Immich: `authorization_code`, `refresh_token`); the UI ticks them all by default.

**Remove a group's invitations:** delete its blueprint file, then delete its flow and stages in the UI (removing a file leaves what it created in place).

Emailed resets ("Forgot password?", **Email recovery link**) need a recovery flow, which isn't set up yet: run the blueprint `Example - Recovery with email verification` (**Customization → Blueprints**), then set it as **Recovery flow** under **System → Brands → authentik-default**.

## Data
- Database: `authentik_postgres`, dumped nightly by `scripts/backup-db.sh`.
- `/srv/appdata/authentik/data`: uploads. Must be owned by uid 1000 (the container user).
- Never change `AUTHENTIK_SECRET_KEY` after the first start: it signs sessions and encrypts stored secrets.
