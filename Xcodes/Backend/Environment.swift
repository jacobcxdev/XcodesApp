import Darwin
import Foundation
import Path
import KeychainAccess
import XcodesKit
import XcodesLoginKit
import os
/**
 Lightweight dependency injection using global mutable state :P

 - SeeAlso: https://www.pointfree.co/episodes/ep16-dependency-injection-made-easy
 - SeeAlso: https://www.pointfree.co/episodes/ep18-dependency-injection-made-comfortable
 - SeeAlso: https://vimeo.com/291588126
 */
public struct Environment: Sendable {
    public var shell = Shell()
    public var files = Files()
    public var network = Network()
    public var keychain = Keychain()
    public var defaults = Defaults()
    public var date: @Sendable () -> Date = { Date() }
    public var helper = Helper()
    public var notificationManager = NotificationManager()
}

private let currentEnvironment = CurrentEnvironmentStorage(Environment())

public var Current: Environment {
    get { currentEnvironment.value }
    set { currentEnvironment.value = newValue }
}

private final class CurrentEnvironmentStorage: Sendable {
    private let environment: OSAllocatedUnfairLock<Environment>

    var value: Environment {
        get { environment.withLock { $0 } }
        set { environment.withLock { $0 = newValue } }
    }

    init(_ environment: Environment) {
        self.environment = OSAllocatedUnfairLock(initialState: environment)
    }
}

public struct Shell: Sendable {
    private static let shared = XcodesShell()

    public var unxip: @Sendable (URL, URL) async throws -> ProcessOutput = { source, workingDirectory in
        try await Process.runAsync(
            URL(fileURLWithPath: "/usr/bin/xip"),
            workingDirectory: workingDirectory,
            ["--expand", source.path]
        )
    }
    public var spctlAssess = Shell.shared.spctlAssess
    public var codesignVerify = Shell.shared.codesignVerify
    public var buildVersion = Shell.shared.buildVersion
    public var xcodeBuildVersion = Shell.shared.xcodeBuildVersion
    public var archs = Shell.shared.archs
    public var getUserCacheDir = Shell.shared.getUserCacheDir
    public var touchInstallCheck = Shell.shared.touchInstallCheck

    public var xcodeSelectPrintPath = Shell.shared.xcodeSelectPrintPath
    
    public var downloadWithAria2Async: @Sendable (Path, URL, Path, [HTTPCookie]) -> AsyncThrowingStream<Progress, Error> = { aria2Path, url, destination, cookies in
        Aria2DownloadService().download(aria2Path: aria2Path, url: url, destination: destination, cookies: cookies)
    }
    
    
    public var unxipExperiment: @Sendable (URL, URL) async throws -> ProcessOutput = { url, workingDirectory in
        let unxipPath = Path(url: Bundle.main.url(forAuxiliaryExecutable: "unxip")!)!
        return try await Process.runAsync(unxipPath.url, workingDirectory: workingDirectory, ["\(url.path)"])
    }
    
    public var downloadRuntime: @Sendable (String, String, String?) -> AsyncThrowingStream<Progress, Error> = { platform, version, architecture in
        XcodebuildRuntimeDownloadService().download(platform: platform, buildVersion: version, architecture: architecture)
    }
}

