import BananaZstd
import Combine
import CryptoKit
import Foundation

struct ShellPlugin: Hashable, Identifiable {
    let id: String
    static let suggestions = Self(id: "zsh-autosuggestions")
    static let highlighting = Self(id: "zsh-syntax-highlighting")
    static let corrections = Self(id: "pay-respects")
    static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("bananaShell/Plugins", isDirectory: true)
    }

    var detail: String {
        switch self {
        case .suggestions: return "Suggest commands from history as you type. Press → to accept."
        case .highlighting: return "Highlight commands and arguments as you type."
        case .corrections: return "Type f after a failed command to review suggested fixes."
        default: return "Zsh shell extension"
        }
    }

    var environmentKey: String? {
        switch self {
        case .suggestions: return "BANANA_AUTOSUGGESTIONS"
        case .highlighting: return "BANANA_SYNTAX_HIGHLIGHTING"
        case .corrections: return "BANANA_PAY_RESPECTS"
        default: return nil
        }
    }

    static func validName(_ name: String) -> Bool {
        name.utf8.count <= 100 && name.range(of: #"^zsh-[a-z0-9]+(-[a-z0-9]+)*$"#, options: .regularExpression) != nil
    }

    static func validScript(_ name: String) -> Bool {
        name.utf8.count <= 150 && name.range(of: #"^[A-Za-z0-9_-][A-Za-z0-9._-]*\.zsh$"#, options: .regularExpression) != nil
    }

    var entryName: String { self == .corrections ? id : id + ".zsh" }

    func installedScript(in root: URL) -> URL? {
        let directory = root.appendingPathComponent(id)
        var name = entryName
        if environmentKey == nil {
            guard Self.validName(id), let saved = try? String(contentsOf: directory.appendingPathComponent(".bananaShell-entry"),
                                                               encoding: .utf8), Self.validScript(saved) else { return nil }
            name = saved
        }
        let script = directory.appendingPathComponent(name)
        let fm = FileManager.default
        let available = self == .corrections ? fm.isExecutableFile(atPath: script.path) : fm.isReadableFile(atPath: script.path)
        return available ? script : nil
    }

    static func installed(in root: URL) -> [Self] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.filter { validName($0) || $0 == corrections.id }.sorted().map(Self.init)
            .filter { $0.installedScript(in: root) != nil }
    }

    // The existing pay-respects distribution is a standalone binary, separate from the zsh formulae.
    func installPayRespects(to folder: URL) throws {
        let fm = FileManager.default
        let parent = folder.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: staging) }
        #if arch(arm64)
        let arch = "aarch64", digest = "ba11712db3dac2d4548abf4747186751636962271fdcda44d078463dde47e158"
        #else
        let arch = "x86_64", digest = "0754726c1b504cfd471eaf3d0aad8ba763201902f0394ad774f65633712f95ac"
        #endif
        let archive = parent.appendingPathComponent(UUID().uuidString + ".tar.zst")
        defer { try? fm.removeItem(at: archive) }
        let asset = "pay-respects-0.9.0-" + arch + "-apple-darwin.tar.zst"
        try runPluginTool("/usr/bin/curl", ["--disable", "--fail", "--silent", "--show-error", "--location",
                                  "--proto", "=https", "--max-time", "120", "-o", archive.path,
                                  "https://github.com/iffse/pay-respects/releases/download/v0.9.0/" + asset])
        let compressed = try Data(contentsOf: archive)
        let checksum = SHA256.hash(data: compressed).map { String(format: "%02x", $0) }.joined()
        guard checksum == digest else { throw CocoaError(.fileReadCorruptFile) }
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        // Finder-launched apps cannot rely on tar finding an external zstd.
        // The pinned releases expand to less than 32 MiB on both architectures.
        var tar = Data(count: 32 * 1024 * 1024)
        let size = tar.withUnsafeMutableBytes { destination in
            compressed.withUnsafeBytes { source in
                ZSTD_decompress(destination.baseAddress, destination.count, source.baseAddress, source.count)
            }
        }
        guard ZSTD_isError(size) == 0 else { throw CocoaError(.fileReadCorruptFile) }
        tar.count = size
        let plainArchive = archive.deletingPathExtension()
        defer { try? fm.removeItem(at: plainArchive) }
        try tar.write(to: plainArchive)
        try runPluginTool("/usr/bin/tar", ["-xf", plainArchive.path, "-C", staging.path, "pay-respects", "LICENSE"])
        try runPluginTool(staging.appendingPathComponent("pay-respects").path, ["--version"])
        try fm.moveItem(at: staging, to: folder)
    }
}

