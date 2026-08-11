import CryptoKit
import Foundation

enum VerificationError: Error, CustomStringConvertible {
    case invalid(String)

    var description: String {
        switch self {
        case let .invalid(message): message
        }
    }
}

func canonicalBase64(_ value: String, byteCount: Int, label: String) throws -> Data {
    guard let decoded = Data(base64Encoded: value),
          decoded.count == byteCount,
          decoded.base64EncodedString() == value
    else {
        throw VerificationError.invalid("\(label) must be canonical Base64 encoding of exactly \(byteCount) bytes")
    }
    return decoded
}

@main
enum VerifySparkleSignature {
    static func main() {
        do {
            guard CommandLine.arguments.count == 4 else {
                throw VerificationError.invalid("usage: verify_sparkle_signature <archive> <signature-file> <Info.plist>")
            }

            let archiveURL = URL(fileURLWithPath: CommandLine.arguments[1])
            let signatureURL = URL(fileURLWithPath: CommandLine.arguments[2])
            let plistURL = URL(fileURLWithPath: CommandLine.arguments[3])
            let signatureFile = try String(contentsOf: signatureURL, encoding: .utf8)
            guard signatureFile.hasSuffix("\n"), !signatureFile.dropLast().contains(where: \Character.isNewline) else {
                throw VerificationError.invalid("signature file must contain exactly one newline-terminated value")
            }
            let signatureValue = String(signatureFile.dropLast())
            let signature = try canonicalBase64(signatureValue, byteCount: 64, label: "signature")

            let plistData = try Data(contentsOf: plistURL)
            guard let plist = try PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any],
                  let publicKeyValue = plist["SUPublicEDKey"] as? String
            else {
                throw VerificationError.invalid("Info.plist must contain SUPublicEDKey")
            }
            let publicKeyData = try canonicalBase64(publicKeyValue, byteCount: 32, label: "SUPublicEDKey")
            let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData)
            let archive = try Data(contentsOf: archiveURL, options: [.mappedIfSafe])
            guard publicKey.isValidSignature(signature, for: archive) else {
                throw VerificationError.invalid("Sparkle Ed25519 signature verification failed")
            }
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            exit(1)
        }
    }
}
