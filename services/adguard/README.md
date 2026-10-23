# AdGuard Home

DNS for the LAN: blocks ads and trackers, and answers `*.<domain>` with the server's LAN IP (split DNS), so internal names reach Traefik without leaving the house. UI: `https://adguard.<domain>` (internal). A secondary runs on the NAS (`nas/adguard`), kept in step by adguardhome-sync.

DNS listens on `192.168.10.103:53` only. The server itself keeps using systemd-resolved on `127.0.0.53`, which takes its upstreams from DHCP. After changing DNS on the UX7, renew the lease instead of waiting up to a day: `sudo nmcli con up netplan-enp0s31f6` (the network drops for a second or two), then check with `resolvectl dns enp0s31f6`.

## First-time setup
1. Uncomment the `3000` and `3001` port lines in `compose.yaml`, `docker compose up -d`, then open `http://192.168.10.103:3000`.
2. Wizard: Admin web interface **All interfaces, port 80**; DNS server **All interfaces, port 53** (these are inside the container). Create the admin login and store it in Vaultwarden.
3. Ignore the wizard's final link (`http://192.168.10.103/` is Traefik, which refuses bare IPs). Open `http://192.168.10.103:3001` and log in. `https://adguard.<domain>` only works once step 5's rewrite exists.
4. **Settings → DNS settings:**
   - Upstream: `https://dns.quad9.net/dns-query` and `https://cloudflare-dns.com/dns-query`, mode **Parallel requests**.
   - Bootstrap DNS: `9.9.9.9`, `1.1.1.1`.
5. **Filters → DNS rewrites:** `<domain>` → `192.168.10.103` and `*.<domain>` → `192.168.10.103`.
6. Comment out the `3000` and `3001` port lines in `compose.yaml` again and run `docker compose up -d`.

## Secondary on the NAS
`nas/adguard/compose.yaml`, deployed as a Portainer stack on the NAS. `adguardhome_sync` (in this stack) sets it up and copies settings to it, so never change settings on the NAS copy: they are overwritten.
1. Synology's Docker won't create missing bind folders, so create them first (from the server): `mkdir -p /media/docker/adguard/conf /media/docker/adguard/work`. The NAS must not run its own DNS Server package (it holds port 53).
2. Portainer → NAS environment → Stacks → Add stack → name `adguard` → Web editor: paste `nas/adguard/compose.yaml`. Add environment variable `NAS_DOCKER_PATH` (the Docker share's path on the NAS, e.g. `/volume1/docker`). Deploy.
3. Here: fill the `ADGUARD_*` keys in `.env` and `docker compose up -d`. Check `docker logs adguardhome_sync` for a successful sync.
4. Test: `dig +short @192.168.10.7 books.<domain>` → `192.168.10.103`.
5. UX7 (Settings → Networks → LAN → DHCP Service Management): DNS servers `192.168.10.103` and `192.168.10.7`. Only once Traefik is running with its routes: the rewrite sends every `*.<domain>` name to it.

## Test
```bash
dig +short @192.168.10.103 books.<domain>   # expect 192.168.10.103
dig +short @192.168.10.103 example.com          # expect a public IP
dig +short @192.168.10.103 doubleclick.net      # expect 0.0.0.0 (blocked)
```

## Rollout
Test on one device first (set its DNS to `192.168.10.103` by hand). The UX7 only hands out AdGuard once the NAS secondary is running, so one box going down never takes out DNS for the house.

## Pausing ad blocking
Use **Protection** (UI or the HA switch); rewrites keep working (tested 2026-10-20). Never turn off **Filtering** (General settings, or HA's *Filtering* switch, which is disabled in HA): it also turns off DNS rewrites, so `*.<domain>` resolves to the WAN IP and every internal app returns 404 from Traefik's `public` entrypoint. adguardhome-sync copies it to the NAS within minutes, so there is no fallback, and HA's integration (host `adguard.<domain>`) can no longer reach AdGuard to undo it. To recover, add `192.168.10.103 adguard.<domain>` to one PC's hosts file, turn filtering back on in the UI, then remove the line.

## Data
`/srv/appdata/adguard/conf` holds the settings (backed up). `work/` holds query logs and stats.