public struct Files: Sendable {
    public var fileExistsAtPath: @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }

    public func fileExists(atPath path: String) -> Bool {
        return fileExistsAtPath(path)
    }

    public var moveItem: @Sendable (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) }

    public func moveItem(at srcURL: URL, to dstURL: URL) throws {
        try moveItem(srcURL, dstURL)
    }

    public var linkItem: @Sendable (URL, URL) throws -> Void = { try FileManager.default.linkItem(at: $0, to: $1) }

    public func linkItem(at srcURL: URL, to dstURL: URL) throws {
        try linkItem(srcURL, dstURL)
    }

    var canonicalURL: @Sendable (URL) -> URL = {
        $0.resolvingSymlinksInPath().standardizedFileURL
    }

    var fileSystemIdentity: @Sendable (URL) throws -> FileSystemIdentity = { url in
        var fileStatus = stat()
        guard lstat(url.path, &fileStatus) == 0 else {
            throw currentPOSIXError()
        }

        return FileSystemIdentity(fileStatus)
    }

    var beforeOwnedDirectoryQuarantine: @Sendable () throws -> Void = {}

    var quarantineAndRemoveOwnedDirectory: @Sendable (
        URL,
        FileSystemIdentity,
        URL,
        FileSystemIdentity,
        @Sendable () throws -> Void
    ) throws -> Void = { parentURL, parentIdentity, directoryURL, directoryIdentity, beforeQuarantine in
        try securelyRemoveOwnedDirectory(
            parentURL: parentURL,
            parentIdentity: parentIdentity,
            directoryURL: directoryURL,
            directoryIdentity: directoryIdentity,
            beforeQuarantine: beforeQuarantine
        )
    }

    public var contentsAtPath: @Sendable (String) -> Data? = { FileManager.default.contents(atPath: $0) }

    public func contents(atPath path: String) -> Data? {
        return contentsAtPath(path)
    }

    public var removeItem: @Sendable (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }

    public func removeItem(at URL: URL) throws {
        try removeItem(URL)
    }

    public var trashItem: @Sendable (URL) throws -> URL = { try FileManager.default.trashItem(at: $0) }

    @discardableResult
    public func trashItem(at URL: URL) throws -> URL {
        return try trashItem(URL)
    }
    
    public var createFile: @Sendable (String, Data?, [FileAttributeKey: Any]?) -> Bool = { FileManager.default.createFile(atPath: $0, contents: $1, attributes: $2) }
    
    @discardableResult
    public func createFile(atPath path: String, contents data: Data?, attributes attr: [FileAttributeKey : Any]? = nil) -> Bool {
        return createFile(path, data, attr)
    }

    public var createDirectory: @Sendable (URL, Bool, [FileAttributeKey : Any]?) throws -> Void = { url, createIntermediates, attributes in
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: createIntermediates, attributes: attributes)
    }
    public func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool, attributes: [FileAttributeKey : Any]? = nil) throws {
        try createDirectory(url, createIntermediates, attributes)
    }

    public var installedXcodes: @Sendable (Path) -> [InstalledXcode] = { destination in
        _installedXcodes(destination: destination)
    }
    
    public func installedXcode(destination: Path) -> InstalledXcode? {
        InstalledXcodeDiscoveryService(
            listDirectory: { _ in [] },
            contentsAtPath: contentsAtPath,
            loadArchitectures: Current.shell.archs
        ).installedXcode(at: destination)
    }
    
    public var write: @Sendable (Data, URL) throws -> Void = { try $0.write(to: $1) }

    public func write(_ data: Data, to url: URL) throws {
        try write(data, url)
    }
}

struct FileSystemIdentity: Equatable, Sendable {
    let deviceID: UInt64
    let inode: UInt64
    let isDirectory: Bool
    let isSymbolicLink: Bool

    init(_ fileStatus: stat) {
        let fileType = fileStatus.st_mode & S_IFMT
        deviceID = UInt64(bitPattern: Int64(fileStatus.st_dev))
        inode = UInt64(fileStatus.st_ino)
        isDirectory = fileType == S_IFDIR
        isSymbolicLink = fileType == S_IFLNK
    }

    init(deviceID: UInt64, inode: UInt64, isDirectory: Bool, isSymbolicLink: Bool) {
        self.deviceID = deviceID
        self.inode = inode
        self.isDirectory = isDirectory
        self.isSymbolicLink = isSymbolicLink
    }
}