private func runPluginTool(_ executable: String, _ arguments: [String]) throws {
    let process = Process(), log = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardInput = FileHandle.nullDevice
    process.standardError = log
    try process.run()
    let output = log.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        let message = String(decoding: output.suffix(1600), as: UTF8.self)
        throw NSError(domain: "ShellPlugin", code: 1, userInfo: [NSLocalizedDescriptionKey: message.isEmpty ? "Download failed. Check your connection and try again." : message])
    }
}

enum ShellPluginStartup {
    static var environment: [String] { environment(in: ShellPlugin.root, defaults: .standard) }

    static func environment(in root: URL, defaults: UserDefaults) -> [String] {
        var entries: [String] = [], catalogScripts: [String] = []
        for plugin in ShellPlugin.installed(in: root) where defaults.bool(forKey: "plugin." + plugin.id) {
            guard let script = plugin.installedScript(in: root) else { continue }
            if let key = plugin.environmentKey { entries.append(key + "=" + script.path) }
            else { catalogScripts.append(plugin.id + "/" + script.lastPathComponent) }
        }
        if !catalogScripts.isEmpty {
            entries += ["BANANA_EXTENSION_ROOT=" + root.path, "BANANA_EXTENSION_SCRIPTS=" + catalogScripts.joined(separator: ":")]
        }
        return entries
    }
}

/// Homebrew metadata shared by the search index, the local cache and the installer.
struct HomebrewFormula: Codable, Equatable {
    struct Versions: Codable, Equatable { let stable: String }
    struct Source: Codable, Equatable { let url: URL; let checksum: String }
    struct URLs: Codable, Equatable { let stable: Source }

    let name: String
    let license: String
    let versions: Versions
    let urls: URLs

    var desc: String?
    var homepage: URL?
    var caveats: String?
    var dependencies: [String]?
    var disabled: Bool?
    var deprecated: Bool?

