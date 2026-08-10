import Combine
import AsyncNetworkService
@preconcurrency import Path
import Version
import XCTest
import XcodesLoginKit
import XcodesKit
import os

@testable import Xcodes

private final class TestLockedBox<Value: Sendable>: Sendable {
    private let storage: OSAllocatedUnfairLock<Value>

    init(_ value: Value) {
        self.storage = OSAllocatedUnfairLock(initialState: value)
    }

    func read<Result: Sendable>(_ body: @Sendable (Value) -> Result) -> Result {
        storage.withLock { body($0) }
    }

    func withValue<Result: Sendable>(_ body: @Sendable (inout Value) -> Result) -> Result {
        storage.withLock { body(&$0) }
    }
}

@MainActor
class AppStateTests: XCTestCase {
    var subject: AppState!
    
    override func setUpWithError() throws {
        Current = .mock
        syncXcodesKitMocks()
        subject = AppState()
    }

    func test_AuthenticationPolicy_MapsSession401ToNotAuthorized() {
        let error = AuthenticationRequestPolicy.mapSessionValidationError(
            NetworkError.non200StatusCode(statusCode: 401, data: Data())
        )

        XCTAssertEqual(error as? AuthenticationError, .notAuthorized)
    }

    func test_AuthenticationPolicy_Retries503UntilSuccess() async throws {
        let attempts = TestLockedBox(0)

        let result = try await AuthenticationRequestPolicy(delayBeforeRetry: .zero).perform {
            let attempt = attempts.withValue { value in
                value += 1
                return value
            }
            if attempt < 3 {
                throw NetworkError.non200StatusCode(statusCode: 503, data: nil)
            }
            return "authenticated"
        }

        XCTAssertEqual(result, "authenticated")
        XCTAssertEqual(attempts.read { $0 }, 3)
    }

    func test_AuthenticationPolicy_StopsAfterThird503() async {
        let attempts = TestLockedBox(0)

        do {
            let _: String = try await AuthenticationRequestPolicy(delayBeforeRetry: .zero).perform {
                attempts.withValue { $0 += 1 }
                throw NetworkError.non200StatusCode(statusCode: 503, data: nil)
            }
            XCTFail("Expected temporary service error")
        } catch {
            XCTAssertEqual(
                error as? AuthenticationRequestError,
                .serviceTemporarilyUnavailable(statusCode: 503)
            )
            XCTAssertEqual(attempts.read { $0 }, 3)
        }
    }

    func test_AuthenticationPolicy_DoesNotClearCredentialsFor503() {
        XCTAssertFalse(
            AuthenticationRequestPolicy.shouldClearCredentials(
                after: NetworkError.non200StatusCode(statusCode: 503, data: nil)
            )
        )
    }

    func test_AuthenticationPolicy_ClearsCredentialsForInvalidPassword() {
        XCTAssertTrue(
            AuthenticationRequestPolicy.shouldClearCredentials(
                after: AuthenticationError.invalidUsernameOrPassword(username: "user@example.com")
            )
        )
    }

    func test_ValidateSession_RetriesTransientServiceFailure() async {
        let attempts = TestLockedBox(0)
        Current.network.validateSessionAsync = {
            attempts.withValue { $0 += 1 }
            throw NetworkError.non200StatusCode(statusCode: 503, data: nil)
        }

        do {
            try await subject.validateSessionAsync(
                authenticationRequestPolicy: AuthenticationRequestPolicy(delayBeforeRetry: .zero)
            )
            XCTFail("Expected temporary service error")
        } catch {
            XCTAssertEqual(
                error as? AuthenticationRequestError,
                .serviceTemporarilyUnavailable(statusCode: 503)
            )
            XCTAssertEqual(attempts.read { $0 }, 3)
        }
    }
    
    func test_ParseCertificateInfo_Succeeds() throws {
        let sampleRawInfo = """
        Executable=/Applications/Xcode-10.1.app/Contents/MacOS/Xcode
        Identifier=com.apple.dt.Xcode
        Format=app bundle with Mach-O thin (x86_64)
        CodeDirectory v=20200 size=434 flags=0x2000(library-validation) hashes=6+5 location=embedded
        Signature size=4485
        Authority=Software Signing
        Authority=Apple Code Signing Certification Authority
        Authority=Apple Root CA
        Info.plist entries=39
        TeamIdentifier=59GAB85EFG
        Sealed Resources version=2 rules=13 files=253327
        Internal requirements count=1 size=68
        """
        let info = XcodeSignatureVerifier().parse(sampleRawInfo)

        XCTAssertEqual(info.authority, ["Software Signing", "Apple Code Signing Certification Authority", "Apple Root CA"])
        XCTAssertEqual(info.teamIdentifier, "59GAB85EFG")
        XCTAssertEqual(info.bundleIdentifier, "com.apple.dt.Xcode")
    }

    func test_PrepareForHelperAction_OnlyRunsActionOnce() {
        var responses = [Bool]()
        subject.prepareForHelperAction { responses.append($0) }

        let helperAction = subject.isPreparingUserForActionRequiringHelper
        helperAction?(true)
        helperAction?(false)

        XCTAssertEqual(responses, [true])
        XCTAssertNil(subject.isPreparingUserForActionRequiringHelper)
    }

    func test_SetupDefaults_EnableGroupedXcodeListDefaultsToTrue() {
        subject.setupDefaults()

        XCTAssertTrue(subject.enableGroupedXcodeList)
    }

    func test_SetupDefaults_EnableGroupedXcodeListUsesStoredValue() {
        Current.defaults.get = { key in
            key == PreferenceKey.enableGroupedXcodeList.rawValue ? false : nil
        }

        subject.setupDefaults()

        XCTAssertFalse(subject.enableGroupedXcodeList)
    }

    func test_ForkPreferenceMigration_CopiesAllowlistedValues() {
        let (defaults, suiteName) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferenceKeys = [
            PreferenceKey.installPath,
            PreferenceKey.localPath,
            PreferenceKey.unxipExperiment,
            PreferenceKey.createSymLinkOnSelect,
            PreferenceKey.createBetaSymLinkOnSelect,
            PreferenceKey.onSelectActionType,
            PreferenceKey.showOpenInRosettaOption,
            PreferenceKey.autoInstallation,
            PreferenceKey.SUEnableAutomaticChecks,
            PreferenceKey.includePrereleaseVersions,
            PreferenceKey.downloader,
            PreferenceKey.dataSource,
            PreferenceKey.xcodeListCategory,
            PreferenceKey.allowedMajorVersions,
            PreferenceKey.hideSupportXcodes,
            PreferenceKey.xcodeListArchitectures,
            PreferenceKey.enableGroupedXcodeList,
            PreferenceKey.expandedMajorXcodeVersions,
            PreferenceKey.expandedMinorXcodeVersions,
        ]
        let keys = preferenceKeys.map(\.rawValue) + ["terminateAfterLastWindowClosed"]
        let legacyValues = Dictionary(uniqueKeysWithValues: keys.map { ($0, "legacy-\($0)") })

        ForkPreferenceMigration.migrate(
            legacyValues: legacyValues,
            into: defaults,
            legacyApplicationSupportExists: false
        )

        for key in keys {
            XCTAssertEqual(defaults.string(forKey: key), "legacy-\(key)")
        }
    }

