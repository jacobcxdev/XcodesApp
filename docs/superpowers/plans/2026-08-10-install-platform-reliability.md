# Install and Platform Reliability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Apple authentication, automatic Xcode symlinks, and installed simulator platform management resilient and truthful.

**Architecture:** Keep workflow policy inside XcodesApp while reusing current XcodesKit and XcodesLoginKit APIs. Add narrow status classification and link-routing helpers to `AppState`, read installed runtimes from live `simctl` output, and isolate Platforms alerts from Settings scene.

**Tech Stack:** Swift 6, SwiftUI, XCTest, XcodesKit 1.0.4, XcodesLoginKit main, AsyncNetworkService main, Xcode 27.

## Global Constraints

- Keep fixes inside XcodesApp; do not fork dependencies.
- Retry only HTTP 502, 503, and 504; make at most three total attempts with two-second delays.
- Never log or persist Apple response bodies or credentials.
- Never delete non-symlink entries at `Xcode.app` or `Xcode-Beta.app`.
- Never mutate CoreSimulator files or restart CoreSimulator services.
- Use stable/beta split: releases update `Xcode.app`; prereleases update `Xcode-Beta.app`.
- Use existing XCTest suite and run each regression red before implementation.

---

### Task 1: Authentication status policy

**Files:**
- Modify: `Xcodes/Backend/AppState.swift`
- Modify: `XcodesTests/AppStateTests.swift`

**Interfaces:**
- Consumes: `NetworkError.non200StatusCode`, `AuthenticationError`, `attemptRetryableTask`.
- Produces: `AuthenticationRequestPolicy.perform(_:)`, `mapSessionValidationError(_:)`, `shouldClearCredentials(after:)`, `AuthenticationRequestError.serviceTemporarilyUnavailable(statusCode:)`.

- [ ] **Step 1: Write failing policy tests**

Add tests proving 401 maps to `.notAuthorized`, two 503 responses are retried before success, third 503 stops, transient errors preserve credentials, and invalid username/password clears credentials:

```swift
func test_AuthenticationPolicy_MapsSession401ToNotAuthorized() {
    let error = AuthenticationRequestPolicy.mapSessionValidationError(
        NetworkError.non200StatusCode(statusCode: 401, data: Data())
    )
    XCTAssertEqual(error as? AuthenticationError, .notAuthorized)
}

func test_AuthenticationPolicy_Retries503UntilSuccess() async throws {
    let attempts = TestLockedBox(0)
    let result = try await AuthenticationRequestPolicy(delayBeforeRetry: .zero).perform {
        let attempt = attempts.withValue { value in value += 1; return value }
        if attempt < 3 {
            throw NetworkError.non200StatusCode(statusCode: 503, data: nil)
        }
        return "authenticated"
    }
    XCTAssertEqual(result, "authenticated")
    XCTAssertEqual(attempts.read { $0 }, 3)
}

func test_AuthenticationPolicy_DoesNotClearCredentialsFor503() {
    XCTAssertFalse(AuthenticationRequestPolicy.shouldClearCredentials(after:
        NetworkError.non200StatusCode(statusCode: 503, data: nil)
    ))
}

func test_AuthenticationPolicy_MapsFinal503ToLegibleError() async {
    do {
        _ = try await AuthenticationRequestPolicy(delayBeforeRetry: .zero).perform {
            throw NetworkError.non200StatusCode(statusCode: 503, data: nil)
        } as String
        XCTFail("Expected temporary service error")
    } catch {
        XCTAssertEqual(
            error as? AuthenticationRequestError,
            .serviceTemporarilyUnavailable(statusCode: 503)
        )
    }
}
```

- [ ] **Step 2: Run focused tests and verify red**

Run:

```bash
xcodebuild test -project Xcodes.xcodeproj -scheme Xcodes -configuration Test -only-testing:XcodesTests/AppStateTests/test_AuthenticationPolicy_MapsSession401ToNotAuthorized -only-testing:XcodesTests/AppStateTests/test_AuthenticationPolicy_Retries503UntilSuccess -only-testing:XcodesTests/AppStateTests/test_AuthenticationPolicy_DoesNotClearCredentialsFor503
```

