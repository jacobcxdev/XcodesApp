import Foundation
import os.log

enum FileOperations {
    private static let subsystem = Bundle.main.bundleIdentifier!
    static let fileOperations = Logger(subsystem: subsystem, category: "fileOperations")

    static func moveApp(at source: String, to destination: String, completion: @escaping ((any Error)?) -> Void) {
        do {
            guard (source as NSString).isAbsolutePath,
                  URL(fileURLWithPath: source).hasDirectoryPath else { throw XPCDelegateError(.invalidSourcePath)}

            guard (destination as NSString).isAbsolutePath,
                  URL(fileURLWithPath: destination).deletingLastPathComponent().hasDirectoryPath else { throw
                XPCDelegateError(.invalidDestinationPath)}

            try FileManager.default.moveItem(at: URL(fileURLWithPath: source), to: URL(fileURLWithPath: destination))
            completion(nil)
        } catch {
            completion(error)
        }
    }

    // does an Xcode.app file exist?
    static func createSymbolicLink(source: String, destination: String, completion: @escaping ((any Error)?) -> Void) {
        do {
            guard (source as NSString).isAbsolutePath else { throw XPCDelegateError(.invalidSourcePath) }
            guard (destination as NSString).isAbsolutePath else { throw XPCDelegateError(.invalidDestinationPath) }

            let attributes: [FileAttributeKey: Any]?
            do {
                // Read the link itself, including links whose target no longer exists.
                attributes = try FileManager.default.attributesOfItem(atPath: destination)
            } catch CocoaError.fileReadNoSuchFile {
                attributes = nil
            }

            if let attributes {
                if attributes[.type] as? FileAttributeType == FileAttributeType.typeSymbolicLink {
                    try FileManager.default.removeItem(atPath: destination)
                    Self.fileOperations.info("Successfully deleted old symlink")
                } else {
                    throw XPCDelegateError(.destinationIsNotASymbolicLink)
                }
            }

            try FileManager.default.createSymbolicLink(atPath: destination, withDestinationPath: source)
            Self.fileOperations.info("Successfully created symbolic link with \(destination)")
            completion(nil)
        } catch {
            completion(error)
        }
    }

    static func rename(source: String, destination: String, completion: @escaping ((any Error)?) -> Void) {
        do {
            guard (source as NSString).isAbsolutePath else { throw XPCDelegateError(.invalidSourcePath) }
            guard (destination as NSString).isAbsolutePath else { throw XPCDelegateError(.invalidDestinationPath) }
            try FileManager.default.moveItem(at: URL(fileURLWithPath: source), to: URL(fileURLWithPath: destination))
            completion(nil)
        } catch {
            completion(error)
        }
    }

    static func remove(path: String, completion: @escaping ((any Error)?) -> Void) {
        do {
            guard (path as NSString).isAbsolutePath,
                  URL(fileURLWithPath: path).standardizedFileURL.path != "/" else { throw XPCDelegateError(.invalidSourcePath) }
            try FileManager.default.removeItem(atPath: path)
            completion(nil)
        } catch {
            completion(error)
        }
    }
}
