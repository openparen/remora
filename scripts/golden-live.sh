#!/usr/bin/env bash
# Diff Remora's SVG against rm2agent's, page by page, for real notebooks.
# usage: scripts/golden-live.sh "<rm2agent path>"...
# Needs rm2agent and jq on PATH and a paired remora-cli. Output stays in
# golden-out/ (gitignored): it is your own handwriting, never commit it.
# Each run mints a session token per tool and document; reMarkable rate-limits
# that exchange, so check a few documents at a time.
set -euo pipefail
out=${GOLDEN_OUT:-golden-out}
status=0
swift build --package-path RMKit -c release --product remora-cli >/dev/null
cli=$(swift build --package-path RMKit -c release --show-bin-path)/remora-cli
for doc in "$@"; do
  manifest=$(rm2agent export "$doc" --format svg --out "$out/rm2agent" --json)
  id=$(jq -r .id <<<"$manifest")
  "$cli" svg "$id" "$out/remora/$id" >/dev/null
  while IFS=$'\t' read -r page svg; do
    if cmp -s "$svg" "$out/remora/$id/$page.svg"; then
      echo "same  $doc  $page"
    else
      echo "DIFF  $doc  $page"
      status=1
    fi
  done < <(jq -r '.pages[] | select(.svg) | [.pageId, .svg] | @tsv' <<<"$manifest")
done
exit $status
