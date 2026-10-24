# Network

UniFi gear: a UniFi Express 7 (router, DHCP, firewall), a US-8-60W and a Flex Mini switch, a UAP-AC-PRO access point. Switch ports aren't assigned: any device can use any port. The ISP gives a static IPv4 address with no CGNAT. How the internet gets in (port forward, Cloudflare, Traefik's two entrypoints): `docs/operations.md`.

## VLANs
| VLAN | ID | Subnet | What |
|---|---|---|---|
| Main | 10 | `192.168.10.0/24` | Server, NAS, JetKVM, OctoPrint Pi, phones and laptops |
| IoT | 30 | `192.168.30.0/24` | Tapo, Cast. Home Assistant reaches into it. |
| NoT | 40 | `192.168.40.0/24` | Tasmota. The server can't reach in; the devices connect out to Mosquitto on `192.168.10.103:1883`. |

Docker networks must stay off these ranges: `/etc/docker/daemon.json` pins them to `172.16.0.0/12` (`scripts/bootstrap-host.sh`). Tailscale advertises `192.168.10.0/24` (`services/tailscale`).

## Fixed addresses
| Address | Device | Set by |
|---|---|---|
| `192.168.10.1` | UX7 (gateway) | The router's own address |
| `192.168.10.7` | Synology NAS: shares, DSM `:5001`, Portainer `:9000`, Plex `:32400`, speedtest `:3000`, AdGuard secondary (DNS `:53`, UI `:3053`) | DHCP reservation |
| `192.168.10.101` | JetKVM | DHCP reservation |
| `192.168.10.103` | Server: everything in `services/` | DHCP reservation for its network card (`enp0s31f6`) |
| `192.168.10.171` | OctoPrint Pi | DHCP reservation |

Reservations are in UniFi under Client Devices → the device → Settings → Fixed IP Address. New hardware has a new MAC address: move the reservation to it.

DHCP (UX7, Settings → Networks → LAN) hands out DNS `192.168.10.103` then `192.168.10.7` (`services/adguard`).

## Server ports
Published on `192.168.10.103`; everything else is only reachable through Traefik.

| Port | What |
|---|---|
| 53 | AdGuard DNS (host network, this address only) |
| 80, 443 | Traefik internal entrypoint (80 redirects) |
| 8443 | Traefik public entrypoint: the UX7 forwards WAN 443 here |
| 1883 | Mosquitto (Tasmota, Home Assistant) |
| 8123, 6052 | Home Assistant, ESPHome (host network; Traefik routes `hass`, `esphome`) |
| 8200 | Duplicati (fallback when Traefik is down) |
| 6789, 8989, 7878, 5055 | nzbget, Sonarr, Radarr, Seerr |
| 9001 | Portainer agent (the NAS's Portainer connects in) |

## NAS shares
Mounted by `scripts/bootstrap-host.sh` (`/etc/fstab`, `_netdev,nofail`, credentials in `~/.smbcredentials`). Docker waits for the mounts but still starts without them.

| Share | Mount point | Holds |
|---|---|---|
| `photos` | `/media/Photos` | Immich library (originals in `library/`) |
| `Video` | `/media/Video` | Films and TV (Plex, Sonarr, Radarr) |
| `Downloads` | `/media/Downloads` | nzbget downloads, Grimmory books |
| `Docker` | `/media/docker` | Archives (the retired `~/homeautomation`) |
| `BACKUPS` | `/media/Backups` | Duplicati `nas-full`, manual archives |

Mount one by hand (to test, or on another Linux box): `sudo mount -t cifs //192.168.10.7/<share> /media/<dir> -o credentials=$HOME/.smbcredentials,uid=$(id -u),gid=$(id -g),vers=3.0`.