    func test_ForkPreferenceMigration_DoesNotCopySensitiveOrUnknownValues() {
        let (defaults, suiteName) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let excludedKeys = [
            "username",
            "password",
            "cookies",
            "sessionCookies",
            "credentials",
            "SULastCheckTime",
            "SUSkippedVersion",
            "lastUpdated",
            "arbitraryKey",
        ]
        let legacyValues = Dictionary(uniqueKeysWithValues: excludedKeys.map { ($0, "legacy-value") })

        ForkPreferenceMigration.migrate(
            legacyValues: legacyValues,
            into: defaults,
            legacyApplicationSupportExists: false
        )

        for key in excludedKeys {
            XCTAssertNil(defaults.object(forKey: key))
        }
    }

    func test_ForkPreferenceMigration_PreservesExistingForkValues() {
        let (defaults, suiteName) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("fork-value", forKey: PreferenceKey.downloader.rawValue)

        ForkPreferenceMigration.migrate(
            legacyValues: [PreferenceKey.downloader.rawValue: "legacy-value"],
            into: defaults,
            legacyApplicationSupportExists: false
        )

        XCTAssertEqual(defaults.string(forKey: PreferenceKey.downloader.rawValue), "fork-value")
    }

    func test_ForkPreferenceMigration_UsesLegacySupportWhenLocalPathIsAbsent() {
        let (defaults, suiteName) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        ForkPreferenceMigration.migrate(
            legacyValues: [:],
            into: defaults,
            legacyApplicationSupportExists: true
        )

        XCTAssertEqual(
            defaults.string(forKey: PreferenceKey.localPath.rawValue),
            (Path.applicationSupport/"com.robotsandpencils.XcodesApp").string
        )
    }

    func test_ForkPreferenceMigration_MarkerMakesMigrationIdempotent() {
        let (defaults, suiteName) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        ForkPreferenceMigration.migrate(
            legacyValues: [PreferenceKey.installPath.rawValue: "/Applications/Legacy"],
            into: defaults,
            legacyApplicationSupportExists: false
        )
        ForkPreferenceMigration.migrate(
            legacyValues: [PreferenceKey.downloader.rawValue: "aria2"],
            into: defaults,
            legacyApplicationSupportExists: false
        )

        XCTAssertEqual(defaults.integer(forKey: ForkPreferenceMigration.markerKey), 1)
        XCTAssertNil(defaults.object(forKey: PreferenceKey.downloader.rawValue))
    }

    func test_ForkPaths_UseForkApplicationSupportAndCaches() {
        let expectedApplicationSupport = Path.applicationSupport/"dev.jacobcx.Xcodes"

        XCTAssertEqual(Path.defaultXcodesApplicationSupport, expectedApplicationSupport)
        XCTAssertEqual(Path.xcodesApplicationSupport, expectedApplicationSupport)
        XCTAssertEqual(Path.xcodesCaches, Path.caches/"dev.jacobcx.Xcodes")

        Current.defaults.string = { key in
            key == PreferenceKey.localPath.rawValue ? "/tmp/dev.jacobcx.Xcodes" : nil
        }
        XCTAssertEqual(Path.xcodesApplicationSupport.string, "/tmp/dev.jacobcx.Xcodes")
    }

    func test_PrepareForHelperAction_StaleActionDoesNotClearReplacementAction() {
        var responses = [Bool]()
        subject.prepareForHelperAction { responses.append($0) }
        let staleHelperAction = subject.isPreparingUserForActionRequiringHelper

        subject.prepareForHelperAction { responses.append($0) }
        let replacementHelperAction = subject.isPreparingUserForActionRequiringHelper

        staleHelperAction?(true)
        XCTAssertTrue(responses.isEmpty)
        XCTAssertNotNil(subject.isPreparingUserForActionRequiringHelper)

        replacementHelperAction?(false)
        XCTAssertEqual(responses, [false])
        XCTAssertNil(subject.isPreparingUserForActionRequiringHelper)
        XCTAssertNil(subject.helperActionPreparationID)
    }

    private func makeIsolatedDefaults() -> (defaults: UserDefaults, suiteName: String) {
        let suiteName = "dev.jacobcx.Xcodes.AppStateTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }

    func test_RespondToPreparedHelperAction_RunsActionAndClearsAlert() {
        var responses = [Bool]()
        subject.prepareForHelperAction { responses.append($0) }

        subject.respondToPreparedHelperAction(userConsented: true)

        XCTAssertEqual(responses, [true])
        XCTAssertNil(subject.isPreparingUserForActionRequiringHelper)
        XCTAssertNil(subject.helperActionPreparationID)
        XCTAssertNil(subject.presentedAlert)
    }

    func test_CreateSymbolicLink_UsesProvidedInstalledPath() throws {
        let installDirectory = try XCTUnwrap(Path(
            NSTemporaryDirectory()
                .appending("XcodesAppStateTests-")
                .appending(UUID().uuidString)
        ))
        let installedXcodePath = installDirectory/"Xcode-15.1.app"
        let symlinkPath = installDirectory/"Xcode.app"
        try FileManager.default.createDirectory(at: installedXcodePath.url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: installDirectory.url) }

        Current.defaults.string = { key in
            key == "installPath" ? installDirectory.string : nil
        }

        subject.createSymbolicLink(to: installedXcodePath)

        let destination = try FileManager.default.destinationOfSymbolicLink(atPath: symlinkPath.string)
        XCTAssertEqual(destination, installedXcodePath.string)
    }

    func test_CreateSymbolicLink_ReplacesBrokenStableLink() throws {
        let installDirectory = try XCTUnwrap(Path(
            NSTemporaryDirectory()
                .appending("XcodesAppStateTests-")
                .appending(UUID().uuidString)
        ))
        let installedXcodePath = installDirectory/"Xcode-16.4.app"
        let symlinkPath = installDirectory/"Xcode.app"
        try FileManager.default.createDirectory(at: installedXcodePath.url, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: symlinkPath.string,
            withDestinationPath: (installDirectory/"Missing-Xcode.app").string
        )
        defer { try? FileManager.default.removeItem(at: installDirectory.url) }

        Current.defaults.string = { key in
            key == "installPath" ? installDirectory.string : nil
        }

        subject.createSymbolicLink(to: installedXcodePath)

        let destination = try FileManager.default.destinationOfSymbolicLink(atPath: symlinkPath.string)
        XCTAssertEqual(destination, installedXcodePath.string)
    }

