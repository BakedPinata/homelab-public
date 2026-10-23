#!/usr/bin/env bash
# R1: bring public PR <n> into the private repo as branch public-pr-<n> and a private PR,
# keeping the contributor as author. Nothing from the PR is run here; validate runs on the
# private PR. Review it like your own change: merging deploys. Leaves ~/homelab on main.
set -euo pipefail
n=${1:?usage: import-pr.sh <public PR number>}
[[ $n =~ ^[0-9]+$ ]] || { echo "ERROR: $n is not a PR number"; exit 1; }
cd "$(git rev-parse --show-toplevel)"

private=$(gh repo view --json nameWithOwner -q .nameWithOwner)
public=$private-public
branch=public-pr-$n
[[ -z $(git status --porcelain --untracked-files=no) ]] || { echo "ERROR: uncommitted changes"; exit 1; }
[[ $(git branch --show-current) == main ]] || { echo "ERROR: not on main"; exit 1; }
! git rev-parse -q --verify "refs/heads/$branch" >/dev/null || { echo "ERROR: branch $branch exists"; exit 1; }

read -r url title < <(gh pr view "$n" --repo "$public" --json url,title -q '.url + " " + .title')
files=$(gh pr diff "$n" --repo "$public" --name-only)
echo "Public PR #$n: $title"; sed 's/^/  /' <<<"$files"

# Excluded paths don't exist publicly; a PR adding one would sneak it past the filter
excluded=$(grep -v -e '^#' -e '^$' .publicignore)
while IFS= read -r f; do
  while IFS= read -r e; do
    if [[ $f == "$e" || ($e == */ && $f == "$e"*) ]]; then
      echo "ERROR: $f is in .publicignore"; exit 1
    fi
  done <<<"$excluded"
done <<<"$files"

if review=$(grep -E '^(scripts/|\.github/|\.githooks/|renovate\.json5$)' <<<"$files"); then
  echo "REVIEW CLOSELY (runs on the server or in CI):"; sed 's/^/  /' <<<"$review"
fi

patch=$(mktemp); trap 'rm -f "$patch"; git switch -q main' EXIT
gh pr diff "$n" --repo "$public" --patch > "$patch"
git fetch -q origin main
git switch -q -c "$branch" origin/main
if ! git am -q --3way "$patch"; then
  git am --abort; git switch -q main; git branch -q -D "$branch"
  echo "ERROR: PR doesn't apply to main. Ask the contributor to rebase on the public main."; exit 1
fi
git push -q -u origin "$branch"
gh pr create --head "$branch" --base main --title "$title" \
  --body "Imported from public PR $url with \`scripts/import-pr.sh $n\`."
echo "After merging, close the public PR: gh pr close $n --repo $public --comment 'Merged, thanks! It will appear in the next publish.'"