    var scriptName: String? {
        let plugin = ShellPlugin(id: name)
        if plugin == .suggestions || plugin == .highlighting { return plugin.entryName }
        // Only interpret a documented source filename. Never execute formula caveats as shell code.
        guard let caveats, !caveats.contains("before any calls to compdef") else { return nil }
        let prefixes = ["$HOMEBREW_PREFIX/share/" + name + "/", "$HOMEBREW_PREFIX/opt/" + name + "/share/" + name + "/"]
        for line in caveats.components(separatedBy: .newlines) {
            let fields = line.split(whereSeparator: { $0.isWhitespace })
            guard fields.count == 2, fields[0] == "source" else { continue }
            let path = String(fields[1]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            for prefix in prefixes where path.hasPrefix(prefix) {
                let file = String(path.dropFirst(prefix.count))
                if ShellPlugin.validScript(file) { return file }
            }
        }
        return nil
    }

    static func decode(_ data: Data, for plugin: ShellPlugin) throws -> Self {
        try JSONDecoder().decode(Self.self, from: data).validated(for: plugin)
    }

    func validated(for plugin: ShellPlugin) throws -> Self {
        let version = versions.stable, source = urls.stable
        let allowedVersion = CharacterSet(charactersIn: "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ.-_")
        let repository: String
        if plugin == .suggestions || plugin == .highlighting {
            repository = "https://github.com/zsh-users/" + plugin.id
        } else {
            guard ShellPlugin.validName(name), dependencies?.isEmpty == true, let homepage,
                  homepage.absoluteString.range(of: #"^https://github\.com/[A-Za-z0-9_-]+/[A-Za-z0-9_.-]+/?$"#,
                                                options: .regularExpression) != nil else {
                throw ExtensionError("This extension requires a different installer.")
            }
            repository = homepage.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        let base = repository + "/archive/"
        let acceptedURLs = ["", "refs/tags/"].flatMap { path in
            ["", "v"].map { base + path + $0 + version + ".tar.gz" }
        }
        guard scriptName != nil, disabled != true, deprecated != true, name == plugin.id, !license.isEmpty,
              (1...64).contains(version.utf8.count), version.unicodeScalars.allSatisfy(allowedVersion.contains),
              acceptedURLs.contains(source.url.absoluteString),
              source.checksum.utf8.count == 64, source.checksum.utf8.allSatisfy({
                  (48...57).contains($0) || (97...102).contains($0)
              }) else { throw ExtensionError("Homebrew returned an unsupported release for " + plugin.id + ".") }
        return self
    }

    static let receiptName = ".bananaShell-sha256"

    func usageExcerpt(session: URLSession = .shared) async -> String? {
        // Read the README belonging to the same release as the catalog entry.
        let archive = urls.stable.url
        let parts = archive.pathComponents
        guard archive.host == "github.com", parts.count >= 5 else { return nil }
        let repo = URL(string: "https://api.github.com/repos")!.appendingPathComponent(parts[1]).appendingPathComponent(parts[2])
        let tag = archive.deletingPathExtension().deletingPathExtension().lastPathComponent
        var request = URLRequest(url: repo.appendingPathComponent("readme").appending(queryItems: [.init(name: "ref", value: tag)]),
                                 timeoutInterval: 8)
        request.setValue("application/vnd.github.raw+json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await session.data(for: request)
            try Self.check(response)
            let lines = String(decoding: data.prefix(256_000), as: UTF8.self).components(separatedBy: .newlines)
            let headings = ["usage", "basic usage", "how to use", "examples", "example", "features"]
            for heading in headings {
                guard let start = lines.firstIndex(where: { line in
                    line.hasPrefix("#") && line.drop(while: { $0 == "#" })
                        .trimmingCharacters(in: .whitespaces).lowercased() == heading
                }) else { continue }
                let section = lines.dropFirst(start + 1).drop(while: { $0.isEmpty }).prefix(while: { !$0.hasPrefix("#") })
                let excerpt = section.filter {
                    !$0.hasPrefix("```") && !$0.hasPrefix("![") && !$0.hasPrefix("[![") && !$0.hasPrefix("<")
                }.prefix(10).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !excerpt.isEmpty { return String(excerpt.prefix(700)) }
            }
        } catch { return nil }
        return nil
    }

    func isInstalled(in folder: URL) -> Bool {
        (try? String(contentsOf: folder.appendingPathComponent(Self.receiptName), encoding: .utf8)) == urls.stable.checksum
    }

    func install(_ plugin: ShellPlugin, to folder: URL, session: URLSession) async throws {
        let (archive, response) = try await session.download(for: URLRequest(url: urls.stable.url, timeoutInterval: 90))
        defer { try? FileManager.default.removeItem(at: archive) }
        try Self.check(response)
        try installArchive(archive, for: plugin, to: folder)
    }

    func installArchive(_ archive: URL, for plugin: ShellPlugin, to folder: URL) throws {
        let fm = FileManager.default
        let bytes = try Data(contentsOf: archive, options: .mappedIfSafe)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        guard digest == urls.stable.checksum else {
            throw ExtensionError("The downloaded archive did not match the Homebrew checksum.")
        }

        let parent = folder.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: staging) }
        try runPluginTool("/usr/bin/tar", ["-xzf", archive.path, "-C", staging.path, "--strip-components", "1",
                                           "--no-same-owner", "--no-same-permissions"])
        guard let scriptName else { throw ExtensionError("Missing zsh entry script in the catalog.") }
        let script = staging.appendingPathComponent(scriptName)
        // Some upstream entrypoints are symlinks to another file in the same release.
        let target = script.resolvingSymlinksInPath().standardizedFileURL
        let releaseRoot = staging.resolvingSymlinksInPath().standardizedFileURL.path
        guard target.path.hasPrefix(releaseRoot + "/"),
              (try? target.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
              fm.isReadableFile(atPath: target.path) else {
            throw ExtensionError("The release is missing its zsh entry script.")
        }
        if plugin.environmentKey == nil {
            try scriptName.write(to: staging.appendingPathComponent(".bananaShell-entry"), atomically: true, encoding: .utf8)
        }
        try digest.write(to: staging.appendingPathComponent(Self.receiptName), atomically: true, encoding: .utf8)
        if fm.fileExists(atPath: folder.path) {
            // Both directories are on the same volume. A failed swap leaves the old install usable.
            guard renamex_np(staging.path, folder.path, UInt32(RENAME_SWAP)) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } else {
            try fm.moveItem(at: staging, to: folder)
        }
    }

    static func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, http.url?.scheme == "https" else {
            throw ExtensionError("Expected an HTTPS response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ExtensionError("The server returned HTTP " + String(http.statusCode) + ".")
        }
    }
}

private struct ExtensionError: LocalizedError {
    var errorDescription: String?
    init(_ description: String) { errorDescription = description }
}

// Skip unrelated formulae without decoding their recipes. A malformed or unsupported row
// cannot prevent the other extensions from appearing in search.
private struct FormulaCandidate: Decodable {
    enum Key: CodingKey { case name }
    let release: HomebrewFormula?
    init(from decoder: Decoder) throws {
        let fields = try? decoder.container(keyedBy: Key.self)
        if let name = try? fields?.decode(String.self, forKey: .name), ShellPlugin.validName(name) {
            release = try? HomebrewFormula(from: decoder).validated(for: ShellPlugin(id: name))
        } else { release = nil }
    }
}

enum ExtensionIndex {
    static let url = URL(string: "https://formulae.brew.sh/api/formula.json")!

