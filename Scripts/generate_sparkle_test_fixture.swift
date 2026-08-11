import CryptoKit
import Foundation

func writePlist(_ value: [String: String], to path: String) throws {
    let plist = try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
    try plist.write(to: URL(fileURLWithPath: path))
}

switch CommandLine.arguments.dropFirst().first {
case "prepare":
    guard CommandLine.arguments.count == 7 else {
        fatalError("usage: generate_sparkle_test_fixture prepare <private-key> <trusted-plist> <app-plist> <version> <build>")
    }
    let privateKey = Curve25519.Signing.PrivateKey()
    let publicKey = privateKey.publicKey.rawRepresentation.base64EncodedString()
    try privateKey.rawRepresentation.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
    try writePlist(["SUPublicEDKey": publicKey], to: CommandLine.arguments[3])
    try writePlist(
        [
            "CFBundleIdentifier": "dev.jacobcx.Xcodes",
            "CFBundleShortVersionString": CommandLine.arguments[5],
            "CFBundleVersion": CommandLine.arguments[6],
            "SUPublicEDKey": publicKey,
        ],
        to: CommandLine.arguments[4]
    )
case "sign":
    guard CommandLine.arguments.count == 6 else {
        fatalError("usage: generate_sparkle_test_fixture sign <private-key> <archive> <signature> <body>")
    }
    let privateKey = try Curve25519.Signing.PrivateKey(
        rawRepresentation: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
    )
    let archive = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3]))
    let signature = try privateKey.signature(for: archive).base64EncodedString()
    try Data("\(signature)\n".utf8).write(to: URL(fileURLWithPath: CommandLine.arguments[4]))
    try Data("Signed release.\n\n<!-- sparkle:edSignature=\(signature) -->\n".utf8)
        .write(to: URL(fileURLWithPath: CommandLine.arguments[5]))
default:
    fatalError("usage: generate_sparkle_test_fixture <prepare|sign> ...")
}
