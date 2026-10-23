# Media

Finds, downloads and organises TV and movies onto the NAS. Family members request titles through Seerr.

| Service | Port | Does |
|---|---|---|
| nzbget | 6789 | Usenet downloader |
| sonarr | 8989 | TV: finds episodes, sends them to nzbget, renames into `TV SERIES` |
| radarr | 7878 | Movies: same, into `2D MOVIES` |
| seerr | 5055 | Request page for family |

## Data
- Config: `/srv/appdata/media/<service>` (backed up)
- Media: NAS `Video` share; downloads: NAS `Downloads` share (not backed up by Duplicati)

## Notes
- Sonarr and Radarr reject unknown hostnames (HTTP 400 "Invalid Hostname"). Settings → General → Allowed Hosts must list `sonarr.<domain>` (or `radarr.…`) and `192.168.10.103` (Seerr connects by IP). Restart after saving.
- Usenet provider and indexer accounts are configured inside nzbget and sonarr/radarr. They are listed in the recovery pack as accounts to cancel.
- Plex runs on the NAS, not here. Signing in to Seerr with Plex makes Plex warn "another device is signing in" (it does this for every app sign-in): approve it if the named location is yours.
