#!/bin/zsh --no-rcs
# Publishes the website: the committed site/ (git archive, so nothing stray on disk ships) to the Cloudflare Pages
# project remora-site. HEAD's branch decides where: main is production (remora.open-paren.dev), any other branch a
# preview (<branch>.remora-site.pages.dev); BRANCH=main publishes another branch as production. Needs `npx wrangler login` once.
set -eu
cd "$(dirname "$0")/.."
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
git archive HEAD site | tar -x -C "$tmp"
branch=${BRANCH:-$(git rev-parse --abbrev-ref HEAD)} commit=$(git rev-parse HEAD)
cd "$tmp"  # outside the repo: wrangler's autoconfig would otherwise write a wrangler.jsonc into it
npx --yes wrangler@4 pages deploy site --project-name remora-site --branch "$branch" --commit-hash "$commit"
