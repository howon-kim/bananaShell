// Run with: swiftc -parse-as-library Sources/TabTypography.swift Sources/PublicKeyPanel.swift Tests/SSHKeyGenerationChecks.swift -o /tmp/bananaShell-key-checks && /tmp/bananaShell-key-checks
import Foundation

@main
struct SSHKeyGenerationChecks {
    static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) {
        do {
            let passed = try condition()
            precondition(passed, message)
        } catch { preconditionFailure("\(message): \(error)") }
    }

    static func expect(_ failure: SSHKeyGenerator.Failure, _ action: () throws -> Void) throws {
        do {
            try action()
            preconditionFailure("Expected \(failure)")
        } catch let error as SSHKeyGenerator.Failure {
            require(String(describing: error) == String(describing: failure), "Unexpected error: \(error)")
        }
    }

    static func sshKeygen(_ arguments: [String]) throws -> (Int32, String) {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let result = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: result, as: UTF8.self))
    }

    static func main() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("bananaShell-key-checks-" + UUID().uuidString)
        defer { try? manager.removeItem(at: root) }
        let folder = root.appendingPathComponent(".ssh")
        require(SSHKeyGenerator.suggestedName(in: folder) == "id_ed25519", "Unexpected initial name")
        // This passphrase and every key below are disposable test fixtures, never user credentials.
        let secret = "disposable-bananaShell-key-test"
        let publicURL = try SSHKeyGenerator.generate(in: folder, filename: "id_ed25519", comment: "disposable test", passphrase: secret)
        let privateURL = folder.appendingPathComponent("id_ed25519")
        let identity = try PublicIdentity(publicURL)
        require(identity.algorithm == "ED25519", "Wrong algorithm")
        require(try manager.attributesOfItem(atPath: folder.path)[.posixPermissions] as? Int == 0o700, "SSH directory must be 0700")
        require(try manager.attributesOfItem(atPath: privateURL.path)[.posixPermissions] as? Int == 0o600, "Private key must be 0600")
        require(try manager.attributesOfItem(atPath: publicURL.path)[.posixPermissions] as? Int == 0o644, "Public key must be 0644")
        let unlocked = try sshKeygen(["-y", "-P", secret, "-f", privateURL.path])
        require(unlocked.0 == 0 && unlocked.1.hasPrefix("ssh-ed25519 "), "Cannot unlock generated key")
        require(try sshKeygen(["-y", "-P", "wrong-disposable-passphrase", "-f", privateURL.path]).0 != 0, "Private key is not encrypted")
        require(try sshKeygen(["-lf", publicURL.path]).1.contains(identity.fingerprint), "Fingerprint differs from OpenSSH")
        print("PASS: Ed25519 pair, encryption, fingerprint, and permissions")

        let variants: [(SSHKeyAlgorithm, Int?, Int, String)] = [
            (.rsa, 2048, 2048, "ssh-rsa"), (.rsa, 3072, 3072, "ssh-rsa"), (.rsa, nil, 4096, "ssh-rsa"),
            (.ecdsa, nil, 256, "ecdsa-sha2-nistp256"), (.ecdsa, 384, 384, "ecdsa-sha2-nistp384"),
            (.ecdsa, 521, 521, "ecdsa-sha2-nistp521")
        ]
        for (algorithm, requestedBits, expectedBits, prefix) in variants {
            let filename = "\(algorithm.rawValue)_\(expectedBits)"
            let publicKey = try SSHKeyGenerator.generate(in: folder, filename: filename, comment: "disposable variant test",
                                                        passphrase: secret, algorithm: algorithm, bitCount: requestedBits)
            let privateKey = folder.appendingPathComponent(filename)
            let parsed = try PublicIdentity(publicKey)
            let fingerprint = try sshKeygen(["-lf", publicKey.path])
            require(parsed.publicLine.hasPrefix(prefix + " "), "Wrong public key type for \(filename)")
            require(fingerprint.0 == 0 && fingerprint.1.hasPrefix("\(expectedBits) ") && fingerprint.1.contains(parsed.fingerprint),
                    "Wrong key size or fingerprint for \(filename)")
            let decrypted = try sshKeygen(["-y", "-P", secret, "-f", privateKey.path])
            require(decrypted.0 == 0 && decrypted.1.hasPrefix(prefix + " "), "Cannot unlock \(filename)")
            require(try manager.attributesOfItem(atPath: privateKey.path)[.posixPermissions] as? Int == 0o600, "Incorrect private key permissions")
            if requestedBits == nil {
                require(try sshKeygen(["-y", "-P", "wrong-disposable-passphrase", "-f", privateKey.path]).0 != 0,
                        "Private key is not encrypted: \(filename)")
            }
            print("PASS: \(algorithm.label) \(expectedBits), encrypted key and OpenSSH fingerprint")
        }
        require(SSHKeyGenerator.suggestedName(in: folder, algorithm: .rsa) == "id_rsa", "Incorrect RSA default filename")
        require(SSHKeyGenerator.suggestedName(in: folder, algorithm: .ecdsa) == "id_ecdsa", "Incorrect ECDSA default filename")
        try Data("reserved".utf8).write(to: folder.appendingPathComponent("id_rsa.pub"))
        require(SSHKeyGenerator.suggestedName(in: folder, algorithm: .rsa) == "id_rsa_2", "RSA suggestion must avoid existing public files")
        try expect(.invalidKeySize) { _ = try SSHKeyGenerator.generate(in: folder, filename: "weak_rsa", comment: "", passphrase: "", algorithm: .rsa, bitCount: 1024) }
        try expect(.invalidKeySize) { _ = try SSHKeyGenerator.generate(in: folder, filename: "bad_ecdsa", comment: "", passphrase: "", algorithm: .ecdsa, bitCount: 2048) }
        try expect(.invalidKeySize) { _ = try SSHKeyGenerator.generate(in: folder, filename: "bad_ed25519", comment: "", passphrase: "", algorithm: .ed25519, bitCount: 4096) }
        print("PASS: algorithm-specific filenames and invalid key sizes")

        let beforePrivate = try Data(contentsOf: privateURL), beforePublic = try Data(contentsOf: publicURL)
        try expect(.alreadyExists) { _ = try SSHKeyGenerator.generate(in: folder, filename: "id_ed25519", comment: "", passphrase: "") }
        require(try Data(contentsOf: privateURL) == beforePrivate && Data(contentsOf: publicURL) == beforePublic, "Existing pair was modified")
        let orphan = folder.appendingPathComponent("public_only.pub")
        try Data("existing public file".utf8).write(to: orphan)
        try expect(.alreadyExists) { _ = try SSHKeyGenerator.generate(in: folder, filename: "public_only", comment: "", passphrase: "") }
        require(try String(contentsOf: orphan, encoding: .utf8) == "existing public file", "Existing public file was modified")
        let symlink = folder.appendingPathComponent("id_ed25519_2")
        try manager.createSymbolicLink(at: symlink, withDestinationURL: root.appendingPathComponent("missing"))
        try expect(.alreadyExists) { _ = try SSHKeyGenerator.generate(in: folder, filename: "id_ed25519_2", comment: "", passphrase: "") }
        require(SSHKeyGenerator.suggestedName(in: folder) == "id_ed25519_3", "Suggested name must skip dangling symlinks")
        require(try manager.destinationOfSymbolicLink(atPath: symlink.path) == root.appendingPathComponent("missing").path, "Symlink was modified")
        print("PASS: existing private/public files and dangling symlinks are preserved")

        for filename in ["", "../escape", "/absolute", ".hidden", "bad/name", "key.pub", "key.PUB", "bad\nname", String(repeating: "a", count: 129)] {
            try expect(.invalidName) { _ = try SSHKeyGenerator.generate(in: folder, filename: filename, comment: "", passphrase: "") }
        }
        try expect(.invalidComment) { _ = try SSHKeyGenerator.generate(in: folder, filename: "bad_comment", comment: "first\nsecond", passphrase: "") }
        try expect(.invalidComment) { _ = try SSHKeyGenerator.generate(in: folder, filename: "unicode_comment", comment: "first\u{2028}second", passphrase: "") }
        try expect(.invalidPassphrase) { _ = try SSHKeyGenerator.generate(in: folder, filename: "bad_secret", comment: "", passphrase: "first\nsecond") }
        try expect(.invalidPassphrase) { _ = try SSHKeyGenerator.generate(in: folder, filename: "unicode_secret", comment: "", passphrase: "first\u{2028}second") }
        try expect(.invalidPassphrase) { _ = try SSHKeyGenerator.generate(in: folder, filename: "long_secret", comment: "", passphrase: String(repeating: "€", count: 400)) }
        print("PASS: path traversal, public-key suffixes, control characters, and oversized input are rejected")

        let plainPublic = try SSHKeyGenerator.generate(in: folder, filename: "plain_key", comment: "", passphrase: "")
        require(try PublicIdentity(plainPublic).algorithm == "ED25519", "Invalid unencrypted public key")
        require(try sshKeygen(["-y", "-P", "", "-f", folder.appendingPathComponent("plain_key").path]).0 == 0, "Empty passphrase does not work")
        require(try manager.contentsOfDirectory(atPath: folder.path).allSatisfy { !$0.hasPrefix(".bananaShell-key-") }, "Staging directory leaked")
        print("PASS: optional empty passphrase and staging cleanup")
    }
}
