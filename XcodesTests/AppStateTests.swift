import AppKit
import Combine
import AsyncNetworkService
@preconcurrency import Path
import struct SwiftUI.KeyboardShortcut
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

private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (Data, HTTPURLResponse)

    private nonisolated(unsafe) static var handler: Handler?

    static func session(handler: @escaping Handler) -> URLSession {
        self.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (data, response) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

@MainActor
class AppStateTests: XCTestCase {
    var subject: AppState!
    
    override func setUpWithError() throws {
        Current = .mock
        syncXcodesKitMocks()
        subject = AppState()
    }

    func test_NewlyAvailableXcodes_IgnoresInitialLoad() {
        let initial = makeAvailableXcode(version: "27.0.0")

        XCTAssertTrue(AppState.newlyAvailableXcodes(oldXcodes: [], newXcodes: [initial]).isEmpty)
    }

    func test_NewlyAvailableXcodes_DetectsIdentityWhenCountDoesNotGrow() {
        let removed = makeAvailableXcode(version: "26.4.0")
        let retained = makeAvailableXcode(version: "26.5.0")
        let added = makeAvailableXcode(version: "27.0.0")

        let result = AppState.newlyAvailableXcodes(oldXcodes: [removed, retained], newXcodes: [retained, added])

        XCTAssertEqual(result.map(\.xcodeID), [added.xcodeID])
    }

    func test_NewlyAvailableXcodes_IgnoresDuplicateIdentity() {
        let existing = makeAvailableXcode(version: "27.0.0", filename: "Xcode.xip")
        let duplicate = makeAvailableXcode(version: "27.0.0", filename: "Xcode-copy.xip")

        XCTAssertTrue(AppState.newlyAvailableXcodes(oldXcodes: [existing], newXcodes: [existing, duplicate]).isEmpty)
    }

    func test_NewlyAvailableXcodes_TreatsArchitectureAsIdentity() {
        let universal = makeAvailableXcode(
            version: "27.0.0",
            architectures: [.arm64, .x86_64]
        )
        let appleSilicon = makeAvailableXcode(
            version: "27.0.0",
            architectures: [.arm64]
        )

        let result = AppState.newlyAvailableXcodes(oldXcodes: [universal], newXcodes: [universal, appleSilicon])

        XCTAssertEqual(result.map(\.xcodeID), [appleSilicon.xcodeID])
    }

    func test_CommandShortcuts_AreDistinctAndLinkUsesL() {
        XCTAssertEqual(
            Set(XcodeCommandShortcuts.all).count,
            XcodeCommandShortcuts.all.count
        )
        XCTAssertEqual(
            XcodeCommandShortcuts.createSymbolicLink,
            KeyboardShortcut("l", modifiers: [.command, .option])
        )
    }

    func test_CopyPath_WritesOnlyPlainText() throws {
        let path = try XCTUnwrap(Path("/Applications/Xcode 27.app"))
        let xcode = Xcode(
            version: Version("27.0.0")!,
            installState: .installed(path),
            selected: false,
            icon: nil
        )
        let pasteboard = NSPasteboard(name: .init("AppStateTests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }

        subject.copyPath(xcode: xcode, pasteboard: pasteboard)

        XCTAssertEqual(pasteboard.string(forType: .string), path.string)
        XCTAssertNil(pasteboard.string(forType: .URL))
        XCTAssertEqual(pasteboard.readObjects(forClasses: [NSURL.self])?.isEmpty, true)
    }

    func test_KeychainUsesPurposeSpecificAppleAccountService() {
        XCTAssertEqual(Keychain.service, "dev.jacobcx.Xcodes.apple-account")
    }

    private func makeAvailableXcode(
        version: String,
        filename: String = "Xcode.xip",
        architectures: [Architecture]? = nil
    ) -> AvailableXcode {
        AvailableXcode(
            version: Version(version)!,
            url: URL(string: "https://example.com/\(filename)")!,
            filename: filename,
            releaseDate: nil,
            architectures: architectures
        )
    }

    func test_AutoInstallWaitsForInitialInstalledXcodeScan() {
        Current.defaults.get = { key in
            key == "autoInstallation" ? AutoInstallationType.newestBeta.rawValue : nil
        }

        subject.availableXcodes = [
            AvailableXcode(
                version: Version("27.0.0-Beta.5")!,
                url: URL(string: "https://apple.com/Xcode-27.0.0-Beta.5.xip")!,
                filename: "Xcode-27.0.0-Beta.5.xip",
                releaseDate: nil
            )
        ]

        XCTAssertTrue(subject.installationTasks.isEmpty)
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

    func test_AuthenticationPolicy_HandlesAuthenticationHTTPStatusCodes() async throws {
        for statusCode in [502, 503, 504, 401] {
            let attempts = TestLockedBox(0)
            let response = try XCTUnwrap(HTTPURLResponse(
                url: URL(string: "https://idmsa.apple.com/appleauth/auth")!,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: nil
            ))
            let failure = AuthenticationError.badStatusCode(statusCode: statusCode, data: nil, response: response)

            do {
                let _: String = try await AuthenticationRequestPolicy(delayBeforeRetry: .zero).perform {
                    attempts.withValue { $0 += 1 }
                    throw failure
                }
                XCTFail("Expected authentication HTTP error")
            } catch {
                if statusCode == 401 {
                    XCTAssertEqual(error as? AuthenticationError, failure)
                    XCTAssertEqual(attempts.read { $0 }, 1)
                } else {
                    XCTAssertEqual(error as? AuthenticationRequestError, .serviceTemporarilyUnavailable(statusCode: statusCode))
                    XCTAssertEqual(attempts.read { $0 }, 3)
                }
                XCTAssertFalse(AuthenticationRequestPolicy.shouldClearCredentials(after: error))
            }
        }
    }

    func test_AuthenticationPolicy_RetriesTransientServiceKeyFailureUntilSuccess() async throws {
        let attempts = TestLockedBox(0)
        let failure = AuthenticationError.serviceKeyResolutionFailed(attempts: [
            .init(source: .appStoreConnectSignOut, failure: .missingRedirect),
            .init(source: .olympus, failure: .httpStatus(code: 503, bodyPreview: nil))
        ])

        let result = try await AuthenticationRequestPolicy(delayBeforeRetry: .zero).perform {
            let attempt = attempts.withValue { $0 += 1; return $0 }
            if attempt < 3 { throw failure }
            return "authenticated"
        }

        XCTAssertEqual(result, "authenticated")
        XCTAssertEqual(attempts.read { $0 }, 3)
    }

    func test_AuthenticationPolicy_MapsExhaustedServiceKeyFailures() async {
        for statusCode in [502, 503, 504] {
            let attempts = TestLockedBox(0)
            let failure = AuthenticationError.serviceKeyResolutionFailed(attempts: [
                .init(source: .appStoreConnectSignOut, failure: .httpStatus(code: statusCode, bodyPreview: nil)),
                .init(source: .olympus, failure: .missingKey)
            ])

            do {
                let _: String = try await AuthenticationRequestPolicy(delayBeforeRetry: .zero).perform {
                    attempts.withValue { $0 += 1 }
                    throw failure
                }
                XCTFail("Expected temporary service error")
            } catch {
                XCTAssertEqual(error as? AuthenticationRequestError, .serviceTemporarilyUnavailable(statusCode: statusCode))
                XCTAssertEqual(attempts.read { $0 }, 3)
                XCTAssertFalse(AuthenticationRequestPolicy.shouldClearCredentials(after: error))
            }
        }
    }

    func test_AuthenticationPolicy_DoesNotRetryServiceKeyParsingFailures() async {
        let attempts = TestLockedBox(0)
        let failure = AuthenticationError.serviceKeyResolutionFailed(attempts: [
            .init(source: .appStoreConnectSignOut, failure: .invalidRedirect),
            .init(source: .olympus, failure: .missingKey)
        ])

        do {
            let _: String = try await AuthenticationRequestPolicy(delayBeforeRetry: .zero).perform {
                attempts.withValue { $0 += 1 }
                throw failure
            }
            XCTFail("Expected service-key parsing failure")
        } catch {
            XCTAssertEqual(error as? AuthenticationError, failure)
            XCTAssertEqual(attempts.read { $0 }, 1)
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

    func test_AuthenticationPolicy_OnlyRetriesCredentialsForInvalidSession() {
        XCTAssertTrue(
            AuthenticationRequestPolicy.requiresCredentialSignIn(
                after: AuthenticationError.notAuthorized
            )
        )
        XCTAssertTrue(
            AuthenticationRequestPolicy.requiresCredentialSignIn(
                after: AuthenticationError.invalidSession
            )
        )
        XCTAssertFalse(
            AuthenticationRequestPolicy.requiresCredentialSignIn(
                after: AuthenticationRequestError.serviceTemporarilyUnavailable(statusCode: 503)
            )
        )
    }

    func test_ValidateSession_PublishesAuthenticatedState() async throws {
        let session = try makeAppleSession()
        Current.network.validateSessionAsync = { .authenticated(session) }

        let result = try await subject.validateSessionAsync()

        XCTAssertEqual(result, .authenticated(session))
        XCTAssertEqual(subject.authenticationState, .authenticated(session))
    }

    func test_RestoreAuthenticationState_DoesNotReadKeychainForValidSession() async throws {
        let session = try makeAppleSession()
        let keychainReads = TestLockedBox(0)
        Current.network.validateSessionAsync = { .authenticated(session) }
        Current.keychain.getString = { _ in
            keychainReads.withValue { $0 += 1 }
            return "unused"
        }

        await subject.restoreAuthenticationStateAsync()

        XCTAssertEqual(subject.authenticationState, .authenticated(session))
        XCTAssertEqual(keychainReads.read { $0 }, 0)
        XCTAssertFalse(subject.isRestoringAuthenticationState)
    }

    func test_RestoreAuthenticationState_UsesSavedCredentialWithoutRewritingKeychain() async throws {
        let session = try makeAppleSession()
        let keychainReads = TestLockedBox(0)
        let keychainWrites = TestLockedBox(0)
        let receivedCredentials = TestLockedBox<(String, String?)?>(nil)
        Current.defaults.string = { key in
            key == "username" ? "saved@example.com" : nil
        }
        Current.network.validateSessionAsync = {
            throw NetworkError.non200StatusCode(statusCode: 401, data: nil)
        }
        Current.network.authenticationStateAsync = { username, password in
            receivedCredentials.withValue { $0 = (username, password) }
            return .authenticated(session)
        }
        Current.keychain.getString = { key in
            keychainReads.withValue { $0 += 1 }
            return key == "saved@example.com" ? "saved-password" : nil
        }
        Current.keychain.set = { _, _ in
            keychainWrites.withValue { $0 += 1 }
        }

        await subject.restoreAuthenticationStateAsync(
            authenticationRequestPolicy: AuthenticationRequestPolicy(
                maximumAttemptCount: 1,
                delayBeforeRetry: .zero
            )
        )

        XCTAssertEqual(subject.authenticationState, .authenticated(session))
        XCTAssertEqual(keychainReads.read { $0 }, 1)
        XCTAssertEqual(keychainWrites.read { $0 }, 0)
        XCTAssertEqual(receivedCredentials.read { $0 }?.0, "saved@example.com")
        XCTAssertEqual(receivedCredentials.read { $0 }?.1, "saved-password")
    }

    func test_SignInIfNeeded_SharesConcurrentRestoration() async throws {
        let session = try makeAppleSession()
        let validationCalls = TestLockedBox(0)
        let keychainReads = TestLockedBox(0)
        let authenticationCalls = TestLockedBox(0)
        let firstValidationStarted = expectation(description: "first validation started")
        let firstValidation = TestLockedBox<CheckedContinuation<AuthenticationState, Error>?>(nil)
        Current.defaults.string = { key in
            key == "username" ? "saved@example.com" : nil
        }
        Current.network.validateSessionAsync = {
            let call = validationCalls.withValue { value in
                value += 1
                return value
            }
            if call == 1 {
                return try await withCheckedThrowingContinuation { continuation in
                    firstValidation.withValue { $0 = continuation }
                    firstValidationStarted.fulfill()
                }
            }
            throw NetworkError.non200StatusCode(statusCode: 401, data: nil)
        }
        Current.keychain.getString = { _ in
            keychainReads.withValue { $0 += 1 }
            return "saved-password"
        }
        Current.network.authenticationStateAsync = { _, _ in
            authenticationCalls.withValue { $0 += 1 }
            return .authenticated(session)
        }

        let first = Task { @MainActor in
            try await subject.signInIfNeededAsync()
        }
        await fulfillment(of: [firstValidationStarted])
        let second = Task { @MainActor in
            try await subject.signInIfNeededAsync()
        }
        for _ in 0..<20 {
            await Task.yield()
        }
        firstValidation.withValue { continuation in
            continuation?.resume(
                throwing: NetworkError.non200StatusCode(statusCode: 401, data: nil)
            )
            continuation = nil
        }

        _ = try await first.value
        _ = try await second.value

        XCTAssertEqual(validationCalls.read { $0 }, 1)
        XCTAssertEqual(keychainReads.read { $0 }, 1)
        XCTAssertEqual(authenticationCalls.read { $0 }, 1)
    }

    func test_WaitForAuthenticationTerminalState_WaitsForFederatedAuthentication() async throws {
        let session = try makeAppleSession()
        subject.authenticationState = .waitingForFederatedAuthentication(
            FederationResponse(federated: true)
        )
        let completed = TestLockedBox(false)
        let task = Task { @MainActor in
            try await subject.waitForAuthenticationTerminalState()
            completed.withValue { $0 = true }
        }

        for _ in 0..<20 {
            await Task.yield()
        }
        XCTAssertFalse(completed.read { $0 })

        subject.authenticationState = .authenticated(session)
        try await task.value

        XCTAssertTrue(completed.read { $0 })
    }

    func test_WaitForAuthenticationTerminalState_ThrowsWhenCancelled() async {
        subject.authenticationState = .waitingForFederatedAuthentication(
            FederationResponse(federated: true)
        )
        let started = expectation(description: "waiter started")
        let task = Task { @MainActor in
            started.fulfill()
            try await subject.waitForAuthenticationTerminalState()
        }
        await fulfillment(of: [started])
        await Task.yield()

        task.cancel()

        do {
            try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }

    func test_SignInIfNeeded_PreservesPendingAuthenticationWithoutRestarting() async throws {
        let pending = AuthenticationState.waitingForFederatedAuthentication(
            FederationResponse(federated: true)
        )
        let validationCalls = TestLockedBox(0)
        let keychainReads = TestLockedBox(0)
        let authenticationCalls = TestLockedBox(0)
        subject.authenticationState = pending
        Current.defaults.string = { key in
            key == "username" ? "saved@example.com" : nil
        }
        Current.network.validateSessionAsync = {
            validationCalls.withValue { $0 += 1 }
            throw NetworkError.non200StatusCode(statusCode: 401, data: nil)
        }
        Current.keychain.getString = { _ in
            keychainReads.withValue { $0 += 1 }
            return "saved-password"
        }
        Current.network.authenticationStateAsync = { _, _ in
            authenticationCalls.withValue { $0 += 1 }
            return .unauthenticated
        }

        let result = try await subject.signInIfNeededAsync()

        XCTAssertEqual(result, pending)
        XCTAssertEqual(validationCalls.read { $0 }, 0)
        XCTAssertEqual(keychainReads.read { $0 }, 0)
        XCTAssertEqual(authenticationCalls.read { $0 }, 0)
    }

    func test_CancelAuthentication_PreventsLateCredentialFallback() async throws {
        let validationStarted = expectation(description: "validation started")
        let continuation = TestLockedBox<CheckedContinuation<AuthenticationState, Error>?>(nil)
        let keychainReads = TestLockedBox(0)
        let authenticationCalls = TestLockedBox(0)
        Current.defaults.string = { key in
            key == "username" ? "saved@example.com" : nil
        }
        Current.network.validateSessionAsync = {
            try await withCheckedThrowingContinuation { pending in
                continuation.withValue { $0 = pending }
                validationStarted.fulfill()
            }
        }
        Current.keychain.getString = { _ in
            keychainReads.withValue { $0 += 1 }
            return "saved-password"
        }
        Current.network.authenticationStateAsync = { _, _ in
            authenticationCalls.withValue { $0 += 1 }
            return .unauthenticated
        }

        let task = Task { @MainActor in
            try await subject.signInIfNeededAsync()
        }
        await fulfillment(of: [validationStarted])
        subject.cancelAuthentication()
        continuation.withValue { pending in
            pending?.resume(
                throwing: NetworkError.non200StatusCode(statusCode: 401, data: nil)
            )
            pending = nil
        }

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
        XCTAssertEqual(keychainReads.read { $0 }, 0)
        XCTAssertEqual(authenticationCalls.read { $0 }, 0)
        XCTAssertEqual(subject.authenticationState, .unauthenticated)
    }

    func test_CancelAuthentication_ReleasesTerminalStateWaiter() async throws {
        subject.authenticationState = .waitingForFederatedAuthentication(
            FederationResponse(federated: true)
        )
        subject.presentedSheet = .signIn
        let task = Task { @MainActor in
            try await subject.waitForAuthenticationTerminalState()
        }
        for _ in 0..<20 {
            await Task.yield()
        }

        subject.cancelAuthentication()

        do {
            try await task.value
            XCTFail("Expected invalid session")
        } catch {
            XCTAssertEqual(error as? AuthenticationError, .invalidSession)
        }
        XCTAssertEqual(subject.authenticationState, .unauthenticated)
        XCTAssertNil(subject.presentedSheet)
        XCTAssertNil(subject.authError)
    }

    func test_RestoreAuthenticationState_PreservesStateDuringTemporaryFailure() async throws {
        let session = try makeAppleSession()
        let keychainReads = TestLockedBox(0)
        subject.authenticationState = .authenticated(session)
        Current.network.validateSessionAsync = {
            throw NetworkError.non200StatusCode(statusCode: 503, data: nil)
        }
        Current.keychain.getString = { _ in
            keychainReads.withValue { $0 += 1 }
            return "unused"
        }

        await subject.restoreAuthenticationStateAsync(
            authenticationRequestPolicy: AuthenticationRequestPolicy(
                maximumAttemptCount: 1,
                delayBeforeRetry: .zero
            )
        )

        XCTAssertEqual(subject.authenticationState, .authenticated(session))
        XCTAssertEqual(keychainReads.read { $0 }, 0)
        XCTAssertFalse(subject.isRestoringAuthenticationState)
    }

    func test_RestoreAuthenticationState_ShowsSignedOutAfterInvalidSessionWithoutCredential() async throws {
        let session = try makeAppleSession()
        subject.authenticationState = .authenticated(session)
        Current.network.validateSessionAsync = {
            throw NetworkError.non200StatusCode(statusCode: 401, data: nil)
        }

        await subject.restoreAuthenticationStateAsync(
            authenticationRequestPolicy: AuthenticationRequestPolicy(
                maximumAttemptCount: 1,
                delayBeforeRetry: .zero
            )
        )

        XCTAssertEqual(subject.authenticationState, .unauthenticated)
        XCTAssertNil(subject.authError)
        XCTAssertFalse(subject.isRestoringAuthenticationState)
    }

    func test_SignOutPreventsLateSessionRestore() async throws {
        let session = try makeAppleSession()
        let started = expectation(description: "session validation started")
        let continuation = TestLockedBox<CheckedContinuation<AuthenticationState, Never>?>(nil)
        Current.network.validateSessionAsync = {
            await withCheckedContinuation { pending in
                continuation.withValue { $0 = pending }
                started.fulfill()
            }
        }

        let restoreTask = Task { @MainActor in
            await subject.restoreAuthenticationStateAsync()
        }
        await fulfillment(of: [started])
        subject.signOut()
        continuation.withValue { pending in
            pending?.resume(returning: .authenticated(session))
            pending = nil
        }
        await restoreTask.value

        XCTAssertEqual(subject.authenticationState, .unauthenticated)
        XCTAssertFalse(subject.isRestoringAuthenticationState)
    }

    func test_NotificationPreferencePresentation_DistinguishesUnknownAndNotShown() {
        XCTAssertEqual(NotificationPreferencePresentation(.unknown), .checking)
        XCTAssertEqual(NotificationPreferencePresentation(.notShown), .canEnable)
        XCTAssertEqual(NotificationPreferencePresentation(.shownAndDenied), .disabled)
        XCTAssertEqual(NotificationPreferencePresentation(.shownAndAccepted), .enabled)
    }

    func test_NotificationManagerPublishesLoadedPermissionStatus() async {
        let manager = NotificationManager(
            notificationStatusLoader: { .shownAndAccepted }
        )
        let statusChanged = expectation(description: "notification status changed")
        var cancellable: AnyCancellable?
        cancellable = manager.$notificationStatus
            .dropFirst()
            .sink { status in
                if status == .shownAndAccepted {
                    statusChanged.fulfill()
                }
            }

        manager.loadNotificationStatus()
        await fulfillment(of: [statusChanged])

        XCTAssertEqual(manager.notificationStatus, .shownAndAccepted)
        withExtendedLifetime(cancellable) {}
    }

    func test_AppleAccountPreferencePresentation_DoesNotFlashSignInWhileChecking() {
        XCTAssertEqual(
            AppleAccountPreferencePresentation(
                isRestoring: true,
                authenticationState: .unauthenticated
            ),
            .checking
        )
        XCTAssertEqual(
            AppleAccountPreferencePresentation(
                isRestoring: false,
                authenticationState: .unauthenticated
            ),
            .signedOut
        )
        XCTAssertEqual(
            AppleAccountPreferencePresentation(
                isRestoring: false,
                authenticationState: .waitingForFederatedAuthentication(
                    FederationResponse(federated: true)
                )
            ),
            .checking
        )
    }

    func test_AppleAccountDisplayName_UsesAvailableAccountIdentity() throws {
        let session = try makeAppleSession(fullName: "Jacob Clayden")
        subject.authenticationState = .authenticated(session)
        Current.defaults.string = { key in
            key == "username" ? "jacob@example.com" : nil
        }
        XCTAssertEqual(subject.appleAccountDisplayName, "jacob@example.com")

        Current.defaults.string = { _ in nil }
        XCTAssertEqual(subject.appleAccountDisplayName, "Jacob Clayden")

        subject.authenticationState = .authenticated(try makeAppleSession())
        XCTAssertEqual(subject.appleAccountDisplayName, localizeString("SignedIn"))
    }

    func test_AppleAccountAuthenticationError_ReplacesLegacyTerminology() {
        XCTAssertEqual(
            AppleAccountAuthenticationError(AuthenticationError.notAuthorized),
            .notAuthorized
        )
        XCTAssertEqual(
            AppleAccountAuthenticationError(AuthenticationError.missingPasswordForNonFederatedAccount),
            .passwordRequired
        )
        XCTAssertFalse(
            AppleAccountAuthenticationError(AuthenticationError.notAuthorized)?.localizedDescription.contains("Apple ID") == true
        )
        XCTAssertFalse(
            AppleAccountAuthenticationError(AuthenticationError.missingPasswordForNonFederatedAccount)?.localizedDescription.contains("Apple ID") == true
        )
        XCTAssertFalse(
            AppState.userFacingAuthenticationError(AuthenticationError.notAuthorized)
                .localizedDescription
                .contains("Apple ID")
        )
    }

    func test_ValidateADCSession_UsesAppleAccountTerminology() async throws {
        Current.network.loadData = { request in
            (
                Data(),
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 401,
                    httpVersion: nil,
                    headerFields: nil
                )!
            )
        }

        do {
            try await subject.validateADCSession(path: "runtime-download")
            XCTFail("Expected authorization failure")
        } catch {
            XCTAssertEqual(error as? AppleAccountAuthenticationError, .notAuthorized)
            XCTAssertFalse(error.localizedDescription.contains("Apple ID"))
        }
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

    private func makeAppleSession(fullName: String? = nil) throws -> AppleSession {
        var user: [String: Any] = [:]
        if let fullName {
            user["fullName"] = fullName
        } else {
            user["fullName"] = NSNull()
        }
        let data = try JSONSerialization.data(
            withJSONObject: ["user": user]
        )
        return try JSONDecoder().decode(
            AppleSession.self,
            from: data
        )
    }

    func test_InstallError_Network401IsUnauthorized() {
        let error = NetworkError.non200StatusCode(statusCode: 401, data: Data())

        XCTAssertTrue(AppState.isUnauthorizedInstallError(error))
    }

    func test_InstallError_OtherNetworkStatusIsNotUnauthorized() {
        let error = NetworkError.non200StatusCode(statusCode: 500, data: Data())

        XCTAssertFalse(AppState.isUnauthorizedInstallError(error))
    }

    func test_ChoosePhoneNumberForSMS_WithOneTrustedPhoneNumberRequestsSMS() async throws {
        let trustedPhoneNumber = AuthOptionsResponse.TrustedPhoneNumber(id: 7, numberWithDialCode: "(•••) •••-••90")
        let authOptions = AuthOptionsResponse(
            trustedPhoneNumbers: [trustedPhoneNumber],
            trustedDevices: nil,
            securityCode: .init(length: 6)
        )
        let sessionData = AppleSessionData(serviceKey: "service-key", sessionID: "session-id", scnt: "scnt")
        Current.network = Network(session: MockURLProtocol.session { request in
            XCTAssertEqual(request.url?.absoluteString, "https://idmsa.apple.com/appleauth/auth/verify/phone")
            XCTAssertEqual(request.httpMethod, "PUT")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Apple-ID-Session-Id"), "session-id")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Apple-Widget-Key"), "service-key")
            XCTAssertEqual(request.value(forHTTPHeaderField: "scnt"), "scnt")
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!)
        })

        subject.choosePhoneNumberForSMS(authOptions: authOptions, sessionData: sessionData)
        for _ in 0..<100 where subject.presentedSheet == nil && subject.authError == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertNil(subject.authError)
        guard case let .twoFactor(secondFactorData) = subject.presentedSheet else {
            XCTFail("Expected the SMS code-entry sheet to be presented")
            return
        }
        XCTAssertEqual(secondFactorData.option, .smsSent(trustedPhoneNumber))
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

    func test_CreateSymbolicLink_UsesProvidedInstalledPath() async throws {
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

        await subject.createSymbolicLink(to: installedXcodePath)

        let destination = try FileManager.default.destinationOfSymbolicLink(atPath: symlinkPath.string)
        XCTAssertEqual(destination, installedXcodePath.string)
    }

    func test_CreateSymbolicLink_ReplacesBrokenStableLink() async throws {
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

        await subject.createSymbolicLink(to: installedXcodePath)

        let destination = try FileManager.default.destinationOfSymbolicLink(atPath: symlinkPath.string)
        XCTAssertEqual(destination, installedXcodePath.string)
    }

    func test_CreateSymbolicLink_ReplacesBrokenBetaLink() async throws {
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

        await subject.createSymbolicLink(to: installedXcodePath, isBeta: true)

        let destination = try FileManager.default.destinationOfSymbolicLink(atPath: symlinkPath.string)
        XCTAssertEqual(destination, installedXcodePath.string)
    }

    func test_CreateSymbolicLink_PrivilegedBetaLinkUsesHelper() async throws {
        let installDirectory = try XCTUnwrap(Path(NSTemporaryDirectory().appending(UUID().uuidString)))
        let installedXcodePath = installDirectory/"Xcode-27.0-Beta.5.app"
        let calls = TestLockedBox<[[String]]>([])
        Current.defaults.string = { key in key == "installPath" ? installDirectory.string : nil }
        Current.defaults.bool = { key in key == PreferenceKey.usePrivilegeHelperForFileOperations.rawValue }
        Current.helper.checkIfLatestHelperIsInstalledAsync = { true }
        Current.helper.createSymbolicLinkAsync = { source, destination in
            calls.withValue { $0.append([source, destination]) }
        }

        await subject.createSymbolicLink(to: installedXcodePath, isBeta: true)

        XCTAssertEqual(calls.read { $0 }, [[installedXcodePath.string, (installDirectory/"Xcode-Beta.app").string]])
        XCTAssertNil(subject.error)
    }

    func test_CreateSymbolicLink_PrivilegedLinkDoesNotReplaceRealApp() async throws {
        let installDirectory = try XCTUnwrap(Path(NSTemporaryDirectory().appending(UUID().uuidString)))
        let destination = installDirectory/"Xcode.app"
        try FileManager.default.createDirectory(at: destination.url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: installDirectory.url) }
        let calledHelper = TestLockedBox(false)
        Current.defaults.string = { key in key == "installPath" ? installDirectory.string : nil }
        Current.defaults.bool = { key in key == PreferenceKey.usePrivilegeHelperForFileOperations.rawValue }
        Current.helper.createSymbolicLinkAsync = { _, _ in calledHelper.withValue { $0 = true } }

        await subject.createSymbolicLink(to: installDirectory/"Xcode-27.0.app")

        XCTAssertFalse(calledHelper.read { $0 })
        XCTAssertEqual(subject.error as? XcodeSelectionFilesystemError, .destinationExistsAndIsNotSymlink(destination))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.string))
    }

    func test_CreateSymbolicLink_HelperCancellationDoesNotPresentError() async throws {
        let directory = try XCTUnwrap(Path(NSTemporaryDirectory().appending(UUID().uuidString)))
        Current.defaults.string = { key in key == "installPath" ? directory.string : nil }
        Current.defaults.bool = { key in key == PreferenceKey.usePrivilegeHelperForFileOperations.rawValue }
        Current.helper.checkIfLatestHelperIsInstalledAsync = { true }
        Current.helper.createSymbolicLinkAsync = { _, _ in throw CancellationError() }

        await subject.createSymbolicLink(to: directory/"Xcode-27.0.app")

        XCTAssertNil(subject.error)
        XCTAssertNil(subject.presentedAlert)
    }

    func test_RenameToXcode_HelperCancellationDoesNotPresentError() async throws {
        let directory = try XCTUnwrap(Path(NSTemporaryDirectory().appending(UUID().uuidString)))
        let xcode = Xcode(version: Version("27.0.0")!, installState: .installed(directory/"Xcode-27.0.app"), selected: false, icon: nil)
        Current.defaults.string = { key in key == "installPath" ? directory.string : nil }
        Current.defaults.bool = { key in key == PreferenceKey.usePrivilegeHelperForFileOperations.rawValue }
        Current.files.fileExistsAtPath = { _ in false }
        Current.helper.checkIfLatestHelperIsInstalledAsync = { true }
        Current.helper.renameAsync = { _, _ in throw CancellationError() }

        let destination = await subject.renameToXcode(xcode: xcode)

        XCTAssertNil(destination)
        XCTAssertNil(subject.error)
        XCTAssertNil(subject.presentedAlert)
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

    func test_Uninstall_CancelledPreviousItemClearsSpinner() async throws {
        try await verifyCancelledUninstallState(repeatsSameItem: false)
    }

    func test_Uninstall_CancelledSameItemPreservesReplacementSpinner() async throws {
        try await verifyCancelledUninstallState(repeatsSameItem: true)
    }

    private func verifyCancelledUninstallState(repeatsSameItem: Bool) async throws {
        let path = try XCTUnwrap(Path("/Applications/Xcode-0.0.0.app"))
        let first = Xcode(version: Version("0.0.0")!, installState: .installed(path), selected: false, icon: nil)
        let second = repeatsSameItem ? first : Xcode(
            version: Version("0.0.1")!,
            installState: .installed(try XCTUnwrap(Path("/Applications/Xcode-0.0.1.app"))),
            selected: false,
            icon: nil
        )
        subject.allXcodes = repeatsSameItem ? [first] : [first, second]
        Current.defaults.bool = { key in key == PreferenceKey.usePrivilegeHelperForFileOperations.rawValue }
        Current.helper.checkIfLatestHelperIsInstalledAsync = { true }
        let continuations = TestLockedBox<[CheckedContinuation<Void, Error>]>([])
        Current.helper.removeAsync = { _ in
            try await withCheckedThrowingContinuation { continuation in
                continuations.withValue { $0.append(continuation) }
            }
        }

        subject.uninstall(xcode: first)
        let firstTask = try XCTUnwrap(subject.uninstallTask)
        for _ in 0..<100 where continuations.read({ $0.count }) < 1 { await Task.yield() }
        XCTAssertEqual(continuations.read { $0.count }, 1)
        subject.uninstall(xcode: second)
        let secondTask = try XCTUnwrap(subject.uninstallTask)
        for _ in 0..<100 where continuations.read({ $0.count }) < 2 { await Task.yield() }
        let pending = continuations.read { $0 }
        guard pending.count == 2 else {
            pending.forEach { $0.resume(throwing: CancellationError()) }
            return XCTFail("Expected both uninstall operations to reach helper")
        }
        pending[0].resume(throwing: CancellationError())
        await firstTask.value

        XCTAssertEqual(subject.allXcodes.first { $0.id == first.id }?.installState,
                       repeatsSameItem ? .uninstalling(path) : .installed(path))
        XCTAssertEqual(subject.allXcodes.first { $0.id == second.id }?.installState, .uninstalling(second.installedPath!))

        pending[1].resume(throwing: CancellationError())
        await secondTask.value
        XCTAssertNil(subject.uninstallTask)
        XCTAssertNil(subject.uninstallXcodeID)
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
        XCTAssertEqual(runtimes.first?.runtime.architectures, [.arm64])
    }

    func test_InstalledPlatformRuntimes_CollapsesDownloadVariantsForInstalledImage() async throws {
        let universalRuntime = try Self.downloadableRuntime(
            identifier: "com.apple.dmg.iPhoneSimulatorSDK26_5",
            build: "23F72",
            version: "26.5",
            fileSize: 10_600_000_000,
            architectures: [.arm64, .x86_64]
        )
        let armRuntime = try Self.downloadableRuntime(
            identifier: "com.apple.dmg.iPhoneSimulatorSDK26_5_arm64",
            build: "23F72",
            version: "26.5",
            fileSize: 8_520_000_000,
            architectures: [.arm64]
        )
        let installedRuntime = CoreSimulatorImage(
            uuid: "97772E90-7BD1-4882-9C51-782E62E0AF4F",
            path: ["relative": "/Library/Developer/CoreSimulator/Images/iOS_26_5.dmg"],
            runtimeInfo: CoreSimulatorRuntimeInfo(
                build: "23F72",
                supportedArchitectures: [.arm64]
            )
        )
        subject.downloadableRuntimes = [universalRuntime, armRuntime]
        subject.installedRuntimes = [installedRuntime]

        let runtimes = subject.installedPlatformRuntimes()

        XCTAssertEqual(runtimes.count, 1)
        XCTAssertEqual(runtimes.first?.runtime.identifier, armRuntime.identifier)
        let deletedIdentifiers = TestLockedBox<[String]>([])
        subject.runtimeService = Self.runtimeService(deleteRuntimeOutput: { identifier in
            deletedIdentifiers.withValue { $0.append(identifier) }
            return ProcessOutput(status: 0, out: "", err: "")
        })
        try await subject.deleteRuntime(runtime: try XCTUnwrap(runtimes.first))
        XCTAssertEqual(deletedIdentifiers.read { $0 }, [installedRuntime.uuid])
    }

    func test_DeleteRuntime_MatchesArchitecturesRegardlessOfOrder() async throws {
        let runtime = try Self.downloadableRuntime(
            identifier: "com.apple.dmg.iPhoneSimulatorSDK26_5",
            build: "23F72",
            version: "26.5",
            architectures: [.arm64, .x86_64]
        )
        let installedRuntime = CoreSimulatorImage(
            uuid: "97772E90-7BD1-4882-9C51-782E62E0AF4F",
            path: ["relative": "/Library/Developer/CoreSimulator/Images/iOS_26_5.dmg"],
            runtimeInfo: CoreSimulatorRuntimeInfo(
                build: "23F72",
                supportedArchitectures: [.x86_64, .arm64]
            )
        )
        let deletedIdentifiers = TestLockedBox<[String]>([])
        subject.downloadableRuntimes = [runtime]
        subject.installedRuntimes = [installedRuntime]
        subject.runtimeService = Self.runtimeService(deleteRuntimeOutput: { identifier in
            deletedIdentifiers.withValue { $0.append(identifier) }
            return ProcessOutput(status: 0, out: "", err: "")
        })

        let displayedRuntime = try XCTUnwrap(subject.installedPlatformRuntimes().first)
        try await subject.deleteRuntime(runtime: displayedRuntime)

        XCTAssertEqual(deletedIdentifiers.read { $0 }, [installedRuntime.uuid])
    }

    func test_InstalledPlatformRuntimes_CollapsesArchitecturelessBuildToExactUUID() async throws {
        let runtime = try Self.downloadableRuntime(
            identifier: "com.apple.dmg.iPhoneSimulatorSDK26_5",
            build: "23F72",
            version: "26.5",
            architectures: nil
        )
        let x86Runtime = CoreSimulatorImage(
            uuid: "97772E90-7BD1-4882-9C51-782E62E0AF4F",
            path: ["relative": "/Library/Developer/CoreSimulator/Images/iOS_26_5_x86_64.dmg"],
            runtimeInfo: CoreSimulatorRuntimeInfo(
                build: "23F72",
                supportedArchitectures: [.x86_64]
            )
        )
        let armRuntime = CoreSimulatorImage(
            uuid: "F42510E4-2C1B-411A-B7CE-E0CA68E5F1E5",
            path: ["relative": "/Library/Developer/CoreSimulator/Images/iOS_26_5_arm64.dmg"],
            runtimeInfo: CoreSimulatorRuntimeInfo(
                build: "23F72",
                supportedArchitectures: [.arm64]
            )
        )
        let deletedIdentifiers = TestLockedBox<[String]>([])
        subject.downloadableRuntimes = [runtime]
        subject.installedRuntimes = [x86Runtime, armRuntime]
        subject.runtimeService = Self.runtimeService(deleteRuntimeOutput: { identifier in
            deletedIdentifiers.withValue { $0.append(identifier) }
            return ProcessOutput(status: 0, out: "", err: "")
        })

        let rows = subject.installedPlatformRuntimes()

        XCTAssertEqual(rows.count, 1)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.id, x86Runtime.uuid)
        try await subject.deleteRuntime(runtime: row)
        XCTAssertEqual(deletedIdentifiers.read { $0 }, [x86Runtime.uuid])
    }

    func test_SetInstallationStep_UpdatesExactArchitectureVariant() {
        let version = Version("27.0.0")!
        let armXcode = Xcode(
            version: version,
            installState: .notInstalled,
            selected: false,
            icon: nil,
            architectures: [.arm64]
        )
        let universalXcode = Xcode(
            version: version,
            installState: .notInstalled,
            selected: false,
            icon: nil,
            architectures: [.arm64, .x86_64]
        )
        let universalDownload = AvailableXcode(
            version: version,
            url: URL(string: "https://example.com/Xcode-27-universal.xip")!,
            filename: "Xcode-27-universal.xip",
            releaseDate: nil,
            architectures: [.arm64, .x86_64]
        )
        subject.allXcodes = [armXcode, universalXcode]

        subject.setInstallationStep(of: universalDownload, to: .unarchiving, postNotification: false)

        XCTAssertEqual(subject.allXcodes[0].installState, .notInstalled)
        XCTAssertEqual(subject.allXcodes[1].installState, .installing(.unarchiving))
    }

    func test_ConcurrentXcodeExtractionWorkspacesAreUniqueAndOwned() async throws {
        let archive = URL(fileURLWithPath: "/tmp/xcodes/Xcode-27.xip")
        let createdDirectories = TestLockedBox<[URL]>([])
        let linkedItems = TestLockedBox<[(URL, URL)]>([])
        Current.files.createDirectory = { url, _, _ in
            createdDirectories.withValue { $0.append(url) }
        }
        Current.files.linkItem = { source, destination in
            linkedItems.withValue { $0.append((source, destination)) }
        }

        async let firstWorkspace = XcodeExtractionWorkspace.create(for: archive)
        async let secondWorkspace = XcodeExtractionWorkspace.create(for: archive)
        let (first, second) = try await (firstWorkspace, secondWorkspace)

        XCTAssertNotEqual(first.directoryURL, second.directoryURL)
        XCTAssertEqual(first.directoryURL.deletingLastPathComponent(), archive.deletingLastPathComponent())
        XCTAssertEqual(second.directoryURL.deletingLastPathComponent(), archive.deletingLastPathComponent())
        XCTAssertTrue(first.stagedArchiveURL.path.hasPrefix(first.directoryURL.path + "/"))
        XCTAssertTrue(second.stagedArchiveURL.path.hasPrefix(second.directoryURL.path + "/"))
        XCTAssertEqual(createdDirectories.read { $0.count }, 2)
        XCTAssertEqual(linkedItems.read { $0.map(\.0) }, [archive, archive])
    }

    func test_CancelledXcodeExtractionCleansOnlyOwnedWorkspace() async throws {
        let archive = URL(fileURLWithPath: "/tmp/xcodes/Xcode-27.xip")
        let workingDirectory = TestLockedBox<URL?>(nil)
        let continuation = TestLockedBox<CheckedContinuation<ProcessOutput, Error>?>(nil)
        let removedURLs = TestLockedBox<[URL]>([])
        Current.files.createDirectory = { _, _, _ in }
        Current.files.linkItem = { _, _ in }
        Current.files.fileExistsAtPath = { path in
            guard let directory = workingDirectory.read({ $0 }) else { return false }
            return path.hasPrefix(directory.path + "/")
        }
        Current.files.removeItem = { url in
            removedURLs.withValue { $0.append(url) }
        }
        Current.files.quarantineAndRemoveOwnedDirectory = { _, _, directory, _, beforeQuarantine in
            try beforeQuarantine()
            removedURLs.withValue { $0.append(directory) }
        }
        Current.shell.unxip = { _, directory in
            workingDirectory.withValue { $0 = directory }
            return try await withCheckedThrowingContinuation { pending in
                continuation.withValue { $0 = pending }
            }
        }

        let installation = Task { @MainActor in
            try await subject.installArchivedXcodeAsync(
                AvailableXcode(
                    version: Version("27.0.0")!,
                    url: URL(string: "https://example.com/Xcode-27.xip")!,
                    filename: "Xcode-27.xip",
                    releaseDate: nil
                ),
                at: archive
            )
        }
        for _ in 0..<100 where continuation.read({ $0 == nil }) {
            await Task.yield()
        }
        let extractionDirectory = try XCTUnwrap(workingDirectory.read { $0 })

        installation.cancel()
        continuation.read { $0 }?.resume(throwing: CancellationError())
        do {
            _ = try await installation.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        }

        XCTAssertFalse(removedURLs.read { $0 }.contains(archive))
        XCTAssertTrue(removedURLs.read { $0 }.allSatisfy {
            $0 == extractionDirectory || $0.path.hasPrefix(extractionDirectory.path + "/")
        })
        XCTAssertTrue(removedURLs.read { $0 }.contains(extractionDirectory))
    }

    func test_XcodeExtractionWorkspaceRefusesCleanupThroughReplacedParentSymlink() throws {
        let previousFiles = Current.files
        Current.files = Files()
        defer { Current.files = previousFiles }
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let parent = root.appendingPathComponent("parent", isDirectory: true)
        let movedParent = root.appendingPathComponent("moved-parent", isDirectory: true)
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let raceRan = TestLockedBox(false)
        let sentinelURL = TestLockedBox<URL?>(nil)
        Current.files.beforeOwnedDirectoryQuarantine = {
            let raceFileManager = FileManager.default
            let workspaceURL = try XCTUnwrap(
                raceFileManager.contentsOfDirectory(
                    at: parent,
                    includingPropertiesForKeys: nil
                ).first { $0.lastPathComponent.hasPrefix(".xcodes-extract-") }
            )
            let outsideWorkspace = outside.appendingPathComponent(
                workspaceURL.lastPathComponent,
                isDirectory: true
            )
            try raceFileManager.createDirectory(at: outsideWorkspace, withIntermediateDirectories: false)
            let sentinel = outsideWorkspace.appendingPathComponent("sentinel")
            try Data("preserve".utf8).write(to: sentinel)
            sentinelURL.withValue { $0 = sentinel }

            try raceFileManager.moveItem(at: parent, to: movedParent)
            try raceFileManager.createSymbolicLink(at: parent, withDestinationURL: outside)
            raceRan.withValue { $0 = true }
        }

        let archive = parent.appendingPathComponent("Xcode-27.xip")
        try Data("archive".utf8).write(to: archive)
        let workspace = try XcodeExtractionWorkspace.create(for: archive)

        try workspace.remove()

        XCTAssertTrue(raceRan.read { $0 })
        XCTAssertTrue(fileManager.fileExists(atPath: try XCTUnwrap(sentinelURL.read { $0 }).path))
        XCTAssertFalse(
            fileManager.fileExists(
                atPath: movedParent.appendingPathComponent(workspace.directoryURL.lastPathComponent).path
            )
        )
    }

    func test_XcodeExtractionWorkspaceRefusesCleanupAfterDirectoryReplacement() throws {
        let previousFiles = Current.files
        Current.files = Files()
        defer { Current.files = previousFiles }
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: outside, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: root) }

        let archive = root.appendingPathComponent("Xcode-27.xip")
        try Data("archive".utf8).write(to: archive)
        let displacedWorkspace = root.appendingPathComponent("displaced-workspace", isDirectory: true)
        let sentinel = outside.appendingPathComponent("sentinel")
        try Data("preserve".utf8).write(to: sentinel)
        let raceRan = TestLockedBox(false)
        Current.files.beforeOwnedDirectoryQuarantine = {
            let raceFileManager = FileManager.default
            let workspaceURL = try XCTUnwrap(
                raceFileManager.contentsOfDirectory(
                    at: root,
                    includingPropertiesForKeys: nil
                ).first { $0.lastPathComponent.hasPrefix(".xcodes-extract-") }
            )
            try raceFileManager.moveItem(at: workspaceURL, to: displacedWorkspace)
            try raceFileManager.createSymbolicLink(at: workspaceURL, withDestinationURL: outside)
            raceRan.withValue { $0 = true }
        }
        let workspace = try XcodeExtractionWorkspace.create(for: archive)

        XCTAssertThrowsError(try workspace.remove())
        XCTAssertTrue(raceRan.read { $0 })
        XCTAssertTrue(fileManager.fileExists(atPath: sentinel.path))
        XCTAssertTrue(fileManager.fileExists(atPath: displacedWorkspace.path))
    }

    func test_XcodeExtractionWorkspaceRemovesUnchangedOwnedDirectory() throws {
        let previousFiles = Current.files
        Current.files = Files()
        defer { Current.files = previousFiles }
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let archive = root.appendingPathComponent("Xcode-27.xip")
        try Data("archive".utf8).write(to: archive)
        let workspace = try XcodeExtractionWorkspace.create(for: archive)
        let nestedDirectory = workspace.directoryURL
            .appendingPathComponent("nested", isDirectory: true)
            .appendingPathComponent("directory", isDirectory: true)
        try fileManager.createDirectory(at: nestedDirectory, withIntermediateDirectories: true)
        try Data("temporary".utf8).write(
            to: nestedDirectory.appendingPathComponent("contents")
        )

        try workspace.remove()

        XCTAssertFalse(fileManager.fileExists(atPath: workspace.directoryURL.path))
        XCTAssertTrue(fileManager.fileExists(atPath: archive.path))
    }

    func test_RestoreAuthenticationState_UsesPersistedSession() async throws {
        let appleSession = try JSONDecoder().decode(
            AppleSession.self,
            from: Data(#"{"user":{"fullName":"Jane Developer"}}"#.utf8)
        )
        let expectedState = AuthenticationState.authenticated(appleSession)
        Current.defaults.string = { key in
            key == "username" ? "jane@example.com" : nil
        }
        Current.network.validateSessionAsync = { expectedState }

        await subject.restoreAuthenticationStateAsync()

        XCTAssertEqual(subject.authenticationState, expectedState)
    }

    func test_RestoreAuthenticationState_ValidatesSessionWithoutSavedUsername() async throws {
        let didValidate = TestLockedBox(false)
        Current.network.validateSessionAsync = {
            didValidate.withValue { $0 = true }
            return .unauthenticated
        }

        await subject.restoreAuthenticationStateAsync()

        XCTAssertTrue(didValidate.read { $0 })
        XCTAssertEqual(subject.authenticationState, .unauthenticated)
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
        let installedPlatformRuntime = InstalledPlatformRuntime(
            runtime: runtime,
            installedRuntimeUUID: installedRuntime.uuid
        )

        subject.confirmDeleteRuntime(runtime: installedPlatformRuntime)
        for _ in 0..<100 where continuations.read({ $0.count }) < 1 {
            await Task.yield()
        }
        let firstTask = try XCTUnwrap(subject.deleteRuntimeTask)
        XCTAssertEqual(deletedIdentifiers.read { $0 }, [installedRuntime.uuid])

        subject.confirmDeleteRuntime(runtime: installedPlatformRuntime)
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
        let installedPlatformRuntime = InstalledPlatformRuntime(
            runtime: runtime,
            installedRuntimeUUID: "missing-runtime-uuid"
        )
        subject.runtimeService = Self.runtimeService(deleteRuntimeOutput: { _ in
            throw XcodesKitError("No simulator found with \(runtime.identifier)")
        })

        subject.confirmDeleteRuntime(runtime: installedPlatformRuntime)
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
        let installedPlatformRuntime = InstalledPlatformRuntime(
            runtime: runtime,
            installedRuntimeUUID: installedRuntime.uuid
        )

        try await subject.deleteRuntime(runtime: installedPlatformRuntime)

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
        let installedPlatformRuntime = InstalledPlatformRuntime(
            runtime: runtime,
            installedRuntimeUUID: installedRuntime.uuid
        )

        subject.confirmDeleteRuntime(runtime: installedPlatformRuntime)
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
        Xcodes.Current.network.validateSessionAsync = { .unauthenticated }
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
        identifier: String = "com.apple.CoreSimulator.SimRuntime.iOS-16-0",
        build: String = "20A360",
        version: String = "16.0",
        fileSize: Int64 = 42,
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
            "buildUpdate": "\(build)",
            "version": "\(version)"
          },
          "source": "https://example.com/iOS_16_Runtime.dmg",
          "architectures": \(encodedArchitectures),
          "dictionaryVersion": 1,
          "contentType": "diskImage",
          "platform": "com.apple.platform.iphoneos",
          "identifier": "\(identifier)",
          "version": "\(version)",
          "fileSize": \(fileSize),
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
        Current.shell.unxip = { _, _ in
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

    func test_InstallNotificationTitle_DoesNotDuplicateMajorVersion() {
        XCTAssertEqual(
            AppState.installNotificationTitle(for: Version(major: 27, minor: 0, patch: 0, prereleaseIdentifiers: ["beta", "4"])),
            "27.0 Beta 4"
        )
        XCTAssertEqual(
            AppState.installNotificationTitle(for: Version(major: 26, minor: 5, patch: 0)),
            "26.5"
        )
        // Stable release with patch
        XCTAssertEqual(
            AppState.installNotificationTitle(for: Version(major: 10, minor: 2, patch: 1)),
            "10.2.1"
        )
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