    func test_CreateSymbolicLink_ReplacesBrokenBetaLink() throws {
        let installDirectory = try XCTUnwrap(Path(
            NSTemporaryDirectory()
                .appending("XcodesAppStateTests-")
                .appending(UUID().uuidString)
        ))
        let installedXcodePath = installDirectory/"Xcode-27.0-Beta.5.app"
        let symlinkPath = installDirectory/"Xcode-Beta.app"
        try FileManager.default.createDirectory(at: installedXcodePath.url, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: symlinkPath.string,
            withDestinationPath: (installDirectory/"Missing-Xcode-Beta.app").string
        )
        defer { try? FileManager.default.removeItem(at: installDirectory.url) }

        Current.defaults.string = { key in
            key == "installPath" ? installDirectory.string : nil
        }

        subject.createSymbolicLink(to: installedXcodePath, isBeta: true)

        let destination = try FileManager.default.destinationOfSymbolicLink(atPath: symlinkPath.string)
        XCTAssertEqual(destination, installedXcodePath.string)
    }

    func test_AutomaticSymbolicLink_ReleaseUsesStableLinkOnly() {
        subject.createSymLinkOnSelect = true
        subject.createBetaSymLinkOnSelect = true
        let xcode = Xcode(
            version: Version("16.4.0")!,
            installState: .notInstalled,
            selected: false,
            icon: nil
        )

        XCTAssertEqual(subject.automaticSymbolicLinkIsBeta(for: xcode), false)
    }

    func test_AutomaticSymbolicLink_PrereleaseUsesBetaLinkOnly() {
        subject.createSymLinkOnSelect = true
        subject.createBetaSymLinkOnSelect = true
        let xcode = Xcode(
            version: Version("27.0.0-Beta.5")!,
            installState: .notInstalled,
            selected: false,
            icon: nil
        )

        XCTAssertEqual(subject.automaticSymbolicLinkIsBeta(for: xcode), true)
    }

    func test_InstallHelperIfNecessary_OldTaskDoesNotClearReplacementTask() async throws {
        subject.helperInstallState = .notInstalled
        let continuations = TestLockedBox<[CheckedContinuation<Bool, Error>]>([])
        Current.helper.install = { }
        Current.helper.checkIfLatestHelperIsInstalledAsync = {
            try await withCheckedThrowingContinuation { continuation in
                continuations.withValue { $0.append(continuation) }
            }
        }

        subject.installHelperIfNecessary(shouldPrepareUserForHelperInstallation: false)
        for _ in 0..<100 where continuations.read({ $0.count }) < 1 {
            await Task.yield()
        }
        let firstTask = try XCTUnwrap(subject.helperInstallTask)
        XCTAssertEqual(continuations.read { $0.count }, 1)

        subject.installHelperIfNecessary(shouldPrepareUserForHelperInstallation: false)
        for _ in 0..<100 where continuations.read({ $0.count }) < 2 {
            await Task.yield()
        }
        let replacementTask = try XCTUnwrap(subject.helperInstallTask)
        XCTAssertEqual(continuations.read { $0.count }, 2)

        continuations.read { $0[0] }.resume(returning: false)
        await firstTask.value
        XCTAssertNotNil(subject.helperInstallTask)

        continuations.read { $0[1] }.resume(returning: true)
        await replacementTask.value
        XCTAssertNil(subject.helperInstallTask)
        XCTAssertNil(subject.helperInstallTaskID)
        XCTAssertEqual(subject.helperInstallState, .installed)
    }

    func test_PerformPostInstallSteps_OldTaskDoesNotClearReplacementTask() async throws {
        subject.helperInstallState = .installed
        let firstXcode = InstalledXcode(path: Path("/Applications/Xcode-1.app")!, version: Version("1.0.0")!)
        let secondXcode = InstalledXcode(path: Path("/Applications/Xcode-2.app")!, version: Version("2.0.0")!)
        let firstLaunchPaths = TestLockedBox<[String]>([])
        let continuations = TestLockedBox<[CheckedContinuation<Void, Error>]>([])

        Current.helper.runFirstLaunchAsync = { path in
            firstLaunchPaths.withValue { $0.append(path) }
            try await withCheckedThrowingContinuation { continuation in
                continuations.withValue { $0.append(continuation) }
            }
        }

        subject.performPostInstallSteps(for: firstXcode)
        for _ in 0..<100 where continuations.read({ $0.count }) < 1 {
            await Task.yield()
        }
        let firstTask = try XCTUnwrap(subject.postInstallTask)
        XCTAssertEqual(firstLaunchPaths.read { $0 }, [firstXcode.path.string])

        subject.performPostInstallSteps(for: secondXcode)
        for _ in 0..<100 where continuations.read({ $0.count }) < 2 {
            await Task.yield()
        }
        let replacementTask = try XCTUnwrap(subject.postInstallTask)
        XCTAssertEqual(firstLaunchPaths.read { $0 }, [firstXcode.path.string, secondXcode.path.string])

        continuations.read { $0[0] }.resume()
        await firstTask.value
        XCTAssertNotNil(subject.postInstallTask)

        continuations.read { $0[1] }.resume()
        await replacementTask.value
        XCTAssertNil(subject.postInstallTask)
        XCTAssertNil(subject.postInstallTaskID)
    }

