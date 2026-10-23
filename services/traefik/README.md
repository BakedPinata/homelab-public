# Traefik

Reverse proxy for every web app, with one Let's Encrypt wildcard certificate for `*.<domain>` (Cloudflare DNS challenge, so no ports are opened for certificates).

| Entrypoint | Port | Reached from |
|---|---|---|
| `internal` | 443 (80 redirects) | LAN and Tailscale. Never port-forwarded. |
| `public` | 8443 | Internet, via the UX7 forward from WAN 443. Every router here uses `public-chain@file`. |

Dashboard: `https://traefik.<domain>` (internal).

## Add an app
In the app's `compose.yaml`:
```yaml
    labels:
      - traefik.enable=true
      - traefik.http.routers.<app>.rule=Host(`<app>.${DOMAIN}`)
      - traefik.http.routers.<app>.entrypoints=internal
      # - traefik.http.services.<app>.loadbalancer.server.port=<port>   # if the image exposes several
    networks:
      - proxy   # declared at the bottom as: proxy: { external: true }
```
Devices off this server (NAS, JetKVM, ...) get routes in `config/dynamic/`, which reloads without a restart.

To make an app public as well, add a second router on the `public` entrypoint. Steps and the Authentik gate are in [docs/operations.md](../../docs/operations.md#make-an-app-public).

## CrowdSec
`crowdsec` reads Traefik's access log and bans IPs that scan or attack. The `crowdsec` middleware (in `public-chain`) checks every public request against its ban list. LAN and Tailscale addresses are never banned.
```bash
docker exec crowdsec cscli decisions list     # current bans
docker exec crowdsec cscli alerts list        # what triggered them
docker exec crowdsec cscli decisions delete --ip <ip>   # unban
docker exec crowdsec cscli bouncers list      # Traefik should show a recent "last pull"
docker exec crowdsec cscli explain --type traefik --log '<access.log line>'   # which parsers and scenarios a line hits
```

## Files
- `config/traefik.yaml`: static config. `__DOMAIN__` in it is filled in from `DOMAIN` (`.env`) at start by the entrypoint in `compose.yaml`. Both HTTPS entrypoints allow 600 s to read a request (default 60 s cuts off large uploads). Restart after changes: `docker compose restart traefik`.
- Every stack names its hosts as `<app>.${DOMAIN}`, with `DOMAIN` in its own `.env`; `config/dynamic/` files use `{{ env "DOMAIN" }}`.
- `config/dynamic/`: routes (`devices.yaml`) and middlewares (`public.yaml`, `authentik.yaml`, `tls.yaml`), reloaded automatically.
- `config/crowdsec-acquis.yaml`: which logs CrowdSec reads.
- `config/crowdsec-whitelist.yaml`: Authentik-gated routers CrowdSec ignores (their visitors are signed in). Apply with `docker compose up -d crowdsec`; check with `cscli explain` (below).
- `/srv/appdata/traefik/acme.json`: the certificate and Let's Encrypt account. Backed up by `nas-full`.

## Test a route before DNS points at it
```bash
curl -sI --resolve traefik.<domain>:443:192.168.10.103 https://traefik.<domain>/dashboard/
```
Public entrypoint: [docs/operations.md](../../docs/operations.md#test-before-going-live).
Requests to Traefik's own services (dashboard, ping) are not written to the access log.

## Gotchas
- This stack creates the `proxy` network, so start it before apps that join it.
- Traefik reads Docker through `traefik_socket_proxy` (read-only, containers only), never the socket directly.
