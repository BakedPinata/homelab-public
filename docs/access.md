# Access register

Every web address, where it runs, and who reaches it. All addresses are `https://<name>.<domain>`.
**Internal** = LAN and Tailscale (the owner's phone and laptop; see `services/tailscale`). **Public** = internet, through Traefik's public entrypoint (how, and how to switch: `docs/operations.md`). Internal visitors skip any Authentik gate.

| Name | What | Runs on | Exposure | Users | Login |
|---|---|---|---|---|---|
| `books` | BookStack wiki | Server | Public | Owner, family, friends | Authentik sign-in (password login is the fallback, README) |
| `grimmory` | Ebook library | Server | Public | Owner, family, friends | Authentik sign-in (OIDC-only mode; admins also `/login?local=true`); device credentials (e-reader sync) |
| `immich` | Immich photos | Server | Public | Owner, family | Authentik sign-in (Password Login off; recovery in README) |
| `timetracker` | Time tracker proof of concept (temporary) | Server | Public; manifest and icons ungated | Owner, driver | Authentik gate; the app's own PIN and Google sign-in |
| `obsidian` | Obsidian notes (browser view) | Server | Public | Owner | Authentik gate (owner's user only); none on the LAN |
| `couchdb` | Obsidian LiveSync server | Server | Public; `/_utils` internal | Owner | CouchDB login (no 2FA: R9 exception, `services/obsidian`) |
| `hass` | Home Assistant | Server | Public | Owner, partner | App login + 2FA |
| `seerr` | Media requests | Server | Public | Owner, family | Authentik gate + Plex sign-in |
| `speed` | OpenSpeedTest | NAS | Public | Family | Authentik gate |
| `warden` | Vaultwarden | Server | Public; `/admin` internal | Owner, family | App login + 2FA |
| `auth` | Authentik sign-in | Server | Public sign-in pages; admin UI internal | Owner, family, friends | Own account + TOTP (admin) |
| `zigbee`, `node`, `esphome` | Zigbee2MQTT, Node-RED, ESPHome | Server | Internal | Owner | Token, app login, app login |
| `uml`, `ittools` | PlantUML, IT-Tools | Server | Public | Owner | Authentik gate (owner's user only); none on the LAN (PlantUML's VS Code extension needs that) |
| `nzbget`, `sonarr`, `radarr` | Media automation | Server | Internal | Owner | App login |
| `duplicati` | Backups | Server | Internal | Owner | App login |
| `adguard` | DNS admin | Server | Internal | Owner | App login |
| `traefik` | Proxy dashboard | Server | Internal | Owner | None (internal only) |
| `nas` | Synology DSM | NAS | Internal | Owner | DSM login |
| `portainer` | Portainer server | NAS | Internal | Owner | App login |
| `plex` | Plex web | NAS | Internal (Plex's own remote access for others) | Owner, family | Plex account |
| `jetkvm` | Server console | JetKVM | Internal | Owner | Device login |
| `octopi` | OctoPrint | Pi | Internal | Owner | App login |

Server-app routes are Docker labels in each `compose.yaml`; the rest are in `services/traefik/config/dynamic/devices.yaml`.
