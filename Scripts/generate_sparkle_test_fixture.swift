import CryptoKit
import Foundation

guard CommandLine.arguments.count == 5 else {
    fatalError("usage: generate_sparkle_test_fixture <archive> <signature> <plist> <body>")
}

let archive = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
let privateKey = Curve25519.Signing.PrivateKey()
let signature = try privateKey.signature(for: archive).base64EncodedString()
let publicKey = privateKey.publicKey.rawRepresentation.base64EncodedString()
try Data("\(signature)\n".utf8).write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
let plist = try PropertyListSerialization.data(
    fromPropertyList: ["SUPublicEDKey": publicKey],
    format: .xml,
    options: 0
)
try plist.write(to: URL(fileURLWithPath: CommandLine.arguments[3]))
try Data("Signed release.\n\n<!-- sparkle:edSignature=\(signature) -->\n".utf8)
    .write(to: URL(fileURLWithPath: CommandLine.arguments[4]))
