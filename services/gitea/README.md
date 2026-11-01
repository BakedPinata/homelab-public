# Gitea

Private git hosting (your own small GitHub) at `https://git.<domain>`, with git over SSH on port `GITEA_SSH_PORT` (2222). Internal: LAN and Tailscale. Own Postgres. Nobody can sign up and nothing is visible without signing in; new repositories are private.

## Setup (once)
1. **`.env`:** copy `.env.sample` and fill it in (database password).
2. **Folders**, as your user (Gitea runs as uid 1000; Docker would create missing ones as root and Gitea couldn't write): `mkdir -p /srv/appdata/gitea/app /srv/appdata/gitea/config`
3. **Start:** commit and push (the deploy starts it), or `docker compose up -d --wait` here.
4. **Setup page:** open `https://git.<domain>`.
   - Everything is filled in from `compose.yaml`: leave it. Check **Database Type** PostgreSQL on `gitea_postgres:5432`, **Server Domain** `git.<domain>`, **SSH Server Port** `2222`, **Gitea Website URL** `https://git.<domain>/`.
   - **Optional Settings → Server and Third-Party Service Settings:** self-registration off and **Require sign-in to view pages** on are already set; leave them.
   - **Optional Settings → Administrator Account Settings:** pick a username (`admin` is reserved), email and password. Store them in Vaultwarden.
   - **Install Gitea.** You're signed in. It writes `app.ini`, including `SECRET_KEY` ([Data](#data-and-backups)).
   - Then `docker exec gitea mkdir -p /var/lib/gitea/git/repositories`. Gitea only makes it with the first repo; until then every SSH command prints "Unable to access repository path" and the first push-to-create fails.
5. **2FA** (optional while internal, required to go public): avatar → **Settings → Security → Two-Factor Authentication**. Store the scratch code in Vaultwarden.
6. **Duplicati** (UI, `nas-full` filters): add **Excludes folder** `/source/appdata/gitea/db/` (live Postgres, dumped). See [services/duplicati](../duplicati/README.md#jobs).
7. **Each computer** you'll use: git, then an SSH key or a token ([Using it](#once-per-computer)). Without a key in Gitea, SSH answers "Permission denied (publickey)".

## Using it
Words you'll see: a **repository** (repo) is a project folder with its full history. Gitea keeps the main copy; you **clone** it to a computer, **commit** changes there (a saved snapshot with a message), **push** commits up to Gitea and **pull** other people's (or your other computer's) commits down. `origin` is git's name for the copy you cloned from. `main` is the default branch.

### Once per computer
1. Install git. Linux: `sudo apt install git`. Windows: Git for Windows (includes Git Credential Manager, which remembers tokens). macOS: `xcode-select --install`.
2. Tell git who you are (goes into every commit): `git config --global user.name "<your name>"` and `git config --global user.email "<email>"`. Also `git config --global init.defaultBranch main`.
3. Choose how git signs in: an **SSH key** (best on your own computers: set up once, never asks again) or **HTTPS with a token** (works anywhere Gitea's web page works). Either is fine; you can use both.

### Sign in with an SSH key
1. Make a key: `ssh-keygen -t ed25519 -C "<computer name>"`. Enter for the default file; a passphrase is optional.
2. Show the public half: `cat ~/.ssh/id_ed25519.pub` (Windows PowerShell: `type $env:USERPROFILE\.ssh\id_ed25519.pub`). Never share the file without `.pub`.
3. Gitea → avatar → **Settings → SSH / GPG Keys → Add Key**: paste it, name it after the computer.
4. Test: `ssh -T -p 2222 git@git.<domain>`. Answer `yes` to the first-time host key question. Expect "Hi there, `<user>`! You've successfully authenticated…".

The SSH user is always `git`: Gitea knows who you are from the key. SSH addresses look like `ssh://git@git.<domain>:2222/<user>/<repo>.git` (the repo page's **SSH** button shows it).

### Sign in with HTTPS and a token
1. Gitea → avatar → **Settings → Applications → Generate New Token**: name it after the computer, set **repository** to **Read and Write** (the rest No Access), **Generate Token**. Copy it now: it's shown once.
2. The first time git asks: username = your Gitea username, password = the token. Git Credential Manager (Windows, macOS) stores it. Linux: `git config --global credential.helper store` saves it in `~/.git-credentials` in plain text (fine on your own machine).

HTTPS addresses look like `https://git.<domain>/<user>/<repo>.git`. Your Gitea password also works there until 2FA is on; a token is better because you can revoke one computer's without changing anything else (same page → **Delete**).

### Make a new repository
**Starting from nothing:** **+** (top right) → **New Repository**. Give it a name, tick **Initialize Repository** (adds a README, and a `.gitignore` for the language you pick), **Create Repository**. Then on your computer:
```bash
git clone ssh://git@git.<domain>:2222/<user>/<repo>.git
cd <repo>
```

**A folder you already have:**
```bash
cd my-project
git init                      # skip if it's already a git repo
git add .
git commit -m "First commit"
git remote add origin ssh://git@git.<domain>:2222/<user>/my-project.git
git push -u origin main       # creates the repo in Gitea (private) if it doesn't exist yet
```
`-u` remembers `origin main`, so later it's just `git push`. Before the first `git add`, make a `.gitignore` listing what must never go in: `.env` and other secrets, build output, `node_modules/`. A committed secret stays in the history even after you delete the file.

### Every day
```bash
git pull                      # start here: get commits made elsewhere (other computer, web editor)
# ...edit files...
git status                    # what changed
git add <file>                # or `git add .` for everything
git commit -m "What and why"
git push
```
On a second computer, clone once, then the same loop. If a push is refused with "fetch first", someone (you, elsewhere) pushed in between: `git pull`, then `git push`. If pull reports a **conflict**, git marks the clashing lines in the file (`<<<<<<<` … `>>>>>>>`): keep what you want, delete the markers, `git add <file>`, `git commit`, `git push`.

Trying something out: `git switch -c try-idea` makes a branch, `git push -u origin try-idea` sends it up. Merge it back with a **Pull Request** in Gitea, or locally: `git switch main && git merge try-idea && git push`.

### Bring a repo over from GitHub
**+** → **New Migration** → **GitHub**: the repo URL, and for a private repo a GitHub token (fine-grained, that repo, Contents read-only). Tick **This repository will be a mirror** to keep pulling from GitHub on a schedule; leave it off for a one-time move. Then point your clone at the new home: `git remote set-url origin <Gitea address>`.

### Other people
Sign-up is off. Avatar → **Site Administration → Identity & Access → User Accounts → Create User Account**. Share a repo with them: the repo → **Settings → Collaborators**.

## Reach it from outside
**Easiest: Tailscale.** With Tailscale on, the laptop and phone use AdGuard and the LAN route ([services/tailscale](../tailscale/README.md)), so `git.<domain>` and SSH on 2222 work exactly as at home. Nothing to change here.

**Public (a computer without Tailscale):** HTTPS only, following [Make an app public](../../docs/operations.md#make-an-app-public). Gitea's own login with 2FA (R9); no Authentik gate, because git clients can't pass one.
1. Every account enrols 2FA (setup step 5). Then add `GITEA__security__TWO_FACTOR_AUTH=enforced` to `compose.yaml`: accounts without 2FA lose web and API access. With 2FA on, git over HTTPS takes tokens only, not passwords.
2. Add the public router; the admin pages stay internal:
   ```yaml
      - traefik.http.routers.gitea-public.rule=Host(`git.${DOMAIN}`) && !PathPrefix(`/-/admin`)
      - traefik.http.routers.gitea-public.entrypoints=public
      - traefik.http.routers.gitea-public.middlewares=public-chain@file
   ```
3. CrowdSec bans for failed logins (Gitea logs real client IPs: `REVERSE_PROXY_TRUSTED_PROXIES`): in `services/traefik/compose.yaml` add `LePresidente/gitea` to `COLLECTIONS`, and in `services/traefik/config/crowdsec-acquis.yaml` a source like Vaultwarden's with `container_name: [gitea]` and `type: gitea`. Check after deploying: one wrong password, then `docker exec crowdsec cscli metrics show acquisition` shows Gitea lines parsed.
4. `docs/access.md`: change the row to Public. Deploy, then test from a phone on mobile data with Wi-Fi and Tailscale off.

Leave SSH home: from the internet it needs its own UX7 forward (WAN 2222 → `192.168.10.103:2222`) that goes straight to Gitea, past Traefik and CrowdSec. HTTPS with a token does the same job. Single sign-on through Authentik (like BookStack) is possible later: an OAuth2 provider in Authentik, then Gitea's **Site Administration → Identity & Access → Authentication Sources**.

## Data and backups
- `/srv/appdata/gitea/app`: repositories (`git/repositories/<user>/<repo>.git`, plain bare git repos), attachments, LFS files, the SSH host key. Owned by uid 1000. Backed up by Duplicati `nas-full`.
- `/srv/appdata/gitea/config/app.ini`: settings, including `SECRET_KEY` (encrypts 2FA secrets). Restore it with the rest; never generate a new one. Settings in `compose.yaml` overwrite their lines at every start.
- `/srv/appdata/gitea/db`: live Postgres, excluded from Duplicati. Dumped nightly to `/srv/backups/db/gitea_postgres/` ([Backups](../../README.md#backups)). Dump now: `scripts/backup-db.sh gitea_postgres`.
- Every clone on a computer is a full copy of its repo's history: `git push` to an empty Gitea repo brings it back.

## Restore the database
As [Authentik's](../authentik/README.md#restore-the-database), with `gitea_postgres` in place of `authentik_postgres`: stop the stack, move `/srv/appdata/gitea/db` aside, `docker compose up -d --wait gitea_postgres`, load `latest.sql.gz` with `psql`, then `docker compose up -d --wait`. Use the Gitea version the dump was made with.

The dump (02:00) is older than Duplicati's file copy (03:00). A repo created in between comes back as files only: **Site Administration → Code Assets → Repositories → Unadopted Repositories → Adopt**.

## Updates
Renovate opens a PR for each new `gitea/gitea` version; it waits for you. Read the release notes (breaking changes); database migrations run on start, after the deploy's dump. The deploy rolls back files, not migrations: the dump is the way back.

## Gotchas
- **Forgotten password:** `docker exec -it gitea gitea admin user change-password --username <user> --password <temporary>`, then change it in the UI.
- **Port 22 is the server's own SSH,** not Gitea's. Clone addresses need `:2222`, or a `~/.ssh/config` entry so plain `git@git.<domain>:<user>/<repo>.git` works:
  ```
  Host git.<domain>
    Port 2222
    User git
  ```
- **"Permission denied (publickey)":** that computer's key isn't in Gitea, or ssh offers another one. `ssh -vT -p 2222 git@git.<domain>` shows which keys it tries.
- **"REMOTE HOST IDENTIFICATION HAS CHANGED"** after a rebuild without the old `app` folder (new host key): `ssh-keygen -R "[git.<domain>]:2222"`, then connect again. A normal restore keeps the key.
- **Off the LAN without Tailscale**, `git.<domain>` reaches the public entrypoint, which answers 404 while Gitea is internal.
