#!/usr/bin/env bash
# R1: replace <public clone> with <commit>'s tracked files minus .publicignore, then commit it as
# one snapshot (no private history). Refuses if any file name or content matches PUBLIC_DENYLIST
# (one extended regex per line, case-insensitive; a GitHub secret in CI). The workflow pushes.
# Dry run: PUBLIC_DENYLIST=... scripts/publish-public.sh HEAD "$(mktemp -d)" (after git init there).
set -euo pipefail
usage="usage: publish-public.sh <commit> <public clone>"
commit=$(git rev-parse --verify "${1:?$usage}^{commit}")
dir=${2:?$usage}
[[ -d $dir/.git ]] || { echo "ERROR: $dir is not a git clone"; exit 1; }

patterns=$(mktemp); trap 'rm -f "$patterns"' EXIT
# Blank lines would match everything
printf '%s\n' "${PUBLIC_DENYLIST:-}" | tr -d '\r' | grep -v '^[[:space:]]*$' > "$patterns" || true
[[ -s $patterns ]] || { echo "ERROR: PUBLIC_DENYLIST is empty"; exit 1; }

excludes=()
while IFS= read -r line; do
  [[ -z $line || $line == \#* ]] || excludes+=(":(exclude)${line%/}")
done < <(git show "$commit:.publicignore")

find "$dir" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +
git archive "$commit" -- . "${excludes[@]}" | tar -x -C "$dir"

# File names only: the log must not echo what matched
hits=$(cd "$dir" && { grep -rliE -f "$patterns" --exclude-dir=.git . || true
  find . -path ./.git -prune -o -print | grep -iE -f "$patterns" || true; } | sort -u)
if [[ -n $hits ]]; then
  echo "ERROR: denylisted text in:"; sed 's/^/  /' <<<"$hits"; exit 1
fi

git -C "$dir" symbolic-ref HEAD refs/heads/main  # names the branch in a new, empty repo
git -C "$dir" add -A
if git -C "$dir" diff --cached --quiet; then
  echo "Public repo already matches ${commit:0:12}"; exit 0
fi
git -C "$dir" -c user.name='github-actions[bot]' \
  -c user.email='41898282+github-actions[bot]@users.noreply.github.com' \
  commit -q -m "Publish ${commit:0:12}"
git -C "$dir" diff --stat HEAD~1 2>/dev/null | tail -1 || echo "First publish"
echo "Committed snapshot of ${commit:0:12}"