Expected: compile failure because `AuthenticationRequestPolicy` does not exist.

- [ ] **Step 3: Implement minimal authentication policy**

Add `import AsyncNetworkService` and internal policy:

```swift
enum AuthenticationRequestError: LocalizedError, Equatable {
    case serviceTemporarilyUnavailable(statusCode: Int)

    var errorDescription: String? {
        switch self {
        case let .serviceTemporarilyUnavailable(statusCode):
            return "Apple's authentication service is temporarily unavailable (HTTP \(statusCode)). Try again shortly."
        }
    }
}

struct AuthenticationRequestPolicy: Sendable {
    let maximumAttemptCount: Int
    let delayBeforeRetry: Duration

    init(maximumAttemptCount: Int = 3, delayBeforeRetry: Duration = .seconds(2)) {
        self.maximumAttemptCount = maximumAttemptCount
        self.delayBeforeRetry = delayBeforeRetry
    }

    func perform<T>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        do {
            return try await attemptRetryableTask(
                maximumRetryCount: maximumAttemptCount,
                delayBeforeRetry: delayBeforeRetry,
                shouldRetry: Self.isTransient
            ) {
                try await operation()
            }
        } catch NetworkError.non200StatusCode(let statusCode, _)
            where [502, 503, 504].contains(statusCode) {
            throw AuthenticationRequestError.serviceTemporarilyUnavailable(statusCode: statusCode)
        }
    }

    static func mapSessionValidationError(_ error: Error) -> Error {
        guard case NetworkError.non200StatusCode(statusCode: 401, data: _) = error else { return error }
        return AuthenticationError.notAuthorized
    }

    static func shouldClearCredentials(after error: Error) -> Bool {
        if case AuthenticationError.invalidUsernameOrPassword = error { return true }
        return false
    }

    private static func isTransient(_ error: Error) -> Bool {
        guard case let NetworkError.non200StatusCode(statusCode, _) = error else { return false }
        return [502, 503, 504].contains(statusCode)
    }
}
```

Use policy in `signInAsync`, map `validateSessionAsync` errors, and gate `clearLoginCredentials()` in `handleAuthenticationFlowFailure`.

- [ ] **Step 4: Run auth tests and relevant installation tests**

Run:

```bash
xcodebuild test -project Xcodes.xcodeproj -scheme Xcodes -configuration Test -only-testing:XcodesTests/AppStateTests/test_AuthenticationPolicy -only-testing:XcodesTests/AppStateTests/test_Install_FullHappyPath_Apple
```

Expected: all selected tests pass.

- [ ] **Step 5: Commit authentication fix**

```bash
git add Xcodes/Backend/AppState.swift XcodesTests/AppStateTests.swift
git commit -m "fix: hardened Apple authentication" -m $'- mapped unauthorized sessions into sign-in flow\n- retried temporary Apple service failures\n- preserved credentials after transient errors'
```

### Task 2: Stable and beta symlink routing

**Files:**
- Modify: `Xcodes/Backend/AppState.swift`
- Modify: `Xcodes/Frontend/Preferences/AdvancedPreferencePane.swift`
- Modify: `Xcodes/Resources/Localizable.xcstrings`
- Modify: `XcodesTests/AppStateTests.swift`

**Interfaces:**
- Consumes: `Version.isPrerelease`, `XcodeSelectionFilesystemService.createSymbolicLink`.
- Produces: `createBetaSymLinkOnSelect`, `createBetaSymLinkOnSelectDisabled`, `automaticSymbolicLinkIsBeta(for:)`.

- [ ] **Step 1: Write failing broken-link and routing tests**

Create a temporary broken `Xcode.app` symlink and assert `createSymbolicLink(to:)` replaces it. Add corresponding `Xcode-Beta.app` case. Add pure routing tests:

