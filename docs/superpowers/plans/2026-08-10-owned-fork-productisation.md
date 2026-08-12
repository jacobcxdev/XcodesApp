# Owned Fork Productisation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `jacobcxdev/XcodesApp` an independently signed, updated, packaged, tested, and maintained Xcodes distribution with a clean upstream-contribution lane.

**Architecture:** Keep visible `Xcodes.app` compatibility while replacing operational upstream identity with `dev.jacobcx` identifiers. Use an allowlisted first-launch preference migration, one local/CI release script, tag-driven GitHub release automation, fork-owned Sparkle feed, and documented dual-lane Git workflow.

**Tech Stack:** Swift 6, SwiftUI, XCTest, Xcode 27, SMJobBless helper, Sparkle 2, Bash, GitHub Actions, Apple notarytool, GitHub Pages.

---

### Task 1: Fork identity contract

**Files:**
- Create: `Scripts/check_fork_identity.sh`
- Modify: `Xcodes.xcodeproj/project.pbxproj`
- Rename: `com.xcodesorg.xcodesapp.Helper/` to `dev.jacobcx.Xcodes.Helper/`
- Rename: `Xcodes.xcodeproj/xcshareddata/xcschemes/com.robotsandpencils.XcodesApp.Helper.xcscheme`
- Modify: `HelperXPCShared/HelperXPCShared.swift`
- Modify: `Scripts/uninstall_privileged_helper.sh`
- Modify: `Xcodes/Resources/Info.plist`

- [ ] **Step 1: Write identity guard**

Create executable shell check that requires:

```bash
#!/bin/bash
set -euo pipefail

readonly app_id="dev.jacobcx.Xcodes"
readonly helper_id="dev.jacobcx.Xcodes.Helper"
readonly team_id="K2648T24P4"

rg -q "PRODUCT_BUNDLE_IDENTIFIER = ${app_id};" Xcodes.xcodeproj/project.pbxproj
rg -q "PRODUCT_BUNDLE_IDENTIFIER = ${helper_id};" Xcodes.xcodeproj/project.pbxproj
rg -q "DEVELOPMENT_TEAM = ${team_id};" Xcodes.xcodeproj/project.pbxproj
rg -q "let machServiceName = \"${helper_id}\"" HelperXPCShared/HelperXPCShared.swift
rg -q "let clientBundleID = \"${app_id}\"" HelperXPCShared/HelperXPCShared.swift

if rg -n "com\\.xcodesorg\\.xcodesapp|com\\.robotsandpencils\\.XcodesApp" \
    Xcodes.xcodeproj HelperXPCShared dev.jacobcx.Xcodes.Helper Scripts/uninstall_privileged_helper.sh Xcodes/Resources/Info.plist; then
  echo "Operational upstream identity remains" >&2
  exit 1
fi
```

- [ ] **Step 2: Run guard and verify red**

Run: `bash Scripts/check_fork_identity.sh`

Expected: non-zero because project still uses upstream IDs and team.

- [ ] **Step 3: Replace product and helper identity**

Apply exact replacements throughout project, helper source, launchd plist, schemes, and scripts:

```text
com.xcodesorg.xcodesapp.Helper -> dev.jacobcx.Xcodes.Helper
com.xcodesorg.xcodesapp.XcodesAppTests -> dev.jacobcx.Xcodes.Tests
com.xcodesorg.xcodesapp -> dev.jacobcx.Xcodes
com.robotsandpencils.XcodesApp.Helper -> dev.jacobcx.Xcodes.Helper
ZU6GR6B2FY -> K2648T24P4
```

Rename helper target, product, directory, bridging header, test entitlement file, and scheme to match `dev.jacobcx.Xcodes.Helper`. Preserve visible app target/product name `Xcodes`.

- [ ] **Step 4: Verify project and guard**

Run:

```bash
plutil -lint Xcodes/Resources/Info.plist dev.jacobcx.Xcodes.Helper/Info.plist dev.jacobcx.Xcodes.Helper/launchd.plist
xcodebuild -list -json -project Xcodes.xcodeproj | jq -e '.project.targets | index("dev.jacobcx.Xcodes.Helper")'
bash Scripts/check_fork_identity.sh
```

