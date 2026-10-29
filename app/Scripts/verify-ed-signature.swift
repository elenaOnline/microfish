// Check Sparkle EdDSA signatures against a PUBLIC key, the way an installed Microfish does.
// Sparkle's own sign_update --verify derives the public key from the private one, so it cannot answer
// "does this archive verify against the SUPublicEDKey that is in the app we are about to ship?".
//
//   verify-ed-signature zip  FILE --public-key B64 (--signature B64 | --signature-output FILE)
//       FILE is the update archive. --signature-output is a file holding sign_update's line
//       `sparkle:edSignature="..." length="N"`; length, when present, must equal the file size.
//   verify-ed-signature feed FILE --public-key B64
//       FILE is an appcast signed with `sign_update FILE`: it ends with
//       `<!-- sparkle-signatures:\nedSignature: B64\nlength: N\n-->`, and the signature covers the first N bytes.
//   verify-ed-signature public-key --private-key-file FILE
//       prints the public key of a 32-byte-seed private key file (tests with throwaway keys).
//
// Exit 0 = verified, 1 = does not verify, 2 = bad usage or unreadable input. Build: swiftc -O verify-ed-signature.swift -o ...
import CryptoKit
import Foundation

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("verify-ed-signature: \(message)\n".utf8))
    exit(code)
}

var args = Array(CommandLine.arguments.dropFirst())
guard let mode = args.first else { fail("usage: verify-ed-signature zip|feed|public-key ... (see the header of this file)", code: 2) }
args.removeFirst()
var file: String?
var opts: [String: String] = [:]
var i = 0
while i < args.count {
    if args[i].hasPrefix("--") {
        guard i + 1 < args.count else { fail("\(args[i]) needs a value", code: 2) }
        opts[args[i]] = args[i + 1]; i += 2
    } else { file = args[i]; i += 1 }
}

func decode(_ b64: String, what: String, bytes: Int) -> Data {
    guard let d = Data(base64Encoded: b64.trimmingCharacters(in: .whitespacesAndNewlines)), d.count == bytes else {
        fail("\(what) is not base64 of \(bytes) bytes", code: 2)
    }
    return d
}
func publicKey() -> Curve25519.Signing.PublicKey {
    guard let k = opts["--public-key"] else { fail("--public-key is required", code: 2) }
    do { return try Curve25519.Signing.PublicKey(rawRepresentation: decode(k, what: "the public key", bytes: 32)) }
    catch { fail("not a valid Ed25519 public key", code: 2) }
}
func read(_ path: String?) -> Data {
    guard let path else { fail("a file argument is required", code: 2) }
    guard let d = FileManager.default.contents(atPath: path) else { fail("cannot read \(path)", code: 2) }
    return d
}

switch mode {
case "public-key":
    guard let path = opts["--private-key-file"] else { fail("--private-key-file is required", code: 2) }
    let seed = decode(String(decoding: read(path), as: UTF8.self), what: "the private key", bytes: 32)
    print((try! Curve25519.Signing.PrivateKey(rawRepresentation: seed)).publicKey.rawRepresentation.base64EncodedString())

case "zip":
    let data = read(file)
    var signature = opts["--signature"], length: Int?
    if let path = opts["--signature-output"] {
        let text = String(decoding: read(path), as: UTF8.self)
        func attr(_ name: String) -> String? {
            guard let r = text.range(of: "\(name)=\"") else { return nil }
            let rest = text[r.upperBound...]
            return rest.firstIndex(of: "\"").map { String(rest[..<$0]) }
        }
        signature = attr("sparkle:edSignature"); length = attr("length").flatMap(Int.init)
    }
    guard let sig = signature else { fail("no signature given", code: 2) }
    if let length, length != data.count { fail("the signature line says length \(length) but the file is \(data.count) bytes") }
    let raw = decode(sig, what: "the signature", bytes: 64)
    guard publicKey().isValidSignature(raw, for: data) else { fail("the archive's EdDSA signature does NOT verify against the given public key") }
    print("zip signature verifies (\(data.count) bytes)")

case "feed":
    let data = read(file)
    let marker = Data("<!-- sparkle-signatures:".utf8)
    guard let r = data.range(of: marker, options: .backwards) else { fail("the feed carries no sparkle-signatures block (not signed)") }
    let signed = data[data.startIndex..<r.lowerBound]
    let block = String(decoding: data[r.lowerBound...], as: UTF8.self)
    func field(_ name: String) -> String? {
        for line in block.split(whereSeparator: \.isNewline) where line.hasPrefix("\(name):") {
            return line.dropFirst(name.count + 1).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }
    guard let sig = field("edSignature") else { fail("the sparkle-signatures block has no edSignature") }
    guard let n = field("length").flatMap(Int.init), n == signed.count else {
        fail("the signed length does not match the feed (the feed was edited after signing, or the block is not at the end)")
    }
    let rest = String(decoding: data[r.lowerBound...], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    guard rest.hasSuffix("-->"), rest.components(separatedBy: "<!--").count == 2 else { fail("unexpected content after the signature block") }
    guard publicKey().isValidSignature(decode(sig, what: "the signature", bytes: 64), for: Data(signed)) else {
        fail("the appcast's EdDSA signature does NOT verify against the given public key")
    }
    print("feed signature verifies (\(signed.count) bytes signed)")

default:
    fail("unknown mode \(mode)", code: 2)
}