    static func decode(_ data: Data) throws -> [ShellPlugin: HomebrewFormula] {
        var result: [ShellPlugin: HomebrewFormula] = [:]
        for row in try JSONDecoder().decode([FormulaCandidate].self, from: data) {
            if let release = row.release { result[ShellPlugin(id: release.name)] = release }
        }
        guard !result.isEmpty else { throw ExtensionError("No compatible zsh extensions in the Homebrew index.") }
        return result
    }

    static func fetch(session: URLSession) async throws -> [ShellPlugin: HomebrewFormula] {
        let request = URLRequest(url: url, cachePolicy: .reloadRevalidatingCacheData, timeoutInterval: 45)
        let (file, response) = try await session.download(for: request)
        defer { try? FileManager.default.removeItem(at: file) }
        try HomebrewFormula.check(response)
        return try decode(Data(contentsOf: file, options: .mappedIfSafe))
    }

    static func matches(_ query: String, in fields: [String]) -> Bool {
        let text = fields.joined(separator: " ")
        return query.split(whereSeparator: { $0.isWhitespace }).allSatisfy { text.localizedCaseInsensitiveContains(String($0)) }
    }
}

@MainActor
final class PluginCatalog: ObservableObject {
    static let shared = PluginCatalog(bundledFolder: PromptSetup.folder)
    @Published private(set) var formulae: [ShellPlugin: HomebrewFormula] = [:]
    @Published private(set) var refreshing = false
    @Published private(set) var catalogNote: String?
    @Published private(set) var installing: String?
    @Published private(set) var removing: ShellPlugin?
    var changingInstallation: Bool { installing != nil || removing != nil }
    @Published private(set) var failure: String?
    private let cache: URL
    let pluginsDirectory: URL
    private let defaults: UserDefaults
    private let session: URLSession
    private var lastRefresh: Date?