    func test_Select_OldTaskDoesNotClearReplacementTask() async throws {
        subject.helperInstallState = .installed
        let firstPath = try XCTUnwrap(Path("/Applications/Xcode-1.app"))
        let secondPath = try XCTUnwrap(Path("/Applications/Xcode-2.app"))
        let firstXcode = Xcode(version: Version("1.0.0")!, installState: .installed(firstPath), selected: false, icon: nil)
        let secondXcode = Xcode(version: Version("2.0.0")!, installState: .installed(secondPath), selected: false, icon: nil)
        let selectedPaths = TestLockedBox<[String]>([])
        let continuations = TestLockedBox<[CheckedContinuation<Void, Error>]>([])

        Current.helper.switchXcodePathAsync = { path in
            selectedPaths.withValue { $0.append(path) }
            try await withCheckedThrowingContinuation { continuation in
                continuations.withValue { $0.append(continuation) }
            }
        }
        Current.shell.xcodeSelectPrintPath = {
            ProcessOutput(status: 0, out: secondPath.string, err: "")
        }

        subject.select(xcode: firstXcode, shouldPrepareUserForHelperInstallation: false)
        for _ in 0..<100 where continuations.read({ $0.count }) < 1 {
            await Task.yield()
        }
        let firstTask = try XCTUnwrap(subject.selectTask)
        XCTAssertEqual(selectedPaths.read { $0 }, [firstPath.string])

        subject.select(xcode: secondXcode, shouldPrepareUserForHelperInstallation: false)
        for _ in 0..<100 where continuations.read({ $0.count }) < 2 {
            await Task.yield()
        }
        let replacementTask = try XCTUnwrap(subject.selectTask)
        XCTAssertEqual(selectedPaths.read { $0 }, [firstPath.string, secondPath.string])

        continuations.read { $0[0] }.resume()
        await firstTask.value
        XCTAssertNotNil(subject.selectTask)

        continuations.read { $0[1] }.resume()
        await replacementTask.value
        XCTAssertNil(subject.selectTask)
        XCTAssertNil(subject.selectTaskID)
        XCTAssertEqual(subject.selectedXcodePath, secondPath.string)
    }

    func test_Uninstall_MissingXcodePresentsFileNotFoundError() async throws {
        let missingPath = try XCTUnwrap(Path("/Applications/Xcode-Missing.app"))
        let xcode = Xcode(version: Version("15.0.0")!, installState: .installed(missingPath), selected: false, icon: nil)
        let didTryToTrashItem = TestLockedBox(false)
        Current.files.contentsAtPath = { _ in nil }
        Current.files.trashItem = { _ in
            didTryToTrashItem.withValue { $0 = true }
            return URL(fileURLWithPath: "\(NSHomeDirectory())/.Trash")
        }

        subject.uninstall(xcode: xcode)
        let uninstallTask = try XCTUnwrap(subject.uninstallTask)
        await uninstallTask.value

        guard case let .generic(title, message) = subject.presentedAlert else {
            return XCTFail("Expected generic uninstall error alert")
        }
        XCTAssertEqual(title, localizeString("Alert.Uninstall.Error.Title"))
        XCTAssertEqual(
            message,
            String(format: localizeString("Alert.Uninstall.Error.Message.FileNotFound"), missingPath.string)
        )
        XCTAssertFalse(didTryToTrashItem.read { $0 })
    }

    func test_Uninstall_RefreshesInstalledXcodeList() async throws {
        let installedPath = try XCTUnwrap(Path("/Applications/Xcode-0.0.0.app"))
        let version = try XCTUnwrap(Version("0.0.0"))
        subject.availableXcodes = [
            AvailableXcode(version: version, url: URL(string: "https://apple.com/xcode.xip")!, filename: "mock.xip", releaseDate: nil)
        ]
        subject.allXcodes = [
            Xcode(version: version, installState: .installed(installedPath), selected: true, icon: nil)
        ]
        Current.files.installedXcodes = { _ in [] }
        Current.shell.xcodeSelectPrintPath = {
            ProcessOutput(status: 0, out: "", err: "")
        }

        subject.uninstall(xcode: subject.allXcodes[0])
        let uninstallTask = try XCTUnwrap(subject.uninstallTask)
        await uninstallTask.value

        XCTAssertEqual(subject.allXcodes[0].installState, .notInstalled)
    }

    func test_Signout_RemovesCookiesFromDownloadSession() throws {
        let session = URLSession(configuration: .ephemeral)
        Current.network.session = session
        let cookie = try HTTPCookie.xcodesTestCookie(name: "ADCDownloadAuth")
        session.configuration.httpCookieStorage?.setCookie(cookie)
        XCTAssertEqual(session.configuration.httpCookieStorage?.cookies?.contains(cookie), true)

        subject.signOut()

        XCTAssertEqual(session.configuration.httpCookieStorage?.cookies?.contains(cookie), false)
    }

    func test_Signout_RemovesCookiesAfterDownloadSessionIsReplaced() throws {
        let initialSession = URLSession(configuration: .ephemeral)
        let replacementSession = URLSession(configuration: .ephemeral)
        Current.network.session = initialSession
        Current.network.session = replacementSession
        let cookie = try HTTPCookie.xcodesTestCookie(name: "FASTLANE_SESSION")
        replacementSession.configuration.httpCookieStorage?.setCookie(cookie)
        XCTAssertEqual(replacementSession.configuration.httpCookieStorage?.cookies?.contains(cookie), true)

        subject.signOut()

        XCTAssertEqual(initialSession.configuration.httpCookieStorage?.cookies?.contains(cookie), false)
        XCTAssertEqual(replacementSession.configuration.httpCookieStorage?.cookies?.contains(cookie), false)
    }

    func test_NetworkSessionReplacementUpdatesLoginClientSession() {
        let initialSession = URLSession(configuration: .ephemeral)
        let replacementSession = URLSession(configuration: .ephemeral)

        Current.network.session = initialSession
        XCTAssertTrue(Current.network.loginClient.urlSession === initialSession)

        Current.network.session = replacementSession
        XCTAssertTrue(Current.network.loginClient.urlSession === replacementSession)
    }

    func test_RefreshInstalledRuntimes_UsesLiveSimctlOutput() async throws {
        let identifier = "97772E90-7BD1-4882-9C51-782E62E0AF4F"
        let json = """
        {
          "\(identifier)": {
            "build": "23F72",
            "deletable": true,
            "identifier": "\(identifier)",
            "kind": "Disk Image",
            "lastUsedAt": null,
            "path": "/Library/Developer/CoreSimulator/Images/iOS_26_5.dmg",
            "platformIdentifier": "com.apple.platform.iphonesimulator",
            "runtimeBundlePath": "/Library/Developer/CoreSimulator/Volumes/iOS_23F72/Library/Developer/CoreSimulator/Profiles/Runtimes/iOS 26.5.simruntime",
            "runtimeIdentifier": "com.apple.CoreSimulator.SimRuntime.iOS-26-5",
            "signatureState": "Verified",
            "state": "Ready",
            "version": "26.5",
            "sizeBytes": 9148280348,
            "supportedArchitectures": ["arm64"]
          }
        }
        """
        subject.runtimeService = Self.runtimeService(installedRuntimesJSON: json)

        try await subject.refreshInstalledRuntimes()

        XCTAssertEqual(subject.installedRuntimes.map(\.uuid), [identifier])
        XCTAssertEqual(subject.installedRuntimes.first?.runtimeInfo.build, "23F72")
        XCTAssertEqual(subject.installedRuntimes.first?.runtimeInfo.supportedArchitectures, [.arm64])
        XCTAssertEqual(
            subject.installedRuntimes.first?.path["relative"],
            "/Library/Developer/CoreSimulator/Images/iOS_26_5.dmg"
        )
    }

