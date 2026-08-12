# Central Appcast Publishing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Publish Xcodes Sparkle feeds through `docs.jacobcx.dev` without enabling Pages or creating a `gh-pages` branch in XcodesApp.

**Architecture:** XcodesApp continues to generate and validate complete appcast history. A dedicated composite action owned by `jacobcxdev.github.io` accepts only the two rendered feeds and atomically publishes them under `public/repo/1330187036/updates/`, matching the central site's stable repository-ID pattern and the publisher flow already used by sibling repositories.

**Tech Stack:** GitHub Actions, Node.js 25, Ruby/Jekyll, Sparkle, Astro static assets, Bash contract tests, GitHub CLI.

---

### Task 1: Central publisher contract

**Files:**
- Create: `../jacobcxdev.github.io/actions/publish-appcast/action.yml`
- Create: `../jacobcxdev.github.io/actions/publish-appcast/publish.mjs`
- Create: `../jacobcxdev.github.io/actions/publish-appcast/publish.test.mjs`
- Modify: `../jacobcxdev.github.io/package.json`
- Modify: `../jacobcxdev.github.io/.github/workflows/test-publish-action.yml`

- [ ] **Step 1: Write failing publisher tests**

Cover exact two-file input, missing/extra files, empty files, symlinks,
malformed XML, fixed destination, unchanged output, and local bare-repository
publication. Assert output names are `appcast.xml` and
`appcast-prereleases.xml` under `public/repo/1330187036/updates/`.

- [ ] **Step 2: Run tests and capture RED**

Run: `node --test actions/publish-appcast/publish.test.mjs`

Expected: FAIL because publisher module does not exist.

- [ ] **Step 3: Implement fixed-scope publisher**

Implement a Node entrypoint that:

```text
validate source directory with lstat
require exact regular files appcast.xml and appcast-prereleases.xml
reject symlinks, empty files, unexpected entries, and malformed XML
clone central repository without logging token
stage replacement beside public/repo/1330187036/updates
rename staged directory to public/repo/1330187036/updates
commit only public/repo/1330187036/updates
pull --rebase and retry bounded push failures
support local test repository and dry-run without weakening hosted mode
```

Expose it through a composite action with required `token` and `source-dir`
inputs. Keep destination and repository fixed.

- [ ] **Step 4: Run focused GREEN**

Run:

```bash
node --test actions/publish-appcast/publish.test.mjs
pnpm lint:strict
pnpm typecheck
```

Expected: PASS.

- [ ] **Step 5: Extend central action workflow**

Add publisher test execution to existing action-test workflow. Use Node.js 25,
matching repository policy. Do not change central index scanner or UI.

- [ ] **Step 6: Run central full verification**

Run: `pnpm ci:local`

Expected: lint, typecheck, coverage, index verification, build, and publisher
tests pass.

- [ ] **Step 7: Commit central source work**

Commit on `dev/next`, merge through repository's documented `dev/next` to
`main` workflow, push both branches, then record exact central merge SHA.

### Task 2: Xcodes workflow RED contracts

**Files:**
- Modify: `.github/workflows/appcast.yml`
- Modify: `.github/workflows/release.yml`
- Modify: `Scripts/check_appcast_workflow.rb`
- Modify: `Scripts/test_appcast_contracts.sh`
- Modify: `Scripts/check_ci_release_workflows.rb`
- Modify: `Scripts/test_ci_release_workflows.sh`

- [ ] **Step 1: Add failing semantic expectations**

Require:

```text
no github-pages deploy action
no gh-pages branch or XcodesApp contents:write deployment
downloaded artifact contains exact two feed files
central action repository checkout pinned to recorded full SHA
persist-credentials false
publisher job uses only INDEX_REPO_TOKEN
publisher action path is ./action-checkout/actions/publish-appcast
release reusable caller passes only INDEX_REPO_TOKEN
```

- [ ] **Step 2: Add mutations**

Mutate each trust boundary: restore `gh-pages`, use mutable central ref, expose
token to build step, broaden permissions, change destination action, omit
secret mapping, add `continue-on-error`, or bypass feed validation.

- [ ] **Step 3: Run tests and capture RED**

Run:

```bash
bash Scripts/test_appcast_contracts.sh
bash Scripts/test_ci_release_workflows.sh
```

Expected: FAIL against current Pages deployment workflow.

### Task 3: Centralise Xcodes feed publication

**Files:**
- Modify: `.github/workflows/appcast.yml`
- Modify: `.github/workflows/release.yml`
- Modify: `AppCast/appcast_pre.xml`
- Modify: `AppCast/test_appcast.rb`
- Modify: `Scripts/validate_rendered_appcast.rb`

- [ ] **Step 1: Rename rendered prerelease feed contract**

