// swiftc -parse-as-library Sources/APIKeyStore.swift Tests/APIKeyStoreChecks.swift -o /tmp/banana-api-key-checks
// Uses only disposable entries under fresh service namespaces; never reads user credentials.
import Foundation
import Security

@main struct APIKeyStoreChecks {
    static func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try value() else { throw NSError(domain: "APIKeyStoreChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    static func expect(_ failure: APIKeyStore.Failure, _ action: () throws -> Void) throws {
        do {
            try action()
            throw NSError(domain: "APIKeyStoreChecks", code: 2, userInfo: [NSLocalizedDescriptionKey: "Expected validation failure"])
        } catch let error as APIKeyStore.Failure { try check(error == failure, "Unexpected failure kind") }
    }
    static func main() throws {
        let namespace = "local.bananaShell.api-key-checks." + UUID().uuidString
        let store = APIKeyStore(namespace: namespace)
        let other = APIKeyStore(namespace: namespace + ".other")
        let first = UUID(), second = UUID(), optional = UUID()
        defer {
            try? store.delete(id: first); try? store.delete(id: second)
            try? store.delete(id: optional)
            try? other.delete(id: first)
        }
        try check(store.list().isEmpty, "Fresh namespace is not empty")
        try store.add(id: optional, name: "No service", service: "", secret: "bananaShell-disposable-optional")
        try check(store.list().first?.service == "" && store.list().first?.link == nil, "Omitted optional metadata broke listing")
        try store.update(id: optional, name: "No service", service: "Temporary")
        try store.update(id: optional, name: "No service", service: "")
        try check(store.list().first?.service == "", "Clearing a service broke listing")
        try check(store.secret(for: optional) == "bananaShell-disposable-optional", "Clearing metadata changed a secret")
        try store.delete(id: optional)
        // Existing records predate the link attribute and keep their raw UTF-8 service.
        let legacy: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: namespace, kSecAttrAccount as String: optional.uuidString,
                                    kSecAttrLabel as String: "Legacy", kSecAttrGeneric as String: Data("Old service".utf8),
                                    kSecValueData as String: Data("bananaShell-disposable-legacy".utf8)]
        try check(SecItemAdd(legacy as CFDictionary, nil) == errSecSuccess, "Legacy fixture could not be added")
        try check(store.list().first?.service == "Old service" && store.list().first?.link == nil, "Legacy metadata did not load")
        try store.update(id: optional, name: "Legacy", service: "Old service", link: "http://localhost:8080/docs")
        try check(store.list().first?.link?.absoluteString == "http://localhost:8080/docs", "Link could not be added to a legacy record")
        try check(store.secret(for: optional) == "bananaShell-disposable-legacy", "Adding a link changed the legacy secret")
        try store.delete(id: optional)
        let link = "https://example.com/dashboard?view=keys#usage"
        try store.add(id: first, name: "Work", service: "Example API", link: "  " + link + "\n", secret: "bananaShell-disposable-alpha")
        try store.add(id: second, name: "개인 키", service: "테스트 서비스", secret: "bananaShell-disposable-beta")
        var records = try store.list()
        try check(records.count == 2 && records.contains { $0.id == second && $0.service == "테스트 서비스" }, "Metadata listing failed")
        try check(APIKeyStore(namespace: namespace).secret(for: first) == "bananaShell-disposable-alpha", "Secret did not persist")
        try check(APIKeyStore(namespace: namespace).list().first(where: { $0.id == first })?.link?.absoluteString == link, "Link did not persist or trim")
        try expect(.keychain(errSecDuplicateItem)) {
            try store.add(id: first, name: "Overwrite attempt", service: "Other", secret: "replacement")
        }
        try check(store.secret(for: first) == "bananaShell-disposable-alpha", "Duplicate add overwrote a secret")
        try store.update(id: first, name: "Renamed", service: "New service")
        try check(store.secret(for: first) == "bananaShell-disposable-alpha", "Metadata edit changed a secret")
        try check(store.list().first(where: { $0.id == first })?.link?.absoluteString == link, "Unrelated metadata edit cleared the link")
        try expect(.invalidLink) { try store.update(id: first, name: "Invalid edit", service: "Other", link: "javascript:alert(1)") }
        try check(store.list().first(where: { $0.id == first })?.name == "Renamed", "Invalid link partially changed metadata")
        try store.update(id: first, name: "Renamed", service: "New service", link: "https://example.org/api/docs")
        try check(store.list().first(where: { $0.id == first })?.link?.absoluteString == "https://example.org/api/docs", "Link replacement failed")
        try store.update(id: first, name: "Renamed", service: "New service", link: "")
        try check(store.list().first(where: { $0.id == first })?.link == nil, "Clearing a link failed")
        try check(store.secret(for: first) == "bananaShell-disposable-alpha", "Changing a link changed a secret")
        try store.update(id: first, name: "Renamed", service: "New service", secret: "bananaShell-disposable-replaced")
        try check(store.secret(for: first) == "bananaShell-disposable-replaced", "Replacement was not saved")
        records = try store.list()
        try check(records.contains { $0.id == first && $0.name == "Renamed" && $0.service == "New service" && $0.createdAt != nil }, "Updated metadata missing")

        // Attribute-only searches must not include the secret value.
        var raw: CFTypeRef?
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: namespace,
                                    kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitAll]
        let status = SecItemCopyMatching(query as CFDictionary, &raw)
        try check(status == errSecSuccess, "Could not inspect test metadata")
        let attributes = raw as? [[String: Any]] ?? []
        try check(attributes.count == 2 && attributes.allSatisfy { $0[kSecValueData as String] == nil }, "List query returned secret data")
        try expect(.keychain(errSecItemNotFound)) { _ = try other.secret(for: first) }
        try other.add(id: first, name: "Isolated", service: "Other", secret: "bananaShell-disposable-isolated")
        try check(store.secret(for: first) != other.secret(for: first), "Namespaces are not isolated")
        try store.delete(id: first)
        try check(other.secret(for: first) == "bananaShell-disposable-isolated", "Deletion affected another namespace")
        try store.delete(id: first) // idempotent, scoped deletion
        try expect(.keychain(errSecItemNotFound)) { _ = try store.secret(for: first) }
        try store.delete(id: second)
        try check(store.list().isEmpty, "Deleted entries remain")
        try expect(.invalidName) { try store.add(name: "  ", service: "Test", secret: "test") }
        try expect(.invalidService) { try store.add(name: "Test", service: "a\nb", secret: "test") }
        for value in ["example.com/docs", "//example.com", "https://", "file:///tmp/test", "javascript:alert(1)",
                      "https://user:password@example.com", "https://user@example.com", "https://example.com/a b",
                      "https://example.com/a\nb", "https://example.com/" + String(repeating: "a", count: 2048)] {
            try expect(.invalidLink) { try store.add(name: "Invalid", service: "Test", link: value, secret: "test") }
        }
        for value in ["", "key with spaces", "key\nline", "key\u{0}", String(repeating: "x", count: 16 * 1024 + 1)] {
            try expect(.invalidSecret) { try store.add(name: "Invalid", service: "Test", secret: value) }
        }
        try check(store.list().isEmpty, "Validation failure created an entry")
        print("API key checks passed: Keychain CRUD, links, legacy records, persistence, metadata-only listing, preservation, isolation and validation.")
    }
}
