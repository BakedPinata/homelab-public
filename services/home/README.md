# Home

Home automation. All internal (LAN and Tailscale) except Home Assistant, which is public (own login, 2FA on every user).

| App | Address | Network | Notes |
|---|---|---|---|
| Home Assistant | `https://hass.<domain>` | host | Phone apps use this address |
| Zigbee2MQTT | `https://zigbee.<domain>` | stack | Zigbee dongle → MQTT. Web page asks for `Z2M_FRONTEND_TOKEN` |
| Node-RED | `https://node.<domain>` | stack | Flows that talk to Home Assistant |
| ESPHome | `https://esphome.<domain>` | host | Builds and updates ESP device firmware |
| Mosquitto | `<server LAN IP>:1883` | stack, port published | MQTT for Zigbee2MQTT, Tasmota devices, Home Assistant |
| Matter server | `ws://localhost:5580` | host | Only Home Assistant talks to it |

Host-network apps have file routes in `services/traefik/config/dynamic/devices.yaml`. Home Assistant sees Traefik from the `proxy` network (`172.24.0.0/16`), which must be in its trusted proxies, or it answers 400 and logs "untrusted proxy". Since 2026.x the HTTP settings live in `.storage/http` (`stable.trusted_proxies`), not `configuration.yaml` (its `http:` block is ignored once migrated). Edit that file, then `docker compose restart homeassistant`.

## Mosquitto users
Users live in `/srv/appdata/home/mosquitto/config/mosquitto.passwd` (Home Assistant, Zigbee2MQTT, Tasmota devices each log in). Add or change one:
```bash
docker exec mosquitto mosquitto_passwd -b /mosquitto/config/mosquitto.passwd <user> <password>
docker exec mosquitto sh -c 'chown mosquitto:mosquitto /mosquitto/config/mosquitto.passwd && chmod 0600 /mosquitto/config/mosquitto.passwd'   # else it warns, and later versions refuse the file
docker exec mosquitto kill -HUP 1   # reload users
```

## Zigbee
- The dongle must show in `ls /dev/serial/by-id/`; `ZIGBEE_DONGLE` in `.env` is that path. The stack won't start without it.
- The network key, PAN ID and the coordinator backup are in `/srv/appdata/home/zigbee2mqtt` (`configuration.yaml`, `coordinator_backup.json`). Losing them means pairing every device again, as in October 2026.
- Pair a device: Zigbee2MQTT → **Permit join (All)**, then reset the device (IKEA: usually 6 quick power or button presses). It appears in Home Assistant through MQTT discovery. New device: rename it in Zigbee2MQTT with "Update Home Assistant entity ID" ticked. Re-paired device: Home Assistant knows it by its IEEE address and brings back the old entities by itself, so rename it to the old name with that box **unticked**.
- Pair mains-powered devices (plugs, repeater, bulbs) first: they are routers and extend the mesh. Battery devices: press a button now and then until the interview finishes.

## Matter
Pairing data (fabric) is in `/srv/appdata/home/matter`, owned by uid 1000. Add a device in the Home Assistant phone app: **Settings → Devices → Add device → Matter**. Delete a dead device in Home Assistant before re-pairing it, so the new one gets the old entity IDs. A device paired to a lost fabric needs a factory reset first. For a device also in another app (Google Home, eWeLink), that app's "Share / Link apps & services" gives a pairing code instead.

## Node-RED
The editor has no login unless `adminAuth` is set in `/srv/appdata/home/nodered/settings.js`:
1. Hash a password: `docker exec -it nodered node-red admin hash-pw`
2. In `settings.js`, uncomment `adminAuth` and set the username and that hash.
3. `docker compose restart nodered`

## Home Assistant
- Recorder history is SQLite (`home-assistant_v2.db`), dumped nightly by `scripts/backup-db.sh`; Duplicati excludes the live file. HA gets 2 minutes to stop (`stop_grace_period`); stop it by hand with `docker stop -t 120 homeassistant`, or the recorder logs an unclean shutdown.
- Public access (R9): own login plus 2FA (router `hass-public` in `devices.yaml`). Every new user turns on **Profile → Security → Multi-factor authentication → Authenticator app** before using it from outside.
- Switching accounts in one browser can leave the page stuck after login ("invalid authentication" on `/auth/token`): close every HA tab first (an open tab writes the old token back), then clear the site data for `hass.<domain>` in the browser's settings (`chrome://` or `brave://settings/content/all`; clearing from the address bar while a tab is open does not stick). Or give each person their own browser profile.
- Integrations take a bare hostname, not a URL: AdGuard is host `adguard.<domain>`, port 443, SSL and verify SSL on. Keep its *Filtering* switch entity disabled (`services/adguard/README.md`, Pausing ad blocking).
- Long-lived tokens (Profile → Security) are used by Node-RED (its Home Assistant server node) and `rest_command_auth` in `secrets.yaml` (`Bearer <token>`). Revoking one breaks both until they get the new one.
- Restore history: stop `homeassistant`, move `home-assistant_v2.db*` aside, then
  `gunzip < /srv/backups/db/homeassistant/latest.sql.gz | docker run --rm -i --user 0 -v /srv/appdata/home/homeassistant:/config keinos/sqlite3:3.53.4 sqlite3 /config/home-assistant_v2.db`

## Data
`/srv/appdata/home/<app>`: `homeassistant` (config, `.storage`, history), `mosquitto` (`config/` users, `data/` retained messages), `zigbee2mqtt`, `matter`, `esphome` (device YAML), `nodered` (flows; `flows_cred.json` is encrypted with the key in `.config.runtime.json`, so keep them together).