Expected: all exit zero.

- [ ] **Step 5: Commit identity**

```bash
git add Xcodes.xcodeproj HelperXPCShared dev.jacobcx.Xcodes.Helper Scripts/check_fork_identity.sh Scripts/uninstall_privileged_helper.sh Xcodes/Resources/Info.plist
git commit -m "feat: adopted fork product identity" -m $'- moved app and helper into `dev.jacobcx` namespace\n- switched signing settings to owned developer team\n- added executable identity guard'
```

### Task 2: Safe preference and storage migration

**Files:**
- Modify: `Xcodes/Backend/AppState.swift`
- Modify: `Xcodes/Backend/Environment.swift`
- Modify: `Xcodes/Backend/Path+.swift`
- Modify: `XcodesTests/AppStateTests.swift`

- [ ] **Step 1: Write failing migration tests**

Add tests for allowlisted values, destination-wins, secret exclusion, legacy-cache reuse, and marker idempotence using isolated `UserDefaults` suites:

```swift
func test_ForkPreferenceMigration_CopiesAllowlistedValuesButNotUsername() {
    let defaults = isolatedDefaults()
    ForkPreferenceMigration().migrate(
        legacyValues: ["installPath": "/Applications", "username": "secret@example.com"],
        legacyApplicationSupportExists: false,
        into: defaults
    )
    XCTAssertEqual(defaults.string(forKey: "installPath"), "/Applications")
    XCTAssertNil(defaults.string(forKey: "username"))
}

func test_ForkPreferenceMigration_PreservesExistingForkValue() {
    let defaults = isolatedDefaults()
    defaults.set("/Fork", forKey: "localPath")
    ForkPreferenceMigration().migrate(
        legacyValues: ["localPath": "/Upstream"],
        legacyApplicationSupportExists: true,
        into: defaults
    )
    XCTAssertEqual(defaults.string(forKey: "localPath"), "/Fork")
}
```

- [ ] **Step 2: Run tests and verify red**

Run: `xcodebuild test -quiet -project Xcodes.xcodeproj -scheme Xcodes -configuration Test -only-testing:XcodesTests/AppStateTests/test_ForkPreferenceMigration`

Expected: compile failure because `ForkPreferenceMigration` does not exist.

- [ ] **Step 3: Implement migration and fork storage**

Add `ForkPreferenceMigration` with marker `dev.jacobcx.Xcodes.preferenceMigrationVersion`, version `1`, and explicit keys from `PreferenceKey` plus `terminateAfterLastWindowClosed`. Exclude `username` and unknown values. Existing destination values win. When no `localPath` exists and legacy support exists, use `~/Library/Application Support/com.robotsandpencils.XcodesApp`.

Call migration at start of production `AppState.init` before loading caches. Change Apple-account Keychain service to `dev.jacobcx.Xcodes.apple-account`. Fresh defaults become:

```swift
Path.applicationSupport/"dev.jacobcx.Xcodes"
Path.caches/"dev.jacobcx.Xcodes"
```

- [ ] **Step 4: Run migration and path tests**

Run:

```bash
xcodebuild test -quiet -project Xcodes.xcodeproj -scheme Xcodes -configuration Test \
  -only-testing:XcodesTests/AppStateTests/test_ForkPreferenceMigration \
  -only-testing:XcodesTests/AppStateTests/test_ForkPaths
```

Expected: selected tests pass.

- [ ] **Step 5: Commit migration**

```bash
git add Xcodes/Backend/AppState.swift Xcodes/Backend/Environment.swift Xcodes/Backend/Path+.swift XcodesTests/AppStateTests.swift
git commit -m "feat: migrated upstream preferences safely" -m $'- copied only non-secret settings on first launch\n- preserved fork values and reusable caches\n- moved new storage and Keychain state into fork namespace'
```

### Task 3: Fork-owned links, attribution, and repository guidance