    init(bundledFolder: URL?, cache: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("bananaShell/HomebrewExtensions"), session: URLSession = .shared,
         pluginsDirectory: URL = ShellPlugin.root, defaults: UserDefaults = .standard) {
        self.cache = cache
        self.session = session
        self.pluginsDirectory = pluginsDirectory
        self.defaults = defaults
        let bundled = bundledFolder?.appendingPathComponent("HomebrewExtensions")
        let index = cache.appendingPathComponent("index.json")
        if let data = try? Data(contentsOf: index), let releases = try? ExtensionIndex.decode(data) {
            formulae = releases
            lastRefresh = try? index.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        } else {
            if let file = bundled?.appendingPathComponent("discovery.json"), let data = try? Data(contentsOf: file),
               let releases = try? ExtensionIndex.decode(data) { formulae = releases }
            // Import the per-formula cache created by earlier versions.
            for plugin in [ShellPlugin.suggestions, .highlighting] {
                let file = plugin.id + ".json"
                for url in [cache.appendingPathComponent(file), bundled?.appendingPathComponent(file)].compactMap({ $0 }) {
                    if let data = try? Data(contentsOf: url), let release = try? HomebrewFormula.decode(data, for: plugin) {
                        formulae[plugin] = release
                        break
                    }
                }
            }
        }
        installed = Set(ShellPlugin.installed(in: pluginsDirectory))
    }

    @Published private(set) var installed: Set<ShellPlugin> = []

    func results(matching query: String, installedOnly: Bool = false) -> [ShellPlugin] {
        let available = installedOnly ? installed : installed.union(formulae.keys).union([.corrections])
        return available.filter { plugin in
            let formula = formulae[plugin]
            return ExtensionIndex.matches(query, in: [plugin.id, plugin.detail, formula?.desc ?? "",
                                                       formula == nil ? "" : "Homebrew", formula?.license ?? ""])
        }.sorted { $0.id < $1.id }
    }

    func refresh(ifOlderThan age: TimeInterval = 0) async {
        if let lastRefresh, Date().timeIntervalSince(lastRefresh) < age { return }
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        do {
            let releases = try await ExtensionIndex.fetch(session: session)
            try Task.checkCancellation()
            formulae = releases
            lastRefresh = Date()
            catalogNote = nil
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            try JSONEncoder().encode(Array(releases.values)).write(to: cache.appendingPathComponent("index.json"), options: .atomic)
        } catch {
            if !Task.isCancelled { catalogNote = "Showing the local catalog. " + error.localizedDescription }
        }
    }

    func install(_ plugin: ShellPlugin) async {
        guard !changingInstallation else { return }
        let destination = pluginsDirectory.appendingPathComponent(plugin.id)
        let updating = plugin.installedScript(in: pluginsDirectory) != nil
        installing = plugin.id
        failure = nil
        defer { installing = nil }
        do {
            if plugin == .corrections {
                try await Task.detached { try plugin.installPayRespects(to: destination) }.value
            } else if let release = formulae[plugin] {
                try await release.install(plugin, to: destination, session: session)
            } else {
                throw ExtensionError("Refresh the Homebrew catalog to install this extension.")
            }
            if !updating { defaults.set(true, forKey: "plugin." + plugin.id) }
            installed.insert(plugin)
        } catch { failure = plugin.id + ": " + error.localizedDescription }
    }

    func uninstall(_ plugin: ShellPlugin) async {
        guard !changingInstallation, installed.contains(plugin),
              ShellPlugin.validName(plugin.id) || plugin == .corrections else { return }
        removing = plugin
        failure = nil
        defer { removing = nil }
        let directory = pluginsDirectory
        do {
            let cleanupNote: String? = try await Task.detached {
                let fm = FileManager.default
                let folder = directory.appendingPathComponent(plugin.id)
                let staging = directory.appendingPathComponent(".removing-" + UUID().uuidString)
                // New shells stop discovering the extension as soon as the rename succeeds.
                do { try fm.moveItem(at: folder, to: staging) }
                catch let error as CocoaError where [.fileNoSuchFile, .fileReadNoSuchFile].contains(error.code) { return nil }
                do { try fm.removeItem(at: staging); return nil }
                catch { return "Removed " + plugin.id + ". Couldn’t delete the remaining files in " + staging.path + "." }
            }.value
            defaults.removeObject(forKey: "plugin." + plugin.id)
            installed.remove(plugin)
            failure = cleanupNote
        } catch { failure = plugin.id + ": " + error.localizedDescription }
    }
}