```swift
func test_AutomaticSymbolicLink_ReleaseUsesStableLinkOnly() {
    subject.createSymLinkOnSelect = true
    subject.createBetaSymLinkOnSelect = true
    let xcode = Xcode(version: Version("16.4")!, installState: .notInstalled, selected: false, icon: nil)
    XCTAssertEqual(subject.automaticSymbolicLinkIsBeta(for: xcode), false)
}

func test_AutomaticSymbolicLink_PrereleaseUsesBetaLinkOnly() {
    subject.createSymLinkOnSelect = true
    subject.createBetaSymLinkOnSelect = true
    let xcode = Xcode(version: Version("27.0-Beta.5")!, installState: .notInstalled, selected: false, icon: nil)
    XCTAssertEqual(subject.automaticSymbolicLinkIsBeta(for: xcode), true)
}
```

- [ ] **Step 2: Run symlink tests and verify red**

Run:

```bash
xcodebuild test -project Xcodes.xcodeproj -scheme Xcodes -configuration Test -only-testing:XcodesTests/AppStateTests/test_CreateSymbolicLink_ReplacesBrokenStableLink -only-testing:XcodesTests/AppStateTests/test_CreateSymbolicLink_ReplacesBrokenBetaLink -only-testing:XcodesTests/AppStateTests/test_AutomaticSymbolicLink_ReleaseUsesStableLinkOnly -only-testing:XcodesTests/AppStateTests/test_AutomaticSymbolicLink_PrereleaseUsesBetaLinkOnly
```

Expected: broken-link test fails with file-exists error; routing tests fail to compile.

- [ ] **Step 3: Detect broken symlink entries**

Inject this existence probe into `XcodeSelectionFilesystemService`:

```swift
fileExists: { path in
    (try? FileManager.default.attributesOfItem(atPath: path)) != nil
},
```

Keep existing type check and non-symlink safety error unchanged.

- [ ] **Step 4: Add beta preference and routing**

Add `createBetaSymLinkOnSelect` preference storage and managed-state handling. Route selection with:

```swift
func automaticSymbolicLinkIsBeta(for xcode: Xcode) -> Bool? {
    if xcode.version.isPrerelease {
        return createBetaSymLinkOnSelect ? true : nil
    }
    return createSymLinkOnSelect ? false : nil
}
```

In `select`, create one routed link only when rename mode is disabled. Add beta toggle and English localization entries beside existing stable-link strings.

- [ ] **Step 5: Run symlink and preferences tests**

Run:

```bash
xcodebuild test -project Xcodes.xcodeproj -scheme Xcodes -configuration Test -only-testing:XcodesTests/AppStateTests/test_CreateSymbolicLink -only-testing:XcodesTests/AppStateTests/test_AutomaticSymbolicLink
```

Expected: all selected tests pass; non-symlink safety remains covered.

- [ ] **Step 6: Commit symlink fix**

```bash
git add Xcodes/Backend/AppState.swift Xcodes/Frontend/Preferences/AdvancedPreferencePane.swift Xcodes/Resources/Localizable.xcstrings XcodesTests/AppStateTests.swift
git commit -m "fix: repaired automatic Xcode links" -m $'- replaced broken symbolic links safely\n- added independent beta-link preference\n- split release and prerelease destinations'
```

### Task 3: Live installed runtime state

**Files:**
- Modify: `Xcodes/Backend/AppState+Runtimes.swift`
- Modify: `Xcodes/Frontend/Preferences/PlatformsListView.swift`
- Modify: `XcodesTests/AppStateTests.swift`

**Interfaces:**
- Consumes: `RuntimeService.installedRuntimes()`, `InstalledRuntime`, `RuntimeInstallationLookupService`.
- Produces: `refreshInstalledRuntimes() async throws`, `CoreSimulatorImage.init(installedRuntime:)`, architecture-aware `loadRuntimes()`.

- [ ] **Step 1: Write failing live-runtime conversion test**

Inject `RuntimeService.installedRuntimesOutput` JSON with UUID, build, path, and `arm64`, call `refreshInstalledRuntimes()`, then assert converted `CoreSimulatorImage` fields exactly match fixture.