**Files:**
- Modify: `README.md`
- Modify: `CONTRIBUTING.md`
- Modify: `LICENSE`
- Create: `FORKING.md`
- Modify: `.github/CODEOWNERS`
- Modify: `.github/ISSUE_TEMPLATE/bug_report.md`
- Modify: `.github/ISSUE_TEMPLATE/feature_request.md`
- Modify: `.github/release-drafter.yml`
- Modify: `Xcodes/XcodesApp.swift`
- Modify: `Xcodes/Frontend/About/AboutView.swift`
- Modify: `Xcodes/Resources/Info.plist`

- [ ] **Step 1: Add fork ownership to identity guard and verify red**

Require `jacobcxdev/XcodesApp` in README, contribution links, app menus, About view, and release template. Reject operational `XcodesOrg/XcodesApp`, `RobotsAndPencils/XcodesApp`, upstream Homebrew release claims, upstream CODEOWNERS, and upstream homepage/feed outside `FORKING.md`, licence attribution, historical decisions, and dependency URLs.

Run: `bash Scripts/check_fork_identity.sh`

Expected: non-zero with current ownership links.

- [ ] **Step 2: Rewrite fork-facing metadata**

Keep product description and contributor credits. Add maintained-fork notice, upstream acknowledgement, fork release installation, signing/notarization statement, development requirements, and release workflow. Remove unsupported fork claims for XcodesOrg Homebrew, OpenCollective, and upstream social accounts. Use JacobCXDev for public ownership branding and CODEOWNERS `@jacobcxdev`; retain legal identity only where licensing or signing requires it.

Append fork copyright to `LICENSE` without removing original copyright.

- [ ] **Step 3: Document dual-lane workflow**

Create `FORKING.md` with exact remote and branch commands, including:

```bash
git remote add upstream https://github.com/XcodesOrg/XcodesApp.git
git remote set-url --push upstream DISABLED
git fetch upstream
git switch --create upstream/<topic> upstream/main
git push --set-upstream origin upstream/<topic>
git switch --create sync/upstream-YYYYMMDD origin/main
git merge --no-ff upstream/main
```

- [ ] **Step 4: Verify links and docs**

Run:

```bash
bash Scripts/check_fork_identity.sh
rg -n 'jacobcxdev/XcodesApp' README.md CONTRIBUTING.md Xcodes/XcodesApp.swift Xcodes/Frontend/About/AboutView.swift .github/release-drafter.yml
```

Expected: guard passes; all fork-facing locations found.

- [ ] **Step 5: Commit ownership docs**

```bash
git add README.md CONTRIBUTING.md LICENSE FORKING.md .github Xcodes/XcodesApp.swift Xcodes/Frontend/About/AboutView.swift Xcodes/Resources/Info.plist Scripts/check_fork_identity.sh
git commit -m "docs: established maintained fork ownership" -m $'- routed support and releases to fork\n- preserved upstream attribution and licence\n- documented clean upstream contribution branches'
```

### Task 4: Sparkle ownership and appcast

**Files:**
- Modify: `Xcodes/Resources/Info.plist`
- Modify: `Xcodes/Frontend/Preferences/UpdatesPreferencePane.swift`
- Modify: `AppCast/_config.yml`
- Modify: `.github/workflows/appcast.yml`
- Modify: `Scripts/check_fork_identity.sh`

- [ ] **Step 1: Generate dedicated Sparkle key**

Run local Sparkle tool with account isolation:

```bash
generate_keys --account dev.jacobcx.Xcodes
```

Store private key only in login Keychain. Capture public key for `SUPublicEDKey`; never print or export private key into repository.

- [ ] **Step 2: Point app at fork feeds**

Set stable and prerelease feeds to:

```text
https://jacobcxdev.github.io/XcodesApp/appcast.xml
https://jacobcxdev.github.io/XcodesApp/appcast_pre.xml
```

Set generated public key in `Info.plist`. Update identity guard to reject upstream feed and public key.

- [ ] **Step 3: Harden appcast workflow**

Add `contents: write`, concurrency, release-published filtering, explicit fork URL metadata, and `gh-pages` deployment. Ensure draft releases remain excluded and first ZIP asset is required.

- [ ] **Step 4: Build appcast locally**

Run:

