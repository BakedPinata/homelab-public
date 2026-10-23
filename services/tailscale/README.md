# Tailscale

Lets the owner's phone and laptop reach the home LAN from anywhere (subnet router for `192.168.10.0/24`), look up `*.<domain>` through AdGuard (split DNS), and optionally send all traffic home on untrusted Wi-Fi (exit node). Machine name in the tailnet: `homelab`.

## Setup
1. Admin console (login.tailscale.com) → **Machines**: remove any old machine from the previous stack.
2. **Settings → Keys → Generate auth key**: one-off, not ephemeral, pre-approved. Put it in `.env` (and nowhere else; it is only needed for the first login).
3. `sudo scripts/bootstrap-host.sh` (turns on IPv4/IPv6 forwarding), then `docker compose up -d`.
4. **Machines → homelab → ⋯**:
   - **Edit route settings**: approve `192.168.10.0/24` and **Use as exit node**.
   - **Disable key expiry**, so the server never drops off the tailnet.
5. **DNS → Nameservers → Add nameserver → Custom**: `192.168.10.103`, turn on **Restrict to domain** → `<domain>`. Repeat with `192.168.10.7`.
6. Clients: Windows/macOS/phones accept subnet routes by default. Linux laptop: `sudo tailscale set --accept-routes`.

## Test
On the phone, off home Wi-Fi (mobile data) with Tailscale on: `https://nas.<domain>` should load.
On the server: `docker exec tailscale tailscale status`.

## Notes
- The host is nftables-only, so the container must run with `TS_DEBUG_FIREWALL_MODE=nftables`. Without it, `tailscale status` shows an iptables health warning and subnet traffic is silently dropped.
- AdGuard sees Tailscale clients as `192.168.10.103` (subnet traffic is NATed through the server).
- The key in `.env` can be deleted after the first login; the state in `/srv/appdata/tailscale` (backed up) keeps the node logged in.