```swift
func test_RefreshInstalledRuntimes_UsesLiveSimctlOutput() async throws {
    subject.runtimeService = runtimeService(installedRuntimesJSON: liveRuntimeJSON)
    try await subject.refreshInstalledRuntimes()
    XCTAssertEqual(subject.installedRuntimes.map(\.uuid), ["97772E90-7BD1-4882-9C51-782E62E0AF4F"])
    XCTAssertEqual(subject.installedRuntimes.first?.runtimeInfo.build, "23F72")
    XCTAssertEqual(subject.installedRuntimes.first?.runtimeInfo.supportedArchitectures, [.arm64])
}
```

- [ ] **Step 2: Run conversion test and verify red**

Run:

```bash
xcodebuild test -project Xcodes.xcodeproj -scheme Xcodes -configuration Test -only-testing:XcodesTests/AppStateTests/test_RefreshInstalledRuntimes_UsesLiveSimctlOutput
```

Expected: compile failure because `refreshInstalledRuntimes()` does not exist.

- [ ] **Step 3: Implement live refresh and conversion**

Add:

```swift
func refreshInstalledRuntimes() async throws {
    installedRuntimes = try await runtimeService.installedRuntimes().map(CoreSimulatorImage.init)
}

private extension CoreSimulatorImage {
    init(_ runtime: InstalledRuntime) {
        self.init(
            uuid: runtime.identifier.uuidString,
            path: ["relative": runtime.path],
            runtimeInfo: CoreSimulatorRuntimeInfo(
                build: runtime.build,
                supportedArchitectures: runtime.supportedArchitectures
            )
        )
    }
}
```

Make `updateInstalledRuntimes()` call this method inside existing cancellation/task-ID guard.

- [ ] **Step 4: Write and run failing architecture-filter test**

Extract Platforms filtering to an internal function callable from tests, then prove same build with `x86_64` downloadable entry does not match live `arm64` runtime while `arm64` entry does.

Run:

```bash
xcodebuild test -project Xcodes.xcodeproj -scheme Xcodes -configuration Test -only-testing:XcodesTests/AppStateTests/test_InstalledPlatformRuntimes_RejectsArchitectureMismatch
```

Expected: red against current build-only filter.

- [ ] **Step 5: Implement architecture-aware filtering**

Filter with existing lookup contract:

```swift
func installedPlatformRuntimes() -> [DownloadableRuntime] {
    downloadableRuntimes.filter { coreSimulatorInfo(runtime: $0) != nil }
}
```

Make `PlatformsListView.loadRuntimes()` group this result.

- [ ] **Step 6: Refresh live state after deletion success and failure**

On successful `deleteRuntime`, wait for deletion then `try await refreshInstalledRuntimes()`. In `confirmDeleteRuntime` failure branch, call `try? await refreshInstalledRuntimes()` before publishing error alert. Add tests asserting stale UUID disappears in both paths.

- [ ] **Step 7: Run runtime tests**

Run:

```bash
xcodebuild test -project Xcodes.xcodeproj -scheme Xcodes -configuration Test -only-testing:XcodesTests/AppStateTests/test_RefreshInstalledRuntimes -only-testing:XcodesTests/AppStateTests/test_InstalledPlatformRuntimes -only-testing:XcodesTests/AppStateTests/test_ConfirmDeleteRuntime
```

Expected: all selected tests pass.

- [ ] **Step 8: Commit runtime fix**

```bash
git add Xcodes/Backend/AppState+Runtimes.swift Xcodes/Frontend/Preferences/PlatformsListView.swift XcodesTests/AppStateTests.swift
git commit -m "fix: refreshed simulator runtime state" -m $'- sourced installed runtimes from live simctl output\n- matched installed platforms by architecture\n- refreshed stale state around deletion'
```

### Task 4: Platforms-only alert ownership

**Files:**
- Modify: `Xcodes/Backend/AppState.swift`
- Modify: `Xcodes/Backend/AppState+Runtimes.swift`
- Modify: `Xcodes/Frontend/Common/XcodesAlert.swift`
- Modify: `Xcodes/Frontend/Preferences/PlatformsListView.swift`
- Modify: `Xcodes/XcodesApp.swift`
- Modify: `XcodesTests/AppStateTests.swift`

