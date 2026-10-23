# Grimmory

Ebook library. Port `GRIMMORY_PORT` (see `.env`). Drop new books into the Bookdrop folder and Grimmory imports them.

## Public access
Public with no Authentik gate. Grimmory's own login has no 2FA, so **OIDC-only mode** must stay on (**Settings → OIDC Settings**): the login page sends users to Authentik, and the server refuses password logins from non-admins. Admins can still sign in with a password at `/login?local=true`; CrowdSec and rate limits cover that page. E-reader sync uses the device credentials set in Grimmory, so the same URLs work at home and away: Kobo `/api/kobo/<token>`, KOReader `/api/koreader`, OPDS `/api/v1/opds`.

Single sign-on: Grimmory's OIDC with the Authentik application `grimmory` (OAuth2/OpenID provider, bound to `family` and `friends`). Redirect URI `https://grimmory.<domain>/oauth2-callback`, issuer `https://auth.<domain>/application/o/grimmory/` (the slug is part of it: renaming the application's slug breaks sign-in until the issuer here matches). `OIDC_ALLOW_UNSAFE_HOSTS=true` in `compose.yaml` is needed because `auth.<domain>` resolves to a LAN IP, which Grimmory's outbound filter blocks; it only affects OIDC requests.
- Leave **Allowed Mobile Redirect URIs** empty or `grimmory://oauth2-callback` (https is rejected there). "Could not reach the OIDC provider" usually means a wrong client secret: check `docker logs grimmory` for `invalid_client`.
- Existing Grimmory accounts link only when the Authentik username matches exactly. Turn on **Link Existing Local Accounts**, sign in once, then turn it off.

## Gotchas
- A 404 on both the internal and public address means Traefik dropped the route because the container is unhealthy. Seen once (v3.5.0): an internal deadlock left Java running but not answering. `docker compose restart grimmory` fixes it.

## Data
- App data: `/srv/appdata/grimmory/app`
- Database files: `/srv/appdata/grimmory/db`. Back up the dump, not these files.
- Books: NAS `Downloads/Grimmory/Books`

## Back up and restore the database
Same as [BookStack](../bookstack/README.md#back-up-the-database), with `grimmory_mariadb` and `grimmory` in place of the BookStack container names.