    func test_RefreshInstalledRuntimes_OlderRequestCannotOverwriteNewerState() async throws {
        let staleJSON = """
        {
          "97772E90-7BD1-4882-9C51-782E62E0AF4F": {
            "build": "23F72",
            "deletable": true,
            "identifier": "97772E90-7BD1-4882-9C51-782E62E0AF4F",
            "kind": "Disk Image",
            "lastUsedAt": null,
            "path": "/Library/Developer/CoreSimulator/Images/iOS_26_5.dmg",
            "platformIdentifier": "com.apple.platform.iphonesimulator",
            "runtimeBundlePath": "/Library/Developer/CoreSimulator/Volumes/iOS_23F72/Library/Developer/CoreSimulator/Profiles/Runtimes/iOS 26.5.simruntime",
            "runtimeIdentifier": "com.apple.CoreSimulator.SimRuntime.iOS-26-5",
            "signatureState": "Verified",
            "state": "Ready",
            "version": "26.5",
            "sizeBytes": 9148280348,
            "supportedArchitectures": ["arm64"]
          }
        }
        """
        let continuations = TestLockedBox<[CheckedContinuation<ProcessOutput, Error>]>([])
        subject.runtimeService = Self.runtimeService(installedRuntimesOutput: {
            try await withCheckedThrowingContinuation { continuation in
                continuations.withValue { $0.append(continuation) }
            }
        })

        let staleRefresh = Task { @MainActor in
            try await self.subject.refreshInstalledRuntimes()
        }
        for _ in 0..<100 where continuations.read({ $0.count }) < 1 {
            await Task.yield()
        }

        let currentRefresh = Task { @MainActor in
            try await self.subject.refreshInstalledRuntimes()
        }
        for _ in 0..<100 where continuations.read({ $0.count }) < 2 {
            await Task.yield()
        }

        continuations.read { $0[1] }.resume(
            returning: ProcessOutput(status: 0, out: "{}", err: "")
        )
        try await currentRefresh.value
        continuations.read { $0[0] }.resume(
            returning: ProcessOutput(status: 0, out: staleJSON, err: "")
        )
        try await staleRefresh.value

        XCTAssertTrue(subject.installedRuntimes.isEmpty)
    }

    func test_InstalledPlatformRuntimes_RejectsArchitectureMismatch() throws {
        let armRuntime = try Self.downloadableRuntime(architectures: [.arm64])
        let x86Runtime = try Self.downloadableRuntime(architectures: [.x86_64])
        subject.downloadableRuntimes = [x86Runtime, armRuntime]
        subject.installedRuntimes = [
            CoreSimulatorImage(
                uuid: "runtime-uuid",
                path: ["relative": "/Library/Developer/CoreSimulator/Images/runtime.dmg"],
                runtimeInfo: CoreSimulatorRuntimeInfo(
                    build: armRuntime.simulatorVersion.buildUpdate,
                    supportedArchitectures: [.arm64]
                )
            )
        ]

        let runtimes = subject.installedPlatformRuntimes()

        XCTAssertEqual(runtimes.count, 1)
        XCTAssertEqual(runtimes.first?.architectures, [.arm64])
    }

    func test_DownloadRuntimeViaXcodeBuild_ClearsRuntimeTaskWhenComplete() async throws {
        let runtime = try Self.downloadableRuntime()
        subject.downloadableRuntimes = [runtime]
        Current.shell.downloadRuntime = { _, _, _ in
            let (stream, continuation) = AsyncThrowingStream.makeStream(of: Progress.self, throwing: Error.self)
            continuation.finish()
            return stream
        }

        subject.downloadRuntimeViaXcodeBuild(runtime: runtime)
        let task = try XCTUnwrap(subject.runtimeTasks[runtime.identifier])
        try await task.value

        XCTAssertNil(subject.runtimeTasks[runtime.identifier])
        XCTAssertNil(subject.runtimeTaskIDs[runtime.identifier])
        XCTAssertEqual(subject.downloadableRuntimes.first?.installState, .installed)
    }

    func test_DownloadRuntimeViaXcodeBuild_OldTaskDoesNotClearReplacementTask() async throws {
        let runtime = try Self.downloadableRuntime()
        subject.downloadableRuntimes = [runtime]
        let continuations = TestLockedBox<[AsyncThrowingStream<Progress, Error>.Continuation]>([])
        Current.shell.downloadRuntime = { _, _, _ in
            let (stream, continuation) = AsyncThrowingStream.makeStream(of: Progress.self, throwing: Error.self)
            continuations.withValue { $0.append(continuation) }
            return stream
        }

        subject.downloadRuntimeViaXcodeBuild(runtime: runtime)
        for _ in 0..<100 where continuations.read({ $0.count }) < 1 {
            await Task.yield()
        }
        let firstTask = try XCTUnwrap(subject.runtimeTasks[runtime.identifier])
        XCTAssertEqual(continuations.read { $0.count }, 1)

        subject.downloadRuntimeViaXcodeBuild(runtime: runtime)
        for _ in 0..<100 where continuations.read({ $0.count }) < 2 {
            await Task.yield()
        }
        let replacementTask = try XCTUnwrap(subject.runtimeTasks[runtime.identifier])
        XCTAssertEqual(continuations.read { $0.count }, 2)

        continuations.read { $0[0] }.finish()
        try await firstTask.value
        XCTAssertNotNil(subject.runtimeTasks[runtime.identifier])

        continuations.read { $0[1] }.finish()
        try await replacementTask.value
        XCTAssertNil(subject.runtimeTasks[runtime.identifier])
        XCTAssertNil(subject.runtimeTaskIDs[runtime.identifier])
    }

