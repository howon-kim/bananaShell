import Foundation
import Security

/// Listing and searching use metadata only; the secret is retrieved on demand.
struct APIKeyRecord: Identifiable, Equatable, Sendable {
    let id: UUID
    let name: String
    let service: String
    let link: URL?
    let createdAt: Date?
    let modifiedAt: Date?
}

struct APIKeyStore: Sendable {
    let namespace: String
    init(namespace: String = "local.bananaShell.api-keys") { self.namespace = namespace }

    enum Failure: LocalizedError, Equatable {
        case invalidName, invalidService, invalidLink, invalidSecret, invalidRecord, keychain(OSStatus)
        var errorDescription: String? {
            switch self {
            case .invalidName: return "Enter a name of up to 100 characters without line breaks or control characters."
            case .invalidService: return "Keep the service name within 100 characters, without line breaks or control characters."
            case .invalidLink: return "Enter a full http:// or https:// address without spaces or embedded sign-in details (up to 2,048 bytes)."
            case .invalidSecret: return "Enter a single API key without spaces, line breaks, or control characters (up to 16 KiB)."
            case .invalidRecord: return "The saved API key could not be read."
            case .keychain(let status):
                if status == errSecItemNotFound { return "This API key no longer exists. Refresh the list and try again." }
                if status == errSecUserCanceled { return "Keychain access was cancelled." }
                if status == errSecInteractionNotAllowed { return "Unlock your login keychain and try again." }
                return "Keychain: " + ((SecCopyErrorMessageString(status, nil) as String?) ?? "The operation failed (\(status)).")
            }
        }
    }

    // Use the Mac's local keychain, with its normal application access controls.
    // Do not opt these items into iCloud synchronization or broaden their ACL.
    // https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: namespace,
         kSecAttrSynchronizable as String: false]
    }

    private func query(for id: UUID) -> [String: Any] {
        var result = query
        result[kSecAttrAccount as String] = id.uuidString
        return result
    }

    func list() throws -> [APIKeyRecord] {
        var request = query
        request[kSecMatchLimit as String] = kSecMatchLimitAll
        request[kSecReturnAttributes as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw Failure.keychain(status) }
        guard let attributes = result as? [[String: Any]] else { throw Failure.invalidRecord }
        return try attributes.map { item in
            guard let account = item[kSecAttrAccount as String] as? String, let id = UUID(uuidString: account),
                  let name = item[kSecAttrLabel as String] as? String else { throw Failure.invalidRecord }
            // The file-based Mac keychain omits generic attributes whose data
            // is empty. An omitted optional service is still a valid record.
            let data = item[kSecAttrGeneric as String] as? Data ?? Data()
            guard let service = String(data: data, encoding: .utf8) else { throw Failure.invalidRecord }
            let link = try Self.linkURL(item[kSecAttrComment as String] as? String ?? "")
            return APIKeyRecord(id: id, name: name, service: service, link: link,
                                createdAt: item[kSecAttrCreationDate as String] as? Date,
                                modifiedAt: item[kSecAttrModificationDate as String] as? Date)
        }.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id.uuidString < $1.id.uuidString : order == .orderedAscending
        }
    }

    @discardableResult
    func add(id: UUID = UUID(), name: String, service: String, link: String = "", secret: String) throws -> UUID {
        var item = query(for: id)
        item.merge(try metadata(name: name, service: service, link: link)) { _, new in new }
        item[kSecValueData as String] = try secretData(secret)
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure.keychain(status) }
        return id
    }

    /// A nil replacement preserves the existing secret without reading it.
    func update(id: UUID, name: String, service: String, link: String? = nil, secret: String? = nil) throws {
        var values = try metadata(name: name, service: service, link: link)
        if let secret { values[kSecValueData as String] = try secretData(secret) }
        let status = SecItemUpdate(query(for: id) as CFDictionary, values as CFDictionary)
        guard status == errSecSuccess else { throw Failure.keychain(status) }
    }

    func secret(for id: UUID) throws -> String {
        var request = query(for: id)
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        request[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        guard status == errSecSuccess else { throw Failure.keychain(status) }
        guard let data = result as? Data, let secret = String(data: data, encoding: .utf8) else { throw Failure.invalidRecord }
        return secret
    }

    func delete(id: UUID) throws {
        let status = SecItemDelete(query(for: id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure.keychain(status) }
    }

    private func metadata(name: String, service: String, link: String?) throws -> [String: Any] {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let service = service.trimmingCharacters(in: .whitespacesAndNewlines)
        let controls = CharacterSet.controlCharacters.union(.newlines)
        guard !name.isEmpty, name.count <= 100, name.rangeOfCharacter(from: controls) == nil else { throw Failure.invalidName }
        guard service.count <= 100, service.rangeOfCharacter(from: controls) == nil else { throw Failure.invalidService }
        var values: [String: Any] = [kSecAttrLabel as String: name,
                                     kSecAttrGeneric as String: Data(service.utf8),
                                     kSecAttrDescription as String: "bananaShell API key"]
        if let link { values[kSecAttrComment as String] = try Self.linkURL(link)?.absoluteString ?? "" }
        return values
    }

    private static func linkURL(_ text: String) throws -> URL? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        guard text.utf8.count <= 2048,
              text.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil,
              let components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              let url = components.url else { throw Failure.invalidLink }
        return url
    }

    private func secretData(_ secret: String) throws -> Data {
        let data = Data(secret.utf8)
        guard !data.isEmpty, data.count <= 16 * 1024,
              secret.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil else { throw Failure.invalidSecret }
        return data
    }
}
