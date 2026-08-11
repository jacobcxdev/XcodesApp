# Install and Platform Reliability Design

## Goal

Make Apple authentication, Xcode selection symlinks, and installed simulator runtime management reliable without introducing additional maintained dependency forks.

## Confirmed Problems

### Authentication and installation

- Apple session validation can expose `NetworkError.non200StatusCode` directly. A 401 therefore bypasses Xcodes' unauthenticated flow and appears as an implementation-level error.
- Apple sign-in endpoints can intermittently return 502, 503, or 504. Current authentication failure handling clears the saved username and password for every failure, including temporary server failures.
- Installation validates the session more than once. Every validation must use the same status classification so a late 401 cannot leak as a raw network error.

### Selection symlinks

- `FileManager.fileExists(atPath:)` returns false for a broken symbolic link. `XcodeSelectionFilesystemService` consequently skips removal and then fails to create the replacement because the directory entry still exists.
- Automatic selection supports only `Xcode.app`. Users need stable and prerelease links to remain independent.

### Installed runtimes and alerts

- Installed runtime state comes from `/Library/Developer/CoreSimulator/images/images.plist`. The observed iOS 26.5 UUID was present in stale app state but absent from live `simctl runtime list -j` output.
- Installed Platforms matches downloadable entries by build alone. Multiple packages for different architectures can share a build, so unsupported duplicates appear.
- Runtime confirmation and error alerts use state attached to both Settings and Platforms scenes. Setting that shared state can activate Settings while Platforms is handling an error.

## Architecture

Keep fixes inside XcodesApp. Reuse XcodesKit's existing live `RuntimeService.installedRuntimes()` API and selection service. Add small app-level policies where XcodesApp owns user workflow: network status classification, automatic link destination selection, runtime presentation matching, and scene-specific alert state.

Do not fork XcodesKit, XcodesLoginKit, or AsyncHTTPNetworkService. Do not broadly retry authentication failures. Do not mutate CoreSimulator files or restart its services.

## Authentication Design

Add an app-owned authentication request policy with these behaviours:

- Identify `NetworkError.non200StatusCode` values.
- Treat 502, 503, and 504 as transient.
- Retry transient authentication requests at most three total attempts with a two-second delay between attempts.
- Respect task cancellation during delay and request execution.
- Map a 401 from session validation to `AuthenticationError.notAuthorized`.
- Preserve saved credentials after transport and transient server failures.
- Clear saved credentials only when Apple rejects credentials or a completed authentication flow proves them unusable.

`signInAsync` applies retry policy around full XcodesLoginKit authentication operation. `validateSessionAsync` maps session authorization status before callers decide whether stored credentials can repair session. Both explicit sign-in and installation therefore share classification.

Final transient failure remains visible, but user-facing text describes temporary Apple service failure and recommends retrying instead of exposing enum debug output or byte counts.

## Symlink Design

Pass an existence probe to `XcodeSelectionFilesystemService` that detects directory entries, including broken symlinks, using filesystem attributes. Existing service then verifies item type, removes only symbolic links, and preserves its safety error for real files or directories.

Add `createBetaSymLinkOnSelect` as a separate persisted preference and managed preference key. Automatic routing follows approved stable/beta split:

- Selecting release Xcode updates `Xcode.app` when stable-link option is enabled.
- Selecting prerelease Xcode updates `Xcode-Beta.app` when beta-link option is enabled.
- Selecting prerelease Xcode never changes `Xcode.app` through automatic linking.
- Selecting release Xcode never changes `Xcode-Beta.app` through automatic linking.
- Existing manual commands for either link remain available.
- Rename-on-select remains mutually exclusive with automatic links.

Prerelease classification uses Xcode version metadata already used elsewhere in application rather than display strings.

## Runtime Design

Change installed runtime refresh to call `RuntimeService.installedRuntimes()`, which executes `xcrun simctl runtime list -j`. Convert returned live records into existing app runtime lookup representation, retaining UUID, build, path, and supported architectures.

Installed Platforms includes a downloadable runtime only when `RuntimeInstallationLookupService` finds a live runtime matching both build and architecture. This removes same-build packages that cannot represent installed image.

Deletion uses UUID from same live snapshot. After successful deletion, refresh live snapshot. After failure, refresh snapshot before presenting error so stale rows disappear when `simctl` reports image already absent. No automatic service restart, plist deletion, or privileged cleanup occurs.

## Alert Ownership

Replace shared `presentedPreferenceAlert` runtime usage with Platforms-owned alert state in `AppState`, bound only to Platforms scene. Settings receives no runtime alert binding. Confirmation and deletion errors remain in window where action originated.

Keep main-window installation alerts unchanged.

## Testing

Use existing XCTest infrastructure and strict red-green cycles. Regression coverage must prove:

- Session-validation 401 becomes `AuthenticationError.notAuthorized`.
- 503 authentication succeeds after bounded retry and stops after third failure.
- Transient authentication failure preserves stored credentials.
- Credential rejection clears stored credentials.
- Broken `Xcode.app` and `Xcode-Beta.app` links are replaced.
- Real files at link destinations remain protected.
- Release and prerelease selections route only to approved automatic link names.
- Live runtime conversion preserves UUID, build, path, and architectures.
- Installed runtime filtering rejects same-build architecture mismatch.
- Runtime deletion refreshes live state on success and failure.
- Runtime errors set Platforms-only alert state.

Run focused test cases after each change. Finish with full XcodesTests suite and Debug build using repository's Xcode scheme.

## Scope Boundaries

- No Apple credential logging or response-body persistence.
- No unbounded retries.
- No changes to Apple or CoreSimulator private data.
- No dependency forks or unrelated SwiftUI refactors.
- No automatic deletion of non-symlink filesystem entries.
