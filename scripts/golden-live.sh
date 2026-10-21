#!/usr/bin/env bash
# Diff Remora's SVG against rm2agent's, page by page, for real notebooks.
# usage: scripts/golden-live.sh "<rm2agent path>"...
# Needs rm2agent and jq on PATH and a paired remora-cli. Output stays in
# golden-out/ (gitignored): it is your own handwriting, never commit it.
# A relative GOLDEN_OUT resolves against the repo root, not your cwd.
# Each run mints a session token per tool and document; reMarkable rate-limits
# that exchange, so check a few documents at a time.
set -euo pipefail
cd "$(dirname "$0")/.."

if [ "$#" -eq 0 ]; then
  echo "usage: scripts/golden-live.sh \"<rm2agent path>\"..." >&2
  exit 2
fi

out=${GOLDEN_OUT:-golden-out}
status=0

swift build --package-path RMKit -c release --product remora-cli
cli=$(swift build --package-path RMKit -c release --show-bin-path)/remora-cli

pages_file=$(mktemp)
trap 'rm -f "$pages_file"' EXIT

for doc in "$@"; do
  manifest=$(rm2agent export "$doc" --format svg --out "$out/rm2agent" --json)
  id=$(jq -r .id <<<"$manifest")
  # the document id is server data and feeds an rm -rf: refuse anything but a plain id
  [[ $id =~ ^[A-Za-z0-9-]+$ ]] || { echo "bad document id: $id" >&2; exit 1; }

  rm -rf "$out/remora/$id"
  "$cli" svg "$id" "$out/remora/$id" >/dev/null

  # into a temp file, not a process substitution: a jq failure must trip set -e
  jq -r '.pages[] | select(.svg) | [.pageId, .svg] | @tsv' <<<"$manifest" >"$pages_file"

  compared=0
  while IFS=$'\t' read -r page svg; do
    compared=$((compared + 1))
    if cmp -s "$svg" "$out/remora/$id/$page.svg"; then
      echo "same  $doc  $page"
    else
      echo "DIFF  $doc  $page"
      status=1
    fi
  done <"$pages_file"

  if [ "$compared" -eq 0 ]; then
    echo "NONE  $doc"
    status=1
  fi

  for rendered in "$out/remora/$id"/*.svg; do
    [ -e "$rendered" ] || continue
    page=$(basename "$rendered" .svg)
    if ! cut -f1 "$pages_file" | grep -qxF "$page"; then
      echo "EXTRA  $doc  $page"
      status=1
    fi
  done
done

exit $status
