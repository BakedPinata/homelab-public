# BookStack

Wiki for notes and documentation, at `https://books.<domain>`. Port `BOOKSTACK_PORT` (see `.env`).

## Sign-in
Through Authentik (OIDC): the login page sends everyone straight to Authentik, which does the 2FA. Authentik's `bookstack` application binds the `friends` and `service-admins` groups (who can reach BookStack); other groups decide what they see. BookStack's own MFA is off: it would ask for a second code after Authentik (it applies to OIDC sign-ins too), so no role has **Require Multi-Factor Authentication** and no user has MFA methods set up. BookStack has no switch to hide it, so Traefik answers 403 on the setup paths (`bookstack-no-mfa` router); the **Setup** button in My Account still shows and leads there. Code checks at sign-in, removal, and the admin's **Reset MFA** still work.
- **Authentik provider** (UI, like Immich's): OAuth2/OpenID, slug `bookstack` (the issuer URL in `compose.yaml` depends on it), confidential client, redirect URI `https://books.<domain>/oidc/callback` (strict), signing key `authentik Self-signed Certificate` (BookStack needs RS256; without a key Authentik signs with HS256 and sign-in fails). Client ID and secret go in `.env`.
- **Linking:** BookStack finds a user by **External Authentication ID** (the user's page, shown while `AUTH_METHOD=oidc`), which must equal Authentik's `sub` for that user, not the email. Email isn't used: Authentik users can change their own, which would let them take over another account.
- **Roles come from Authentik groups** at every sign-in (`OIDC_USER_TO_GROUPS`). A group matches a role by the role's **External Authentication IDs** field, or else by its name (case ignored; the group name lowercased, spaces as hyphens). Roles no group matches are removed (`OIDC_REMOVE_FROM_GROUPS`), so change roles in Authentik: an edit in BookStack lasts until that user's next sign-in.
  | Authentik group | BookStack role | Rights |
  |---|---|---|
  | `service-admins` | Admin (External Authentication ID `service-admins`) | everything |
  | `bookstack-general` | `bookstack-general` (name match) | view all, comment (add; edit and delete own), minus items that exclude it |
  | `friends` | none | reaches BookStack, sees nothing |

  The default registration role is **None**: sync keeps the default role for everyone, so any other default would be a role nobody can lose. Built-in roles left: Admin, and Public (visitors not signed in; public access is off).
- **Map a role before anyone signs in with it.** The Admin mapping must stay: without it the next sign-in strips the owner's Admin role (fix: fallback below, or set `roles.external_auth_id` again from the dump).
- **New people:** Authentik invitation for `friends` → their first BookStack sign-in creates the account with no role (empty wiki) → add them to `bookstack-general` (or another BookStack group) in Authentik → they sign out and in again (roles only change at sign-in).
- **Hide a shelf or book from `bookstack-general`:** the item's **Permissions** → add an override for the role → untick **View**. Books inside a hidden shelf stay visible on their own unless they're hidden too (shelf permissions don't flow down to books).
- **Narrower access later:** a new Authentik group (for example `bookstack-recipes`), a BookStack role with the same name and no view-all rights, and that role given **View** on the shelf or book's **Permissions**. Groups are sent without their parent groups, so a user needs the exact group.
- **Authentik down or misconfigured:** set `BOOKSTACK_AUTH_METHOD=standard` in `.env` and `docker compose up -d`. The password login comes back with the old passwords; users created through Authentik have no password (use **Forgot password**). It has **no 2FA** then: remove the `bookstack-no-mfa` router and tick **Require Multi-Factor Authentication** on every role (users set it up at their next sign-in), or remove the `bookstack-public` router until Authentik works again.

## Data
- App files and uploads: `/srv/appdata/bookstack/app`
- Database files: `/srv/appdata/bookstack/db`. Back up the dump, not these files.

## Back up the database
Dumped nightly to `/srv/backups/db/bookstack_mariadb/` (see [Backups](../../README.md#backups)). Dump now: `scripts/backup-db.sh bookstack_mariadb`.

## Restore the database
1. Stop the app only: `docker stop bookstack` (leave `bookstack_mariadb` running).
2. Load the dump:
   ```bash
   gunzip < /srv/backups/db/bookstack_mariadb/latest.sql.gz \
     | docker exec -i bookstack_mariadb sh -c 'mariadb -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" "$MYSQL_DATABASE"'
   ```
3. Start it again: `docker start bookstack`.

## Gotchas
- `MYSQL_ROOT_PASSWORD` is only applied when the database is first created. The current database's real root password differs from `.env`, so dumps and restores use the app user.
- If the site address changes, update `APP_URL` and run `docker exec bookstack php /app/www/artisan bookstack:update-url <old> <new>`.