private func securelyRemoveOwnedDirectory(
    parentURL: URL,
    parentIdentity: FileSystemIdentity,
    directoryURL: URL,
    directoryIdentity: FileSystemIdentity,
    beforeQuarantine: @Sendable () throws -> Void
) throws {
    guard directoryURL.deletingLastPathComponent() == parentURL,
          directoryURL.lastPathComponent.contains("/") == false
    else {
        throw CocoaError(.fileWriteInvalidFileName)
    }

    let parentDescriptor = open(
        parentURL.path,
        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    )
    guard parentDescriptor >= 0 else { throw currentPOSIXError() }
    defer { close(parentDescriptor) }

    var currentParentStatus = stat()
    guard fstat(parentDescriptor, &currentParentStatus) == 0 else {
        throw currentPOSIXError()
    }
    guard FileSystemIdentity(currentParentStatus) == parentIdentity else {
        throw CocoaError(.fileWriteInvalidFileName)
    }

    let directoryName = directoryURL.lastPathComponent
    var currentDirectoryStatus = stat()
    guard fstatat(
        parentDescriptor,
        directoryName,
        &currentDirectoryStatus,
        AT_SYMLINK_NOFOLLOW
    ) == 0 else {
        throw currentPOSIXError()
    }
    guard FileSystemIdentity(currentDirectoryStatus) == directoryIdentity else {
        throw CocoaError(.fileWriteInvalidFileName)
    }

    let quarantineName = ".xcodes-cleanup-" + UUID().uuidString
    guard mkdirat(parentDescriptor, quarantineName, 0o700) == 0 else {
        throw currentPOSIXError()
    }

    let quarantineDescriptor = openat(
        parentDescriptor,
        quarantineName,
        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    )
    guard quarantineDescriptor >= 0 else {
        let error = currentPOSIXError()
        unlinkat(parentDescriptor, quarantineName, AT_REMOVEDIR)
        throw error
    }
    defer {
        close(quarantineDescriptor)
        unlinkat(parentDescriptor, quarantineName, AT_REMOVEDIR)
    }

    try beforeQuarantine()

    let quarantinedDirectoryName = "workspace"
    guard renameat(
        parentDescriptor,
        directoryName,
        quarantineDescriptor,
        quarantinedDirectoryName
    ) == 0 else {
        throw currentPOSIXError()
    }

    var quarantinedDirectoryStatus = stat()
    guard fstatat(
        quarantineDescriptor,
        quarantinedDirectoryName,
        &quarantinedDirectoryStatus,
        AT_SYMLINK_NOFOLLOW
    ) == 0 else {
        throw currentPOSIXError()
    }
    guard FileSystemIdentity(quarantinedDirectoryStatus) == directoryIdentity else {
        throw CocoaError(.fileWriteInvalidFileName)
    }

    guard removefileat(
        quarantineDescriptor,
        quarantinedDirectoryName,
        nil,
        removefile_flags_t(REMOVEFILE_RECURSIVE)
    ) == 0 else {
        throw currentPOSIXError()
    }
}

private func currentPOSIXError() -> POSIXError {
    POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
}

private func _installedXcodes(destination: Path) -> [InstalledXcode] {
    InstalledXcodeDiscoveryService(
        listDirectory: { $0.ls() },
        contentsAtPath: { path in FileManager.default.contents(atPath: path) },
        loadArchitectures: Current.shell.archs
    ).installedXcodes(in: destination)
}

public struct Network: Sendable {
    public private(set) var loginClient: XcodesLoginKit.Client

    public var session: URLSession {
        get { loginClient.urlSession }
        set {
            let loginClient = XcodesLoginKit.Client(urlSession: newValue)
            self.loginClient = loginClient
            configureDefaultOperations(using: loginClient)
        }
    }

    public var loadData: @Sendable (URLRequest) async throws -> (Data, URLResponse)

    public func dataTaskAsync(with request: URLRequest) async throws -> (Data, URLResponse) {
        try await loadData(request)
    }
    
    public var downloadTaskAsync: @Sendable (URL, URL, Data?) -> (Progress, Task<(saveLocation: URL, response: URLResponse), Error>)

    public func downloadTaskAsync(with url: URL, to saveLocation: URL, resumingWith resumeData: Data?) -> (progress: Progress, task: Task<(saveLocation: URL, response: URLResponse), Error>) {
        downloadTaskAsync(url, saveLocation, resumeData)
    }
    
    public var validateSessionAsync: @Sendable () async throws -> Void

    public var signout: @Sendable () -> Void

    public init(
        session: URLSession? = nil,
        loadData: (@Sendable (URLRequest) async throws -> (Data, URLResponse))? = nil,
        downloadTaskAsync: (@Sendable (URL, URL, Data?) -> (Progress, Task<(saveLocation: URL, response: URLResponse), Error>))? = nil,
        validateSessionAsync: (@Sendable () async throws -> Void)? = nil,
        signout: (@Sendable () -> Void)? = nil
    ) {
        let loginClient: XcodesLoginKit.Client
        if let session {
            loginClient = XcodesLoginKit.Client(urlSession: session)
        } else {
            loginClient = XcodesLoginKit.Client()
        }
        self.loginClient = loginClient
        self.loadData = loadData ?? { request in
            try await loginClient.urlSession.data(for: request)
        }
        self.downloadTaskAsync = downloadTaskAsync ?? { url, saveLocation, resumeData in
            loginClient.urlSession.downloadTaskAsync(with: url, to: saveLocation, resumingWith: resumeData)
        }
        self.validateSessionAsync = validateSessionAsync ?? {
            _ = try await loginClient.validateSession()
        }
        self.signout = signout ?? {
            loginClient.signout()
        }
    }

