# Owned Fork Productisation Design

## Goal

Turn `jacobcxdev/XcodesApp` into Jacob Clayden's maintained, signed, independently releasable Xcodes distribution while preserving `Xcodes.app` as a user-facing drop-in replacement and keeping clean routes for upstream contributions.

## Source-Control Model

- `origin/main` is product authority for fork identity, packaging, CI, releases, documentation, and fork-only features.
- `upstream` fetches `https://github.com/XcodesOrg/XcodesApp.git`; its push URL is disabled locally.
- `jacobcxdev/<topic>` branches start from `origin/main` for normal fork work.
- `upstream/<topic>` branches start from `upstream/main`, contain only portable commits, and are pushed to `origin` for pull requests into `XcodesOrg/XcodesApp`.
- `sync/upstream-YYYYMMDD` branches integrate upstream changes into owned `main` through review.
- `FORKING.md` records exact commands and invariants. No generated overlay hides fork identity from `main`.

## Product Identity

Visible product remains `Xcodes` and installs as `/Applications/Xcodes.app`. Fork-owned technical identity becomes:

- application bundle ID: `dev.jacobcx.Xcodes`
- privileged helper ID and Mach service: `dev.jacobcx.Xcodes.Helper`
- test bundle ID: `dev.jacobcx.Xcodes.Tests`
- Keychain service: `dev.jacobcx.Xcodes`
- application-support directory: `~/Library/Application Support/dev.jacobcx.Xcodes`
- cache directory: `~/Library/Caches/dev.jacobcx.Xcodes`
- Apple Developer Team ID: `K2648T24P4`
- copyright: original MIT copyright remains, with `Copyright © 2026 Jacob Clayden` added for fork work

All helper code requirements use fork bundle IDs and the signing certificate organisational unit supplied by Xcode. Existing upstream helper is never silently deleted.

## Safe Migration

First launch under fork bundle ID performs an idempotent, allowlisted migration from `com.xcodesorg.xcodesapp` defaults before caches or settings load.

Migrated values are non-secret preferences only: install/cache paths, download/data-source choices, runtime and list presentation, selection actions, update preferences, and automatic-install settings. `username`, cookies, Apple credentials, updater state, and arbitrary unknown keys are excluded.

If upstream has no saved `localPath` but its legacy application-support directory exists, migration records that directory as `localPath` so downloaded archives and metadata remain reusable. Fresh installs use fork-owned support and cache directories. New Keychain service starts empty, requiring Apple sign-in. Helper installation remains explicit because bundle ID, Mach service, and signing requirement changed.

Migration writes a versioned marker only after copied values are committed. Existing fork values win over legacy values. Failures leave marker unset so a later launch can retry.

## Repository and User-Facing Ownership

- README identifies repository as maintained fork, credits XcodesOrg and prior contributors, links fork releases/issues, and documents upstream relationship.
- `CODEOWNERS`, contribution links, issue templates, release drafter, app About/menu links, copyright, homepage, and release instructions point to `jacobcxdev/XcodesApp`.
- Original MIT licence text remains intact. Fork copyright is appended, never substituted.
- Upstream donation, social, release, and Homebrew claims are removed from fork installation instructions unless fork-owned equivalents exist.
- Initial supported install path is signed ZIP from fork GitHub Releases. Homebrew remains future work until fork owns a tap/cask.

## Signing, Updates, and Packaging

Release builds use `Developer ID Application: Jacob Clayden (K2648T24P4)`. Debug/Test keep automatic Apple Development signing for team `K2648T24P4`; unsigned CI explicitly disables signing.

Fork gets a distinct Sparkle EdDSA keypair. Public key is committed in `Info.plist`; private key stays in local Keychain and GitHub Actions secret only. Feed URLs become:

- `https://jacobcxdev.github.io/XcodesApp/appcast.xml`
- `https://jacobcxdev.github.io/XcodesApp/appcast_pre.xml`

Packaging is one script used locally and by CI. It archives, exports Developer ID app, verifies nested signatures and helper requirements, submits ZIP to Apple notary service, requires Accepted status, staples ticket, validates with `stapler`, `codesign`, and `spctl`, creates deterministic release ZIP, and signs update with Sparkle. Temporary keychains and API-key files are cleaned on success, failure, and cancellation.

## CI and Release Flow

Pull requests and pushes to `main` run unsigned Debug build, full tests, localization validation, identity checks, and shell syntax checks. Release workflow runs only for version tags matching `v<marketing-version>b<build>` and requires protected `release` environment.

Release workflow consumes these secrets without logging values:

- `DEVELOPER_ID_APPLICATION_P12_BASE64`
- `DEVELOPER_ID_APPLICATION_P12_PASSWORD`
- `RELEASE_KEYCHAIN_PASSWORD`
- `APP_STORE_CONNECT_API_KEY_ID`
- `APP_STORE_CONNECT_API_ISSUER_ID`
- `APP_STORE_CONNECT_API_PRIVATE_KEY`
- `SPARKLE_PRIVATE_KEY`

Workflow validates tag against built `CFBundleShortVersionString` and `CFBundleVersion`, packages and notarizes app, creates GitHub release with `Xcodes.zip`, includes Sparkle signature in release notes, then rebuilds and deploys appcast to `gh-pages`. Release or appcast publication fails closed when signature, notarization, tag, asset, or secret is missing.

## GitHub Settings Boundary

Tracked files prepare repository, but remote writes require explicit confirmation. Final handoff lists exact settings to apply: enable Issues and Actions, create protected `release` environment, install secrets, enable GitHub Pages from `gh-pages`, update homepage/description, add branch protection for `main`, and optionally enable Discussions.

## Error Handling and Security

- No secret values enter source, logs, artefacts, release notes, or migration.
- Migration copies only allowlisted property-list values.
- Different Sparkle key prevents upstream feed or release from updating fork builds.
- Different helper identity prevents upstream and fork signing requirements from being conflated.
- Release pipeline stops before publication on any verification failure.
- Local packaging refuses dirty source and mismatched tag/version.

## Verification

- Unit tests prove allowlist, destination-wins behavior, credential exclusion, legacy-cache reuse, and migration idempotence.
- Static identity check rejects remaining operational upstream bundle IDs, helper IDs, feed URLs, ownership links, or team ID outside explicit attribution/history allowlists.
- Full XCTest suite passes.
- Debug build passes with signing disabled.
- Release archive is inspected for fork app/helper IDs, team ID, code requirements, Sparkle public key/feed, and absence of upstream operational identifiers.
- Workflow YAML, plists, shell scripts, appcast XML, and project file parse successfully.

## Non-Goals

- Renaming visible app, icon, executable, or `/Applications/Xcodes.app`.
- Migrating Apple passwords, cookies, Keychain items, installed privileged helper, or Sparkle state.
- Publishing release, changing GitHub settings, or creating Homebrew cask without separate remote-write confirmation.
- Forking XcodesKit/XcodesLoginKit solely to replace historical dependency namespaces.
