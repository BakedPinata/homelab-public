#!/usr/bin/env bash
# Repo checks (R4). CI runs this on every push and PR; run it locally before pushing.
# Each stack must resolve with only its .env.sample (a key missing from the sample fails),
# every image must be pinned, and yamllint must pass. gitleaks runs separately
# (pre-commit hook locally, its own step in CI).
set -euo pipefail
cd "$(dirname "$0")/.."

status=0
for f in services/*/compose.yaml nas/*/compose.yaml; do
  d=$(dirname "$f"); args=(-f "$f"); ok=1
  [[ -f $d/.env.sample ]] && args+=(--env-file "$d/.env.sample")
  if ! out=$(docker compose "${args[@]}" config -q 2>&1) || [[ -n $out ]]; then
    echo "FAIL $d: compose config"; sed 's/^/     /' <<<"$out"; status=1; continue
  fi
  while read -r img; do
    if [[ ! $img =~ :[^/]+$ || $img =~ :(latest|stable)$ ]]; then
      echo "FAIL $d: image not pinned: $img"; ok=0; status=1
    fi
  done < <(docker compose "${args[@]}" config --images)
  [[ $ok == 1 ]] && echo "OK   $d"
done

if yamllint --strict .; then echo "OK   yamllint"; else echo "FAIL yamllint"; status=1; fi
exit $status