    func test_ConfirmDeleteRuntime_OldTaskDoesNotClearReplacementTask() async throws {
        let runtime = try Self.downloadableRuntime()
        let installedRuntime = CoreSimulatorImage(
            uuid: "runtime-uuid",
            path: ["relative": "/Library/Developer/CoreSimulator/Images/runtime.dmg"],
            runtimeInfo: CoreSimulatorRuntimeInfo(build: runtime.simulatorVersion.buildUpdate)
        )
        let deletedIdentifiers = TestLockedBox<[String]>([])
        let continuations = TestLockedBox<[CheckedContinuation<ProcessOutput, Error>]>([])
        subject = AppState(
            runtimeService: Self.runtimeService(deleteRuntimeOutput: { identifier in
                deletedIdentifiers.withValue { $0.append(identifier) }
                return try await withCheckedThrowingContinuation { continuation in
                    continuations.withValue { $0.append(continuation) }
                }
            })
        )
        subject.installedRuntimes = [installedRuntime]

        subject.confirmDeleteRuntime(runtime: runtime)
        for _ in 0..<100 where continuations.read({ $0.count }) < 1 {
            await Task.yield()
        }
        let firstTask = try XCTUnwrap(subject.deleteRuntimeTask)
        XCTAssertEqual(deletedIdentifiers.read { $0 }, [installedRuntime.uuid])

        subject.confirmDeleteRuntime(runtime: runtime)
        for _ in 0..<100 where continuations.read({ $0.count }) < 2 {
            await Task.yield()
        }
        let replacementTask = try XCTUnwrap(subject.deleteRuntimeTask)
        XCTAssertEqual(deletedIdentifiers.read { $0 }, [installedRuntime.uuid, installedRuntime.uuid])

        continuations.read { $0[0] }.resume(returning: ProcessOutput(status: 0, out: "", err: ""))
        await firstTask.value
        XCTAssertNotNil(subject.deleteRuntimeTask)

        continuations.read { $0[1] }.resume(returning: ProcessOutput(status: 0, out: "", err: ""))
        await replacementTask.value
        XCTAssertNil(subject.deleteRuntimeTask)
        XCTAssertNil(subject.deleteRuntimeTaskID)
    }

    func test_ConfirmDeleteRuntime_PresentsPlatformAlertOnError() async throws {
        let runtime = try Self.downloadableRuntime()

        subject.confirmDeleteRuntime(runtime: runtime)
        let task = try XCTUnwrap(subject.deleteRuntimeTask)
        await task.value

        guard case let .generic(title, message) = subject.presentedPlatformAlert else {
            return XCTFail("Expected generic platform alert")
        }
        XCTAssertEqual(title, "Error")
        XCTAssertEqual(message, "No simulator found with \(runtime.identifier)")
        XCTAssertNil(subject.deleteRuntimeTask)
        XCTAssertNil(subject.deleteRuntimeTaskID)
    }

    func test_DeleteRuntime_RefreshesInstalledRuntimesAfterSuccess() async throws {
        let runtime = try Self.downloadableRuntime()
        let installedRuntime = CoreSimulatorImage(
            uuid: "runtime-uuid",
            path: ["relative": "/Library/Developer/CoreSimulator/Images/runtime.dmg"],
            runtimeInfo: CoreSimulatorRuntimeInfo(build: runtime.simulatorVersion.buildUpdate)
        )
        subject = AppState(runtimeService: Self.runtimeService())
        subject.installedRuntimes = [installedRuntime]

        try await subject.deleteRuntime(runtime: runtime)

        XCTAssertTrue(subject.installedRuntimes.isEmpty)
    }

    func test_ConfirmDeleteRuntime_RefreshesStaleStateOnError() async throws {
        let runtime = try Self.downloadableRuntime()
        let installedRuntime = CoreSimulatorImage(
            uuid: "runtime-uuid",
            path: ["relative": "/Library/Developer/CoreSimulator/Images/runtime.dmg"],
            runtimeInfo: CoreSimulatorRuntimeInfo(build: runtime.simulatorVersion.buildUpdate)
        )
        subject = AppState(
            runtimeService: Self.runtimeService(deleteRuntimeOutput: { _ in
                throw XcodesKitError("No matching images found to delete")
            })
        )
        subject.installedRuntimes = [installedRuntime]

        subject.confirmDeleteRuntime(runtime: runtime)
        let task = try XCTUnwrap(subject.deleteRuntimeTask)
        await task.value

        XCTAssertTrue(subject.installedRuntimes.isEmpty)
        guard case let .generic(title, message) = subject.presentedPlatformAlert else {
            return XCTFail("Expected generic platform alert")
        }
        XCTAssertEqual(title, "Error")
        XCTAssertEqual(message, "No matching images found to delete")
    }

    func test_InstallWithoutLogin_OldTaskDoesNotClearReplacementTask() async throws {
        let version = Version("0.0.0")!
        let availableXcode = AvailableXcode(
            version: version,
            url: URL(string: "https://apple.com/xcode.xip")!,
            filename: "mock.xip",
            releaseDate: nil
        )
        subject.availableXcodes = [availableXcode]
        subject.allXcodes = [
            .init(version: version, installState: .notInstalled, selected: false, icon: nil)
        ]
        subject.helperInstallState = .installed

        Current.defaults.string = { key in
            key == "downloader" ? "urlSession" : nil
        }
        Current.files.fileExistsAtPath = { path in
            path != (Path.xcodesApplicationSupport/"Xcode-0.0.0.xip").string
        }
        Current.shell.codesignVerify = { _ in
            ProcessOutput(
                status: 0,
                out: "",
                err: """
                    TeamIdentifier=\(XcodeTeamIdentifier)
                    Authority=\(XcodeCertificateAuthority[0])
                    Authority=\(XcodeCertificateAuthority[1])
                    Authority=\(XcodeCertificateAuthority[2])
                    """
            )
        }

        let continuations = TestLockedBox<[CheckedContinuation<(saveLocation: URL, response: URLResponse), Error>]>([])
        Current.network.downloadTaskAsync = { url, saveLocation, _ in
            (
                Progress(),
                Task {
                    try await withCheckedThrowingContinuation { continuation in
                        continuations.withValue { $0.append(continuation) }
                    }
                }
            )
        }

        subject.installWithoutLogin(id: availableXcode.xcodeID)
        for _ in 0..<100 where continuations.read({ $0.count }) < 1 {
            await Task.yield()
        }
        let firstTask = try XCTUnwrap(subject.installationTasks[availableXcode.xcodeID])
        XCTAssertEqual(continuations.read { $0.count }, 1)

        subject.installWithoutLogin(id: availableXcode.xcodeID)
        for _ in 0..<100 where continuations.read({ $0.count }) < 2 {
            await Task.yield()
        }
        let replacementTask = try XCTUnwrap(subject.installationTasks[availableXcode.xcodeID])
        XCTAssertEqual(continuations.read { $0.count }, 2)

        continuations.read { $0[0] }.resume(returning: Self.downloadResult(for: availableXcode))
        await firstTask.value
        XCTAssertNotNil(subject.installationTasks[availableXcode.xcodeID])

        continuations.read { $0[1] }.resume(returning: Self.downloadResult(for: availableXcode))
        await replacementTask.value
        XCTAssertNil(subject.installationTasks[availableXcode.xcodeID])
        XCTAssertNil(subject.installationTaskIDs[availableXcode.xcodeID])
    }

