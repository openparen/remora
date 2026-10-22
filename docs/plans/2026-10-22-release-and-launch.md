# Remora releases and launch

**Date:** 2026-10-22
**Status:** Agreed with the user. Not built yet.
**Design:** `2026-10-21-remora-design.md` ("later notarized and distributed as a DMG", "private until v1").

The repo lives in the `open-paren` GitHub organization (moved from `gveres` before going public); the bundle id stays `io.github.gveres.remora`, since changing it would orphan Keychain items and settings.

GitHub is the distribution platform: notarized DMGs on GitHub releases, plus a Homebrew cask. The announcement is kept small: the app is only useful to reMarkable owners, so it goes only where they are.

## 1. A notarizable build

- `project.yml` sets `ENABLE_HARDENED_RUNTIME: NO`. Notarization requires `YES`. The app isn't sandboxed and shouldn't need entitlements; check that Keychain access and `rmr://` links still work after the switch.
- The version lives in `project.yml` (`MARKETING_VERSION`, `CURRENT_PROJECT_VERSION`). A release bumps both and is tagged `v<MARKETING_VERSION>`, e.g. `v0.1.0`.
- Notarization is required, not optional: Gatekeeper blocks an unnotarized download, and Homebrew disables casks that fail Gatekeeper.

## 2. `scripts/release.sh`

Run locally, with the user's Developer ID (`REMORA_SIGN_IDENTITY`, `REMORA_TEAM`), as `build-app.sh` already supports. It:

1. builds with `scripts/build-app.sh Release`;
2. packs `Remora-<version>.dmg` with `hdiutil create`;
3. notarizes it with `xcrun notarytool submit --wait`, using a Keychain profile stored once with `notarytool store-credentials`, then staples it with `xcrun stapler staple`;
4. publishes it with `gh release create v<version> Remora-<version>.dmg --generate-notes`;
5. updates the cask's `version` and `sha256` in the tap and pushes it.

The script refuses to run on a dirty tree or when the tag already exists.

Not in CI: that would put the signing certificate into repo secrets, for no gain while one person releases.

## 3. Homebrew

- Our own tap first: `open-paren/homebrew-tap`, with `Casks/remora.rb`.
  - `url` is the release DMG, plus its `sha256`;
  - `depends_on macos: ">= :tahoe"` (macOS 26);
  - `app "Remora.app"`;
  - `zap` removes `~/Library/Caches/Remora`.
- Install line: `brew install --cask open-paren/tap/remora`.
- `homebrew/cask` later, once the repo meets its notability bar (roughly 75 stars, or 30 forks or watchers). The cask file carries over almost unchanged.

## 4. Before going public

- README:
  - one GIF: write on the tablet, the page updates in Remora, Copy Link, paste into a note, click it;
  - the install line (brew, or the DMG from releases);
  - requirements: macOS 26+, a reMarkable Connect subscription;
  - "Not affiliated with reMarkable AS".
- A privacy paragraph: the app talks only to reMarkable's cloud, keeps the device token in Keychain, and has no telemetry.
- A risk note: it uses reMarkable's unofficial cloud API, which can change.
- Issues stay open for feedback.
- `gh repo edit open-paren/remora --visibility public`.

## 5. Website: remora.open-paren.dev

The same shape and look as zyz's site (`zyz/docs/plans/2026-10-19-website-design.md`): hand-written HTML and CSS in `site/`, no build step, no JavaScript, no analytics, the self-hosted Newsreader serif, light and dark. Its own accent, a sea teal.

- `site/index.html` describes only what the app does today. It covers the hero, why I built it, a link to every page, live while you write, everything on the tablet, privacy, install, and open source. The footer carries the trademark disclaimer.
- Privacy and support are not separate pages: privacy is a section of the landing page, and support goes through GitHub issues and hello@open-paren.dev.
- Until the first release, the call to action is "Open source, coming soon" plus a mailto. At release it becomes the brew line and a link to the latest release.
- `scripts/deploy-site.sh` uploads the committed `site/` to the Cloudflare Pages project `remora-site`. `main` deploys to production; other branches get preview URLs.

Launch (owner):
1. `npx wrangler pages project create remora-site --production-branch main`, then `scripts/deploy-site.sh` on `main`.
2. In the Pages project: Custom domains → remora.open-paren.dev.
3. At name.com: a CNAME `remora` → `remora-site.pages.dev`.

Still missing, and needed before the announcement:
- Screenshots and the GIF. They come from a purpose-made fixtures notebook and PDF, never the owner's own library.
- The app icon, which also gives the favicon.
- An Open Graph image.

## 6. Announcement

- One post on r/RemarkableTablet, GIF first: "built this for myself, open source, feedback welcome".
- A PR adding Remora to the awesome-reMarkable list.
- Show HN only with a technical write-up (the `.rm` format, the sync v3/v4 protocol, the content-addressed cache), because that's interesting without the device.
- Not: r/macapps or other general Mac channels. Without the tablet the app is useless.
- Never "reMarkable" in the app's name or icon, or anything that looks official. "For reMarkable" in posts is fine.

## Skipped

- In-app updates (Sparkle): `brew upgrade` and GitHub's release notifications cover it. Add them if DMG users ask.
- Download analytics: GitHub's per-release download counts are enough.
