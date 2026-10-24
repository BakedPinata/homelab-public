#!/usr/bin/env bash
# Build the recovery pack (R23): docs/disaster-recovery.template.md filled in from every
# services/*/.env and dr.env (scripts/make-dr-pdf.lua), rendered to a PDF in out/.
# pandoc and mermaid-cli run in Docker, with no network. The PDF holds every secret:
# print it, then delete it.
# Usage: scripts/make-dr-pdf.sh [--sample]   --sample uses the .env.sample files and dr.env.sample
set -euo pipefail
cd "$(dirname "$0")/.."

PANDOC_IMAGE=pandoc/latex:3.11.0.0-debian
MERMAID_IMAGE=minlag/mermaid-cli:12.0.1

sample=0; [[ ${1:-} == --sample ]] && sample=1
date=$(date +%F)
commit=$(git rev-parse --short HEAD)$(git diff --quiet HEAD || echo -dirty)
if (( sample )); then
  pdf=out/disaster-recovery-sample.pdf
else
  [[ -f dr.env ]] || { echo "No dr.env: copy dr.env.sample to dr.env and fill it in"; exit 1; }
  if ! out=$(scripts/check-env.sh); then grep -v '^OK' <<<"$out"; echo "Fix the .env files first"; exit 1; fi
  pdf=out/disaster-recovery-$date.pdf
fi

umask 077
build=out/.dr-build
rm -rf "$build"; mkdir -p "$build"
trap 'rm -rf "$build"' EXIT
run=(docker run --rm --network none -u "$(id -u):$(id -g)")

# Mermaid blocks → PNGs. Only the template goes in here, never a value.
"${run[@]}" -v "$PWD/docs:/docs:ro" -v "$PWD/$build:/build" "$MERMAID_IMAGE" \
  -q -i /docs/disaster-recovery.template.md -o /build/pack.md -e png -s 2 -b white

"${run[@]}" -e HOME=/tmp -e DR_SAMPLE="$sample" -e DR_DATE="$date" -e DR_COMMIT="$commit" \
  -v "$PWD:/repo:ro" -v "$PWD/out:/out" -w "/out/.dr-build" "$PANDOC_IMAGE" pack.md \
  -f markdown --lua-filter /repo/scripts/make-dr-pdf.lua --pdf-engine=xelatex --toc --toc-depth=2 \
  -V papersize=a4 -V geometry:margin=2cm -V fontsize=11pt -V colorlinks=true \
  -V mainfont="DejaVu Sans" -V monofont="DejaVu Sans Mono" -o "/out/${pdf#out/}"
chmod 600 "$pdf"

echo "Wrote $pdf"
(( sample )) || echo "It holds every password and key: print it, store the copies, then delete the file."