    private mutating func configureDefaultOperations(using loginClient: XcodesLoginKit.Client) {
        self.loadData = { request in
            try await loginClient.urlSession.data(for: request)
        }
        self.downloadTaskAsync = { url, saveLocation, resumeData in
            loginClient.urlSession.downloadTaskAsync(with: url, to: saveLocation, resumingWith: resumeData)
        }
        self.validateSessionAsync = {
            _ = try await loginClient.validateSession()
        }
        self.signout = {
            loginClient.signout()
        }
    }
}

public struct Keychain: Sendable {
    static let service = "dev.jacobcx.Xcodes.apple-account"

    private static var keychain: KeychainAccess.Keychain {
        KeychainAccess.Keychain(service: service)
    }

    public var getString: @Sendable (String) throws -> String? = { try keychain.getString($0) }
    public func getString(_ key: String) throws -> String? {
        try getString(key)
    }

    public var set: @Sendable (String, String) throws -> Void = { try keychain.set($0, key: $1) }
    public func set(_ value: String, key: String) throws {
        try set(value, key)
    }

    public var remove: @Sendable (String) throws -> Void = { try keychain.remove($0) }
    public func remove(_ key: String) throws -> Void {
        try remove(key)
    }
}

public struct Defaults: Sendable {
    public var string: @Sendable (String) -> String? = { UserDefaults.standard.string(forKey: $0) }
    public func string(forKey key: String) -> String? {
        string(key)
    }
    
    public var date: @Sendable (String) -> Date? = { Date(timeIntervalSince1970: UserDefaults.standard.double(forKey: $0)) }
    public func date(forKey key: String) -> Date? {
        date(key)
    }
    
    public var setDate: @Sendable (Date?, String) -> Void = { UserDefaults.standard.set($0?.timeIntervalSince1970, forKey: $1) }
    public func setDate(_ value: Date?, forKey key: String) {
        setDate(value, key)
    }
    
    public var set: @Sendable (Any?, String) -> Void = { UserDefaults.standard.set($0, forKey: $1) }
    public func set(_ value: Any?, forKey key: String) {
        set(value, key)
    }
    
    public var removeObject: @Sendable (String) -> Void = { UserDefaults.standard.removeObject(forKey: $0) }
    public func removeObject(forKey key: String) {
        removeObject(key)
    }
    
    public var get: @Sendable (String) -> Any? = { UserDefaults.standard.value(forKey: $0) }
    public func get(forKey key: String) -> Any? {
        get(key)
    }
    
    public var bool: @Sendable (String) -> Bool? = { UserDefaults.standard.bool(forKey: $0) }
    public func bool(forKey key: String) -> Bool? {
        bool(key)
    }
}

@MainActor
private let helperClient = HelperClient()
public struct Helper: Sendable {
    var install: @Sendable () async throws -> Void = { try await helperClient.install() }
    var checkIfLatestHelperIsInstalledAsync: @Sendable () async throws -> Bool = { try await helperClient.checkIfLatestHelperIsInstalledAsync() }
    var getVersionAsync: @Sendable () async throws -> String = { try await helperClient.getVersionAsync() }
    var switchXcodePathAsync: @Sendable (_ absolutePath: String) async throws -> Void = { try await helperClient.switchXcodePathAsync($0) }
    var devToolsSecurityEnableAsync: @Sendable () async throws -> Void = { try await helperClient.devToolsSecurityEnableAsync() }
    var addStaffToDevelopersGroupAsync: @Sendable () async throws -> Void = { try await helperClient.addStaffToDevelopersGroupAsync() }
    var acceptXcodeLicenseAsync: @Sendable (_ absoluteXcodePath: String) async throws -> Void = { try await helperClient.acceptXcodeLicenseAsync(absoluteXcodePath: $0) }
    var runFirstLaunchAsync: @Sendable (_ absoluteXcodePath: String) async throws -> Void = { try await helperClient.runFirstLaunchAsync(absoluteXcodePath: $0) }
}