```bash
bundle config set --local path vendor/bundle
bundle install --gemfile AppCast/Gemfile
bundle exec --gemfile AppCast/Gemfile jekyll build --source AppCast --destination /tmp/xcodesapp-appcast
xmllint --noout /tmp/xcodesapp-appcast/appcast.xml /tmp/xcodesapp-appcast/appcast_pre.xml
bash Scripts/check_fork_identity.sh
```

Expected: appcasts parse; identity guard passes.

- [ ] **Step 5: Commit updater ownership**

```bash
git add Xcodes/Resources/Info.plist Xcodes/Frontend/Preferences/UpdatesPreferencePane.swift AppCast .github/workflows/appcast.yml Scripts/check_fork_identity.sh
git commit -m "feat: moved updates to fork releases" -m $'- installed dedicated Sparkle public key\n- routed stable and prerelease feeds to fork Pages\n- prepared appcast publication from fork releases'
```

### Task 5: Reproducible signed release packaging

**Files:**
- Replace: `Scripts/package_release.sh`
- Replace: `Scripts/notarize.sh`
- Modify: `Scripts/export_options.plist`
- Create: `Scripts/test_release_scripts.sh`

- [ ] **Step 1: Write failing release-script contract checks**

Check scripts use `set -euo pipefail`, `mktemp -d`, trap cleanup, exact tag/version validation, Developer ID team `K2648T24P4`, notary Accepted validation, stapler/codesign/spctl verification, Sparkle signing, and no broad `rm -rf Archive/*` or `Product/*`.

Run: `bash Scripts/test_release_scripts.sh`

Expected: non-zero against existing scripts.

- [ ] **Step 2: Replace packaging and notarization scripts**

`package_release.sh` must:

1. Refuse dirty tracked state.
2. Validate exact `v<marketing>b<build>` tag.
3. Build in `mktemp -d`.
4. Archive/export with Developer ID and team `K2648T24P4`.
5. Verify app/helper identifiers and signatures.
6. Create submission ZIP.
7. Call `notarize.sh` with API-key environment.
8. Staple and validate ticket.
9. Re-verify `codesign --deep --strict` and `spctl -a -t install`.
10. Acquire an exclusive per-tag lock, build the complete release output in an isolated sibling staging directory, and atomically publish it as `Product/<tag>/`.
11. Write `Product/<tag>/Xcodes.zip`, `Product/<tag>/Xcodes.zip.sha256`, `Product/<tag>/sparkle-signature.txt`, and `Product/<tag>/release-manifest.txt` without overwriting an existing release directory; tag `v4.0.4b39` therefore publishes under `Product/v4.0.4b39/`.

`notarize.sh` must require API key ID, issuer, and key path; parse JSON status with `plutil`; exit unless status is `Accepted`; never delete caller artefacts.

- [ ] **Step 3: Verify scripts without signing**

Run:

```bash
bash -n Scripts/package_release.sh Scripts/notarize.sh Scripts/test_release_scripts.sh
bash Scripts/test_release_scripts.sh
plutil -lint Scripts/export_options.plist
```

Expected: all exit zero.

- [ ] **Step 4: Commit packaging**

```bash
git add Scripts/package_release.sh Scripts/notarize.sh Scripts/export_options.plist Scripts/test_release_scripts.sh
git commit -m "build: made fork releases reproducible" -m $'- unified local and CI Developer ID packaging\n- failed closed on notarization and signature checks\n- removed broad destructive build cleanup'
```

### Task 6: Owned CI and release workflows

**Files:**
- Modify: `.github/workflows/ci.yml`
- Modify: `.github/workflows/xcstrings.yml`
- Create: `.github/workflows/release.yml`
- Modify: `.github/dependabot.yml`
- Modify: `README.md`

- [ ] **Step 1: Extend workflow contract checks and verify red**

Require CI to run tests, unsigned Debug build, identity check, script contracts, plist lint, and localization. Require release workflow environment `release`, seven named secrets, temporary Keychain cleanup, package script invocation, GitHub release creation, and Sparkle signature note.

Run: `bash Scripts/check_fork_identity.sh`

Expected: non-zero because release workflow is absent.

