import Version
import XcodesKit
@testable import Xcodes
import XCTest

/// Regression tests for the "New Xcode version available" notification trigger.
///
/// The decision to notify is extracted into the pure helper
/// `AppState.newlyAvailableXcodes(oldXcodes:newXcodes:)` and asserted directly here.
/// No notification spying and no `Current = .mock` are required: the helper is the single
/// source of truth that the `availableXcodes.willSet` predicate consults.
@MainActor
final class NewVersionNotificationTests: XCTestCase {
    // MARK: - Fixtures

    /// Builds an `AvailableXcode` for `version` with a distinct download URL, mirroring the
    /// construction style in `AppStateUpdateTests.swift` (`Version("0.0.0")!`, three components).
    /// `architectures` defaults to `nil`.
    private func makeAvailableXcode(
        version: String,
        architectures: [Architecture]? = nil,
        urlSuffix: String = ""
    ) -> AvailableXcode {
        AvailableXcode(
            version: Version(version)!,
            url: URL(string: "https://example.com/Xcode-\(version)-\(urlSuffix).xip")!,
            filename: "Xcode-\(version)-\(urlSuffix).xip",
            releaseDate: nil,
            architectures: architectures
        )
    }

    /// The set of stable identities (`xcodeID`) for the given available Xcodes — an
    /// order-independent comparison keyed on version + architecture, not array position.
    private func identities(_ xcodes: [AvailableXcode]) -> Set<XcodeID> {
        Set(xcodes.map(\.xcodeID))
    }

    // MARK: - Initial-load suppression

    func testInitialLoadDoesNotNotify() {
        // First population (empty -> populated) is the initial cache load, NOT "a new version
        // since you last looked", so the result must be empty even though the array grew.
        let old: [AvailableXcode] = []
        let new = [makeAvailableXcode(version: "15.0.0")]

        let result = AppState.newlyAvailableXcodes(oldXcodes: old, newXcodes: new)

        XCTAssertTrue(result.isEmpty, "Initial population must not be treated as a new version")
    }

    // MARK: - True positive — one genuinely new version

    func testGenuinelyNewVersionIsReported() {
        let existingA = makeAvailableXcode(version: "15.0.0")
        let existingB = makeAvailableXcode(version: "15.1.0")
        let added = makeAvailableXcode(version: "16.0.0")
        let old = [existingA, existingB]
        let new = [existingA, existingB, added]

        let result = AppState.newlyAvailableXcodes(oldXcodes: old, newXcodes: new)

        XCTAssertEqual(identities(result), [added.xcodeID])
    }

    // MARK: - FALSE NEGATIVE (the bug) — new version added AND old version removed, count unchanged

    func testNewVersionAddedAndOldRemovedIsReported() {
        // The OLD count-based predicate saw "no growth" (2 -> 2) here and MISSED version C.
        // A data source can drop an obsolete beta row the same refresh it adds the new one.
        let existing = makeAvailableXcode(version: "15.1.0")
        let removed = makeAvailableXcode(version: "15.0.0")
        let added = makeAvailableXcode(version: "16.0.0")
        let old = [removed, existing]
        let new = [existing, added]

        let result = AppState.newlyAvailableXcodes(oldXcodes: old, newXcodes: new)

        XCTAssertEqual(identities(result), [added.xcodeID], "A genuinely new version must be reported even when the count is unchanged")
    }

    // MARK: - FALSE NEGATIVE variant — a new version appears while the list shrinks

    func testNewVersionReportedEvenWhenListShrinks() {
        // A genuinely new version can appear even when the overall count DECREASES: a data source
        // prunes older rows the same refresh it surfaces the newest (3 -> 2 here). The OLD
        // count-based predicate saw "no growth" and MISSED D; the identity-based helper reports it.
        let droppedA = makeAvailableXcode(version: "15.0.0")
        let droppedB = makeAvailableXcode(version: "15.1.0")
        let kept = makeAvailableXcode(version: "16.0.0")
        let added = makeAvailableXcode(version: "17.0.0")
        let old = [droppedA, droppedB, kept]
        let new = [kept, added]

        let result = AppState.newlyAvailableXcodes(oldXcodes: old, newXcodes: new)

        XCTAssertEqual(identities(result), [added.xcodeID], "A new version must be reported even when the list shrinks")
    }

    // MARK: - FALSE POSITIVE (the bug) — count grows with NO new identity

    func testDuplicateIdentityIsNotNew() {
        // The OLD count-based predicate FIRED here (1 -> 2); the fixed helper correctly does not.
        // The feed returns a row whose xcodeID was already present (a duplicate, same version).
        let present = makeAvailableXcode(version: "15.0.0")
        let duplicate = makeAvailableXcode(version: "15.0.0", urlSuffix: "duplicate") // same version -> same xcodeID
        let old = [present]
        let new = [present, duplicate]

        let result = AppState.newlyAvailableXcodes(oldXcodes: old, newXcodes: new)

        XCTAssertTrue(result.isEmpty, "A duplicate of an existing xcodeID must not be treated as new")
    }

    // MARK: - Identical list

    func testIdenticalListIsNotNew() {
        let a = makeAvailableXcode(version: "15.0.0")
        let b = makeAvailableXcode(version: "15.1.0")
        let old = [a, b]
        let new = [a, b]

        let result = AppState.newlyAvailableXcodes(oldXcodes: old, newXcodes: new)

        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - Identity is version + architecture, not version alone

    func testSameVersionDifferentArchitectureIsDistinctIdentity() {
        // Two AvailableXcodes with the same version but different architectures have DIFFERENT
        // xcodeIDs (XcodeID.id = version.description + architectures), so an Apple-Silicon-only
        // release is distinct from a Universal release of the same version.
        let universal: [Architecture] = [.arm64, .x86_64]
        let appleSilicon: [Architecture] = [.arm64]
        let universalRelease = makeAvailableXcode(version: "15.0.0", architectures: universal)
        let appleSiliconRelease = makeAvailableXcode(version: "15.0.0", architectures: appleSilicon)
        let old = [universalRelease]
        let new = [universalRelease, appleSiliconRelease]

        let result = AppState.newlyAvailableXcodes(oldXcodes: old, newXcodes: new)

        XCTAssertEqual(identities(result), [appleSiliconRelease.xcodeID])
    }
}
