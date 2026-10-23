#!/usr/bin/env bash
# Deploy the stacks that changed since the last good deploy (R5). The deploy workflow runs it on
# the self-hosted runner once validate passes; it can be run by hand the same way.
# Per stack: env check → DB dump → pull → up --wait. If that fails, the stack's files from the last
# good deploy are put back for a redeploy, then restored, and the run fails.
# The last good deploy is the local ref refs/homelab/deployed. It moves only when every stack
# succeeds, so the next run retries whatever failed or was skipped.
# Usage: scripts/deploy.sh [--dry-run] <commit>   fast-forward to <commit> (must be on origin/main) and deploy
#        scripts/deploy.sh --mark <commit>        record <commit> as deployed (first setup, manual deploys)
# Env: DEPLOY_WAIT_TIMEOUT (seconds per stack, default 300)
set -euo pipefail

main() {
  cd "$(dirname "$0")/.."
  REF=refs/homelab/deployed
  WAIT=${DEPLOY_WAIT_TIMEOUT:-300}
  dry=0; [[ ${1:-} == --dry-run ]] && { dry=1; shift; }
  if [[ ${1:-} == --mark ]]; then
    git update-ref "$REF" "$(git rev-parse --verify "${2:?usage: --mark <commit>}^{commit}")"
    echo "Marked $(short "$REF") as deployed"; return
  fi
  target=${1:?usage: scripts/deploy.sh [--dry-run] <commit> | --mark <commit>}

  exec 9>"$(git rev-parse --git-dir)/homelab-deploy.lock"
  flock -n 9 || die "another deploy is running"

  # Guards: never deploy half-finished work from the working copy
  [[ $(git branch --show-current) == main ]] || die "the working copy isn't on main"
  git diff --quiet HEAD || die "uncommitted changes to tracked files: commit and push, or stash, then re-run"
  git fetch -q origin main
  target=$(git rev-parse --verify "$target^{commit}")
  git merge-base --is-ancestor "$target" origin/main || die "$(short "$target") isn't on origin/main"
  prev=$(git rev-parse --verify -q "$REF") \
    || die "no deploy mark: check the running stacks match a commit, then scripts/deploy.sh --mark <commit>"
  if git merge-base --is-ancestor "$target" "$prev"; then echo "Already deployed: $(short "$prev")"; return; fi
  git merge-base --is-ancestor HEAD "$target" || die "local commits not in $(short "$target"): push them first"
  (( dry )) || git merge -q --ff-only "$target"
  echo "Deploying $(short "$prev")..$(short "$target")"

  # Traefik first: it creates the proxy network the others join. README changes deploy nothing.
  local stacks
  stacks=$(git diff --name-only "$prev" "$target" -- services | { grep -v '\.md$' || true; } | cut -d/ -f2 | sort -u \
    | awk '$0=="traefik"{print; next} {rest=rest $0 "\n"} END{printf "%s", rest}')
  git diff --quiet "$prev" "$target" -- nas || echo "NOTE nas/ changed: redeploy it in Portainer by hand"
  [[ -n $stacks ]] || echo "No stack changed"

  local status=0 s
  for s in $stacks; do
    if [[ ! -f services/$s/compose.yaml ]]; then
      echo "WARN $s: removed from the repo; take its containers down by hand"; continue
    fi
    echo "== $s"
    if deploy_stack "$s"; then echo "OK   $s"; else status=1; fi
  done

  if (( status )); then echo "FAIL deploy mark stays at $(short "$prev"): the next run retries"; return 1; fi
  if (( dry )); then echo "Dry run: nothing deployed"; return; fi
  git update-ref "$REF" "$target"
  echo "Deployed $(short "$target")"
}

die() { echo "FAIL $*"; exit 1; }
short() { git rev-parse --short "$1"; }
run() { if (( dry )); then echo "     would run: $*"; else "$@"; fi; }
compose() { docker compose -f "services/$1/compose.yaml" "${@:2}"; }

# Services that bind-mount a changed file (not a folder): a mounted file is only read at start
file_mounts() {
  local changed
  changed=$(git diff --name-only "$prev" "$target" -- "services/$1" | sed "s|^|$PWD/|")
  compose "$1" config --format json | jq -r '.services | to_entries[] | .key as $s
    | .value.volumes[]? | select(.type == "bind") | "\($s) \(.source)"' \
    | while read -r svc src; do
        [[ -f $src ]] && grep -qxF "$src" <<<"$changed" && echo "$svc"
      done | sort -u
}

up() {
  local s=$1 svcs
  svcs=$(file_mounts "$s" | xargs)
  # Recreate those first: a plain up would wait on their old containers (unhealthy in a rollback)
  [[ -z $svcs ]] || run compose "$s" up -d --wait --wait-timeout "$WAIT" --force-recreate $svcs || return 1
  run compose "$s" up -d --wait --wait-timeout "$WAIT"
}

deploy_stack() {
  local s=$1 dbs out
  out=$(scripts/check-env.sh "$s") || { echo "$out"; return 1; }
  dbs=$(docker ps --filter label=homelab.backup.db=true --filter "label=com.docker.compose.project=$s" \
    --format '{{.Names}}' | xargs)
  [[ -z $dbs ]] || run scripts/backup-db.sh $dbs || { echo "FAIL $s: dump failed, not deployed"; return 1; }
  run compose "$s" pull --quiet || { echo "FAIL $s: pull failed, not deployed"; return 1; }
  up "$s" && return 0
  compose "$s" ps --all --format 'table {{.Service}}\t{{.Status}}'
  echo "FAIL $s: not healthy (docker compose logs in services/$s)"
  rollback "$s"
  return 1
}

rollback() {
  local s=$1
  if ! git cat-file -e "$prev:services/$s/compose.yaml" 2>/dev/null; then
    echo "FAIL $s: new stack, nothing to roll back to (left as is)"; return
  fi
  echo "ROLLBACK $s to $(short "$prev")"
  git restore --source="$prev" --worktree -- "services/$s"
  if up "$s"; then echo "OK   $s rolled back"
  else echo "FAIL $s: rollback unhealthy too. Fix by hand, then: docker compose up -d --force-recreate"; fi
  # Files back to HEAD; containers keep the old config until recreated (fix forward soon)
  git restore --worktree -- "services/$s"
}

main "$@"
