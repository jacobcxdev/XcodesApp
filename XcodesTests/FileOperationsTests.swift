import Foundation
import XCTest
@testable import Xcodes

final class FileOperationsTests: XCTestCase {
    func testRejectsRelativePathsBeforeFileOperations() throws {
        try withTemporaryDirectory { directory in
            let absolute = directory.appendingPathComponent("Xcode.app").path
            let relative = "xcodes-test-\(UUID().uuidString)"
            for operation in [FileOperations.moveApp, FileOperations.createSymbolicLink, FileOperations.rename] {
                var error: Error?
                operation(relative, absolute) { error = $0 }
                XCTAssertEqual((error as? XPCDelegateError)?.code, .invalidSourcePath)

                operation(directory.path, relative) { error = $0 }
                XCTAssertEqual((error as? XPCDelegateError)?.code, .invalidDestinationPath)
            }

            var error: Error?
            FileOperations.remove(path: relative) { error = $0 }
            XCTAssertEqual((error as? XPCDelegateError)?.code, .invalidSourcePath)
            XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
        }
    }

    func testCreatesNewSymbolicLink() throws {
        try withTemporaryDirectory { directory in
            let destination = directory.appendingPathComponent("Xcode.app")
            var error: Error?
            FileOperations.createSymbolicLink(source: "/new-xcode", destination: destination.path) { error = $0 }
            XCTAssertNil(error)
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: destination.path), "/new-xcode")
        }
    }

    func testReplacesDanglingSymbolicLink() throws {
        try withTemporaryDirectory { directory in
            let destination = directory.appendingPathComponent("Xcode.app")
            try FileManager.default.createSymbolicLink(atPath: destination.path, withDestinationPath: "/missing-old-xcode")

            var error: Error?
            FileOperations.createSymbolicLink(source: "/new-xcode", destination: destination.path) { error = $0 }

            XCTAssertNil(error)
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: destination.path), "/new-xcode")
        }
    }

    func testReplacesExistingSymbolicLinkWithoutRemovingTarget() throws {
        try withTemporaryDirectory { directory in
            let target = directory.appendingPathComponent("OldXcode.app")
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
            let destination = directory.appendingPathComponent("Xcode.app")
            try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: target)

            var error: Error?
            FileOperations.createSymbolicLink(source: "/new-xcode", destination: destination.path) { error = $0 }

            XCTAssertNil(error)
            XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: destination.path), "/new-xcode")
        }
    }

    func testDoesNotReplaceRealDirectoryOrFile() throws {
        try withTemporaryDirectory { directory in
            let app = directory.appendingPathComponent("Xcode.app")
            try FileManager.default.createDirectory(at: app, withIntermediateDirectories: false)
            let file = directory.appendingPathComponent("file")
            let contents = Data("keep me".utf8)
            try contents.write(to: file)

            for destination in [app, file] {
                var error: Error?
                FileOperations.createSymbolicLink(source: "/new-xcode", destination: destination.path) { error = $0 }
                XCTAssertEqual((error as? XPCDelegateError)?.code, .destinationIsNotASymbolicLink)
            }

            XCTAssertTrue(FileManager.default.fileExists(atPath: app.path))
            XCTAssertEqual(try Data(contentsOf: file), contents)
        }
    }

    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }
}