    func test_Install_RetryingDownloadDoesNotAttachSameProgressTwice() async throws {
        let version = Version("0.0.0")!
        let availableXcode = AvailableXcode(
            version: version,
            url: URL(string: "https://apple.com/xcode.xip")!,
            filename: "mock.xip",
            releaseDate: nil
        )
        subject.allXcodes = [
            .init(version: version, installState: .notInstalled, selected: false, icon: nil)
        ]
        subject.helperInstallState = .installed

        Current.files.fileExistsAtPath = { path in
            path != (Path.xcodesApplicationSupport/"Xcode-0.0.0.xip").string
        }
        Current.shell.codesignVerify = { _ in
            ProcessOutput(
                status: 0,
                out: "",
                err: """
                    TeamIdentifier=\(XcodeTeamIdentifier)
                    Authority=\(XcodeCertificateAuthority[0])
                    Authority=\(XcodeCertificateAuthority[1])
                    Authority=\(XcodeCertificateAuthority[2])
                    """
            )
        }

        let progress = Progress(totalUnitCount: 100)
        let attempts = TestLockedBox(0)
        Current.network.downloadTaskAsync = { url, saveLocation, _ in
            let attempt = attempts.withValue {
                $0 += 1
                return $0
            }
            return (
                progress,
                Task {
                    await Task.yield()
                    if attempt == 1 {
                        throw NSError(
                            domain: NSURLErrorDomain,
                            code: NSURLErrorNetworkConnectionLost,
                            userInfo: [NSURLSessionDownloadTaskResumeData: Data("resume".utf8)]
                        )
                    }

                    return (
                        saveLocation: saveLocation,
                        response: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
                    )
                }
            )
        }

        let installedXcode = try await subject.installAsync(
            .version(availableXcode),
            downloader: .urlSession,
            attemptNumber: 0
        )

        XCTAssertEqual(attempts.read { $0 }, 2)
        XCTAssertTrue(installedXcode.version.isEquivalent(to: version))
    }
    