- [ ] **Step 2: Implement CI workflow**

Use `macos-26`, select `/Applications/Xcode_26.5.app`, disable code signing, and run:

```bash
xcodebuild test -quiet -project Xcodes.xcodeproj -scheme Xcodes -configuration Test CODE_SIGNING_ALLOWED=NO
xcodebuild build -quiet -project Xcodes.xcodeproj -scheme Xcodes -configuration Debug CODE_SIGNING_ALLOWED=NO
bash Scripts/check_fork_identity.sh
bash Scripts/test_release_scripts.sh
```

- [ ] **Step 3: Implement tag-driven release workflow**

Trigger exact `vX.Y.ZbN` tags and manual dispatch. Import P12 into temporary Keychain, write API and Sparkle keys under `$RUNNER_TEMP`, invoke the package script with the exact tag, construct release notes containing `<!-- sparkle:edSignature=... -->` from `Product/<tag>/sparkle-signature.txt`, and publish `Product/<tag>/Xcodes.zip` with `gh release create`. Preserve or upload `Product/<tag>/Xcodes.zip.sha256` and `Product/<tag>/release-manifest.txt` as workflow evidence. Add `if: always()` cleanup for Keychain and key files.

- [ ] **Step 4: Validate workflow syntax and contracts**

Run:

```bash
ruby -e 'require "yaml"; Dir[".github/workflows/*.yml"].each { |f| YAML.load_file(f); puts f }'
bash Scripts/check_fork_identity.sh
```

Expected: every workflow parses and identity contract passes.

- [ ] **Step 5: Commit CI**

```bash
git add .github README.md Scripts/check_fork_identity.sh
git commit -m "ci: owned fork build and release flow" -m $'- verified fork identity on every change\n- automated signed notarized tag releases\n- kept release credentials inside protected environment'
```

### Task 7: Local upstream lane

**Files:**
- Modify local Git config only.
- Verify: `FORKING.md`

- [ ] **Step 1: Configure upstream fetch remote**

Run:

```bash
git remote add upstream https://github.com/XcodesOrg/XcodesApp.git
git remote set-url --push upstream DISABLED
git fetch upstream
```

If `upstream` exists, validate and correct URLs instead of adding duplicate.

- [ ] **Step 2: Verify ancestry and remote safety**

Run:

```bash
git remote -v
git merge-base upstream/main origin/main
git remote get-url --push upstream
```

Expected: fetch URL is XcodesOrg; push URL is `DISABLED`; merge base resolves and records exact shared upstream ancestry without assuming either branch is current.

### Task 8: Full verification and review

**Files:**
- Verify all changed files.

- [ ] **Step 1: Run static contracts**

```bash
bash Scripts/check_fork_identity.sh
bash Scripts/test_release_scripts.sh
git diff --check origin/main...HEAD
```

- [ ] **Step 2: Run full tests**

```bash
xcodebuild test -quiet -project Xcodes.xcodeproj -scheme Xcodes -configuration Test CODE_SIGNING_ALLOWED=NO
```

Expected: all tests pass.

- [ ] **Step 3: Run unsigned Debug and archive compilation**

```bash
xcodebuild build -quiet -project Xcodes.xcodeproj -scheme Xcodes -configuration Debug CODE_SIGNING_ALLOWED=NO
xcodebuild archive -quiet -project Xcodes.xcodeproj -scheme Xcodes -configuration Release -archivePath /tmp/Xcodes-owned-fork.xcarchive CODE_SIGNING_ALLOWED=NO
```

Expected: both exit zero. Signed notarized packaging remains gated by release secrets.

- [ ] **Step 4: Inspect built identity**

Extract build settings and archive plist. Confirm app/helper/test IDs, team ID, feed URLs, public key, visible product name, and absence of operational upstream IDs.

- [ ] **Step 5: Independent code review**

Review migration safety, helper code requirements, scripts, workflow secret handling, appcast publication, and upstream branch lane. Fix Critical and Important findings with red-green tests.

- [ ] **Step 6: Final clean-state check**

```bash
git status --short
git log --oneline origin/main..HEAD
```

Expected: clean worktree and scoped commits.
