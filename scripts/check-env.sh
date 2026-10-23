#!/usr/bin/env bash
# Check each service's .env against its .env.sample. Prints key names only, never values.
# Usage: scripts/check-env.sh [service ...]   (default: all services)
set -euo pipefail
cd "$(dirname "$0")/.."

keys() { grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$1" | cut -d= -f1 | sort -u; }

if [[ $# -gt 0 ]]; then services=("$@"); else
  services=(); for d in services/*/; do services+=("$(basename "$d")"); done
fi

status=0
for s in "${services[@]}"; do
  sample="services/$s/.env.sample"; env="services/$s/.env"
  [[ -f $sample ]] || continue
  if [[ ! -f $env ]]; then
    echo "FAIL $s: no .env (copy .env.sample and fill it in)"; status=1; continue
  fi
  missing=$(comm -23 <(keys "$sample") <(keys "$env") | xargs)
  extra=$(comm -13 <(keys "$sample") <(keys "$env") | xargs)
  placeholder=$(grep -E '^[A-Za-z_][A-Za-z0-9_]*=.*changeme' "$env" | cut -d= -f1 | xargs || true)
  if [[ -n $missing || -n $placeholder ]]; then
    status=1
    [[ -n $missing ]] && echo "FAIL $s: missing $missing"
    [[ -n $placeholder ]] && echo "FAIL $s: still 'changeme': $placeholder"
  else
    echo "OK   $s"
  fi
  [[ -n $extra ]] && echo "WARN $s: not in .env.sample: $extra"
done
exit $status