**Interfaces:**
- Consumes: current runtime confirmation/error alert cases.
- Produces: `presentedPlatformAlert: XcodesPlatformAlert?`, Platforms-only scene binding.

- [ ] **Step 1: Rename runtime alert state in tests and verify red**

Update runtime error assertion to require `subject.presentedPlatformAlert` and add assertion that Settings scene no longer binds platform alerts through shared preference state.

Run:

```bash
xcodebuild test -project Xcodes.xcodeproj -scheme Xcodes -configuration Test -only-testing:XcodesTests/AppStateTests/test_ConfirmDeleteRuntime_PresentsPlatformAlertOnError
```

Expected: compile failure because platform-owned state does not exist.

- [ ] **Step 2: Implement Platforms-owned alert state**

Rename `XcodesPreferencesAlert` to `XcodesPlatformAlert`, publish `presentedPlatformAlert`, and update runtime actions. Remove `.alert` modifier from Settings scene. Bind `presentedPlatformAlert` only inside `Window("Platforms", id: "platforms")`.

- [ ] **Step 3: Run platform alert tests and build**

Run:

```bash
xcodebuild test -project Xcodes.xcodeproj -scheme Xcodes -configuration Test -only-testing:XcodesTests/AppStateTests/test_ConfirmDeleteRuntime_PresentsPlatformAlertOnError
xcodebuild build -project Xcodes.xcodeproj -scheme Xcodes -configuration Debug
```

Expected: test and build pass.

- [ ] **Step 4: Commit alert fix**

```bash
git add Xcodes/Backend/AppState.swift Xcodes/Backend/AppState+Runtimes.swift Xcodes/Frontend/Common/XcodesAlert.swift Xcodes/Frontend/Preferences/PlatformsListView.swift Xcodes/XcodesApp.swift XcodesTests/AppStateTests.swift
git commit -m "fix: kept platform alerts in context" -m $'- isolated runtime alert state from Settings\n- bound confirmation and errors to Platforms window'
```

### Task 5: Final verification and review

**Files:**
- Verify all modified files.

**Interfaces:**
- Consumes: completed Tasks 1-4.
- Produces: verified branch with clean tracked state.

- [ ] **Step 1: Run full test suite**

```bash
xcodebuild test -project Xcodes.xcodeproj -scheme Xcodes -configuration Test
```

Expected: XcodesTests passes without failures.

- [ ] **Step 2: Run Debug build**

```bash
xcodebuild build -project Xcodes.xcodeproj -scheme Xcodes -configuration Debug
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Run formatting and diff checks**

```bash
git diff --check origin/main...HEAD
git status --short
```

Expected: no whitespace errors; only intended plan state remains uncommitted if plan was not included earlier.

- [ ] **Step 4: Review Swift concurrency and SwiftUI scene ownership**

Confirm retry closure remains `Sendable`, task cancellation propagates, stale task IDs cannot overwrite replacement tasks, Settings has no platform alert binding, and Platforms owns both confirmation and error presentation.

- [ ] **Step 5: Commit plan document if still uncommitted**

```bash
git add docs/superpowers/plans/2026-08-10-install-platform-reliability.md
git commit -m "docs: recorded reliability plan" -m $'- documented red-green implementation steps\n- captured focused and full verification commands'
```

## Execution Result

- Focused red-green tests passed for authentication, symlink routing, live runtime state, and platform alert ownership.
- Full test suite passed: 50 tests, 0 failures, 0 skips.
- Debug build compiled and linked with `CODE_SIGNING_ALLOWED=NO`.
- Normal signed Debug build reached signing and stopped because development certificate for upstream team `ZU6GR6B2FY` is not installed locally.
- `git diff --check origin/main...HEAD` passed.
- Independent review findings for transient session validation and stale runtime refresh ordering were reproduced, fixed, and covered by regression tests.