    func test_Install_FullHappyPath_Apple() async throws {
        // Available xcode doesn't necessarily have build identifier
        subject.allXcodes = [
            .init(version: Version("0.0.0")!, installState: .notInstalled, selected: false, icon: nil),
            .init(version: Version("0.0.0-Beta.1")!, installState: .notInstalled, selected: false, icon: nil),
            .init(version: Version("0.0.0-Beta.2")!, installState: .notInstalled, selected: false, icon: nil),
        ]
        
        // It hasn't been downloaded
        Current.files.fileExistsAtPath = { path in
            if path == (Path.xcodesApplicationSupport/"Xcode-0.0.0.xip").string {
                return false
            }
            else {
                return true
            }
        }
        Xcodes.Current.network.validateSessionAsync = { }
        Xcodes.Current.network.loadData = { urlRequest in
            if urlRequest.url! == URLRequest.developerDownloads.url! {
                let downloads = Downloads(resultCode: 0, resultsString: nil, downloads: [Download(name: "Xcode 0.0.0", files: [Download.File(remotePath: "https://apple.com/xcode.xip", fileSize: 9484444)], dateModified: Date())])
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .formatted(.downloadsDateModified)
                let downloadsData = try! encoder.encode(downloads)
                return (
                    data: downloadsData,
                    response: HTTPURLResponse(url: urlRequest.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                )
            }

            return (
                data: Data(),
                response: HTTPURLResponse(url: urlRequest.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            )
        }
        // It downloads and updates progress
        let progress = Progress(totalUnitCount: 100)
        Current.network.downloadTaskAsync = { url, saveLocation, _ in
            return (
                progress,
                Task {
                    await Task.yield()
                    await MainActor.run {
                        for i in 0...100 {
                            progress.completedUnitCount = Int64(i)
                        }
                    }
                    return (
                        saveLocation: saveLocation,
                        response: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
                    )
                }
            )
        }
        // It's a valid .app
        Current.shell.codesignVerify = { _ in
            ProcessOutput(
                    status: 0,
                    out: "",
                    err: """
                        TeamIdentifier=\(XcodeTeamIdentifier)
                        Authority=\(XcodeCertificateAuthority[0])
                        Authority=\(XcodeCertificateAuthority[1])
                        Authority=\(XcodeCertificateAuthority[2])
                        """)
        }
        // Helper is already installed
        subject.helperInstallState = .installed

        let allXcodeInstallStates = try await recordAllXcodeInstallStates {
            _ = try await subject.installAsync(
                .version(AvailableXcode(version: Version("0.0.0")!, url: URL(string: "https://apple.com/xcode.xip")!, filename: "mock.xip", releaseDate: nil)),
                downloader: .urlSession,
                attemptNumber: 0
            )
        }

        XCTAssertEqual(
            allXcodeInstallStates,
            [
                [XcodeInstallState.notInstalled, .notInstalled, .notInstalled], 
                [.installing(.downloading(progress: progress)), .notInstalled, .notInstalled],
                [.installing(.unarchiving), .notInstalled, .notInstalled],
                [.installing(.moving(destination: "/Applications/Xcode-0.0.0.app")), .notInstalled, .notInstalled],
                [.installing(.trashingArchive), .notInstalled, .notInstalled],
                [.installing(.checkingSecurity), .notInstalled, .notInstalled],
                [.installing(.finishing), .notInstalled, .notInstalled],
                [.installed(Path("/Applications/Xcode-0.0.0.app")!), .notInstalled, .notInstalled]
            ]
        )
    }

    private static func downloadableRuntime(
        architectures: [Architecture]? = nil
    ) throws -> DownloadableRuntime {
        let encodedArchitectures: String
        if let architectures {
            encodedArchitectures = "[\(architectures.map { "\"\($0.rawValue)\"" }.joined(separator: ","))]"
        } else {
            encodedArchitectures = "null"
        }
        let json = """
        {
          "category": "simulator",
          "simulatorVersion": {
            "buildUpdate": "20A360",
            "version": "16.0"
          },
          "source": "https://example.com/iOS_16_Runtime.dmg",
          "architectures": \(encodedArchitectures),
          "dictionaryVersion": 1,
          "contentType": "diskImage",
          "platform": "com.apple.platform.iphoneos",
          "identifier": "com.apple.CoreSimulator.SimRuntime.iOS-16-0",
          "version": "16.0",
          "fileSize": 42,
          "hostRequirements": null,
          "name": "iOS 16.0",
          "authentication": null
        }
        """
        return try JSONDecoder().decode(DownloadableRuntime.self, from: Data(json.utf8))
    }

    private static func downloadResult(for availableXcode: AvailableXcode) -> (saveLocation: URL, response: URLResponse) {
        (
            saveLocation: (Path.xcodesApplicationSupport/"Xcode-\(availableXcode.version).xip").url,
            response: HTTPURLResponse(url: availableXcode.url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        )
    }

    private static func runtimeService(
        installedRuntimesJSON: String = "{}",
        installedRuntimesOutput: (@Sendable () async throws -> ProcessOutput)? = nil,
        deleteRuntimeOutput: @escaping @Sendable (String) async throws -> ProcessOutput = { _ in
            ProcessOutput(status: 0, out: "", err: "")
        }
    ) -> RuntimeService {
        RuntimeService(
            loadData: { request in
                (Data(), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            },
            contentsAtPath: { _ in
                Data("""
                <?xml version="1.0" encoding="UTF-8"?>
                <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
                <plist version="1.0">
                <dict>
                    <key>images</key>
                    <array/>
                </dict>
                </plist>
                """.utf8)
            },
            installedRuntimesOutput: {
                if let installedRuntimesOutput {
                    return try await installedRuntimesOutput()
                }
                return ProcessOutput(status: 0, out: installedRuntimesJSON, err: "")
            },
            installRuntimeImageOutput: { _ in
                ProcessOutput(status: 0, out: "", err: "")
            },
            mountDMGOutput: { _ in
                ProcessOutput(status: 0, out: "", err: "")
            },
            unmountDMGOutput: { _ in
                ProcessOutput(status: 0, out: "", err: "")
            },
            deleteRuntimeOutput: deleteRuntimeOutput
        )
    }
    
    func test_Install_FullHappyPath_XcodeReleases() async throws {
        // Available xcode has build identifier
        subject.allXcodes = [
            .init(version: Version("0.0.0+ABC123")!, installState: .notInstalled, selected: false, icon: nil),
            .init(version: Version("0.0.0-Beta.1+DEF456")!, installState: .notInstalled, selected: false, icon: nil),
            .init(version: Version("0.0.0-Beta.2+GHI789")!, installState: .notInstalled, selected: false, icon: nil)
        ]
        
        // It hasn't been downloaded
        Current.files.fileExistsAtPath = { path in
            if path == (Path.xcodesApplicationSupport/"Xcode-0.0.0.xip").string {
                return false
            }
            else {
                return true
            }
        }
        Xcodes.Current.network.loadData = { urlRequest in
            if urlRequest.url! == URLRequest.developerDownloads.url! {
                let downloads = Downloads(resultCode: 0, resultsString: nil, downloads: [Download(name: "Xcode 0.0.0", files: [Download.File(remotePath: "https://apple.com/xcode.xip", fileSize: 9494944)], dateModified: Date())])
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .formatted(.downloadsDateModified)
                let downloadsData = try! encoder.encode(downloads)
                return (
                    data: downloadsData,
                    response: HTTPURLResponse(url: urlRequest.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                )
            }

            return (
                data: Data(),
                response: HTTPURLResponse(url: urlRequest.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            )
        }
        // It downloads and updates progress
        let progress = Progress(totalUnitCount: 100)
        Current.network.downloadTaskAsync = { url, saveLocation, _ in
            return (
                progress,
                Task {
                    await Task.yield()
                    await MainActor.run {
                        for i in 0...100 {
                            progress.completedUnitCount = Int64(i)
                        }
                    }
                    return (
                        saveLocation: saveLocation,
                        response: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
                    )
                }
            )
        }
        // It's a valid .app
        Current.shell.codesignVerify = { _ in
            ProcessOutput(
                    status: 0,
                    out: "",
                    err: """
                        TeamIdentifier=\(XcodeTeamIdentifier)
                        Authority=\(XcodeCertificateAuthority[0])
                        Authority=\(XcodeCertificateAuthority[1])
                        Authority=\(XcodeCertificateAuthority[2])
                        """)
        }
        // Helper is already installed
        subject.helperInstallState = .installed

        let allXcodeInstallStates = try await recordAllXcodeInstallStates {
            _ = try await subject.installAsync(
                .version(AvailableXcode(version: Version("0.0.0")!, url: URL(string: "https://apple.com/xcode.xip")!, filename: "mock.xip", releaseDate: nil)),
                downloader: .urlSession,
                attemptNumber: 0
            )
        }

        XCTAssertEqual(
            allXcodeInstallStates,
            [
                [XcodeInstallState.notInstalled, .notInstalled, .notInstalled], 
                [.installing(.downloading(progress: progress)), .notInstalled, .notInstalled],
                [.installing(.unarchiving), .notInstalled, .notInstalled],
                [.installing(.moving(destination: "/Applications/Xcode-0.0.0.app")), .notInstalled, .notInstalled],
                [.installing(.trashingArchive), .notInstalled, .notInstalled],
                [.installing(.checkingSecurity), .notInstalled, .notInstalled],
                [.installing(.finishing), .notInstalled, .notInstalled],
                [.installed(Path("/Applications/Xcode-0.0.0.app")!), .notInstalled, .notInstalled]
            ]
        )
    }

    func test_Install_NotEnoughFreeSpace() async throws {
        Current.shell.unxip = { _ in
            throw ProcessExecutionError(
                    process: Process(),
                    standardOutput: "xip: signing certificate was \"Development Update\" (validation not attempted)", 
                    standardError: "xip: error: The archive “Xcode-12.4.0-Release.Candidate+12D4e.xip” can’t be expanded because the selected volume doesn’t have enough free space."
            )
        }
        let archiveURL = URL(fileURLWithPath: "/Users/user/Library/Application Support/Xcode-0.0.0.xip")
        
        do {
            _ = try await subject.installArchivedXcodeAsync(
                AvailableXcode(
                    version: Version("0.0.0")!,
                    url: URL(string: "https://developer.apple.com")!,
                    filename: "Xcode-0.0.0.xip",
                    releaseDate: nil
                ),
                at: archiveURL
            )
            XCTFail()
        } catch let error as InstallationError {
            XCTAssertEqual(
                error,
                InstallationError.notEnoughFreeSpaceToExpandArchive(archivePath: Path(url: archiveURL)!, 
                                                                    version: Version("0.0.0")!)
            )
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func recordAllXcodeInstallStates(during operation: () async throws -> Void) async throws -> [[XcodeInstallState]] {
        var states: [[XcodeInstallState]] = []
        var cancellable: AnyCancellable?
        cancellable = subject.$allXcodes.sink { xcodes in
            states.append(xcodes.map(\.installState))
        }
        defer { cancellable?.cancel() }

        try await operation()
        return states
    }
}

private extension HTTPCookie {
    static func xcodesTestCookie(name: String) throws -> HTTPCookie {
        try XCTUnwrap(HTTPCookie(properties: [
            .domain: "developer.apple.com",
            .path: "/",
            .name: name,
            .value: "test-cookie",
            .secure: "TRUE",
            .expires: Date.distantFuture
        ]))
    }
}