Replace `appcast_pre.xml` output with `appcast-prereleases.xml` in source,
fixtures, validators, and uploaded artifact. Keep stable feed as `appcast.xml`.

- [ ] **Step 2: Replace Pages deploy job**

Use a secret-bearing Ubuntu publisher job with `contents: read`, exact central
checkout SHA, `persist-credentials: false`, downloaded verified feeds, and:

```yaml
- name: Publish through central index
  uses: ./action-checkout/actions/publish-appcast
  with:
    token: ${{ secrets.INDEX_REPO_TOKEN }}
    source-dir: AppCast/_site
```

Declare required `INDEX_REPO_TOKEN` for `workflow_call`. Map only that secret
from signed release workflow.

- [ ] **Step 3: Run focused GREEN**

Run:

```bash
bash Scripts/test_appcast_contracts.sh
bash Scripts/test_ci_release_workflows.sh
actionlint
```

Expected: PASS.

### Task 4: Update fork feed identity

**Files:**
- Modify: `Xcodes/Resources/Info.plist`
- Modify: `Xcodes/Frontend/Preferences/UpdatesPreferencePane.swift`
- Modify: `AppCast/_config.yml`
- Modify: `Scripts/check_appcast_identity.sh`
- Modify: `Scripts/test_fork_identity_guard.sh`
- Modify: `Scripts/test_appcast_contracts.sh`
- Modify: `README.md`
- Modify: `docs/RELEASING.md`

- [ ] **Step 1: Add failing URL contract mutations**

Require stable URL
`https://docs.jacobcx.dev/repo/1330187036/updates/appcast.xml` and prerelease URL
`https://docs.jacobcx.dev/repo/1330187036/updates/appcast-prereleases.xml`. Reject old
`jacobcxdev.github.io/XcodesApp` URLs anywhere active.

- [ ] **Step 2: Update application and renderer configuration**

Change both runtime feed constants, `SUFeedURL`, Jekyll `url`/`baseurl`, README,
release guide, and guards. Document that central Pages owns hosting while
XcodesApp owns feed generation.

- [ ] **Step 3: Run identity GREEN**

Run:

```bash
bash Scripts/check_fork_identity.sh
bash Scripts/test_fork_identity_guard.sh
bash Scripts/check_appcast_identity.sh
bash Scripts/test_appcast_contracts.sh
```

Expected: PASS with no old feed or `gh-pages` references.

### Task 5: Advance immutable release build

**Files:**
- Modify: `Xcodes.xcodeproj/project.pbxproj`
- Modify: `docs/RELEASING.md`
- Modify: release workflow contract fixtures that encode current example tag

- [ ] **Step 1: Add build-number mismatch RED**

Update release contract expected tag to `v4.0.4b43` while project still reports
build 42. Run release contracts and confirm failure.

- [ ] **Step 2: Set all target/configuration build numbers to 43**

Update every `CURRENT_PROJECT_VERSION` owned by app, tests, and helper. Preserve
marketing version 4.0.4.

- [ ] **Step 3: Run release-contract GREEN**

Run:

```bash
bash Scripts/test_release_scripts.sh
bash Scripts/test_release_artifacts.sh
bash Scripts/test_ci_release_workflows.sh
```

Expected: PASS.

### Task 6: Full local verification and publication

**Files:**
- Verify all changed files in both repositories

- [ ] **Step 1: Verify central repository**

Run `pnpm ci:local`, publisher tests, YAML parse, and workflow lint.

- [ ] **Step 2: Verify Xcodes repository**

Run all shell/Ruby/workflow contract suites, unrestricted ShellCheck,
`actionlint`, YAML/plist validation, full unsigned tests, and unsigned Debug
build. Restore generated `Licenses.rtf` if Xcode changes it.

- [ ] **Step 3: Review diffs and secrets**

Run `git diff --check`, changed-line secret scan, and confirm clean staged scope
in both repositories.

- [ ] **Step 4: Commit, push, and merge Xcodes work**

Push `jacobcxdev/centralise-appcast`, open ready PR, wait for required checks,
merge, and confirm clean `main` at exact merge SHA.

- [ ] **Step 5: Configure cross-repo secret**

Set XcodesApp `INDEX_REPO_TOKEN` without printing its value. Verify secret name
exists and token can write only central index repository.

- [ ] **Step 6: Tag and release**

Create immutable `v4.0.4b43` tag on exact XcodesApp main merge, push tag, and
wait for signed release workflow.

- [ ] **Step 7: Verify live outcome**

Confirm signed/notarised release assets, central-site commit, successful central
deployment, valid live XML at both feed URLs, Sparkle enclosure version/build
43, `XcodesApp.has_pages == false`, and no remote `gh-pages` ref.
