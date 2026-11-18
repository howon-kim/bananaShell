// Compile with Sources/ExtensionCatalog.swift and the BananaZstd C object.
import CryptoKit
import Foundation

enum PromptSetup {
    static let folder: URL? = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/PromptSupport")
}

private final class FormulaServer: URLProtocol {
    // Fixtures are configured before the requests start and stay fixed until refresh completes.
    static var responses: [URL: Data] = [:]
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        let data = Self.responses[url]
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: data == nil ? 503 : 200,
            httpVersion: "HTTP/1.1", headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        if let data { client?.urlProtocol(self, didLoad: data) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main
struct ExtensionCatalogChecks {
    @MainActor static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("extension-checks-" + UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let cache = root.appendingPathComponent("cache")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FormulaServer.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let plugins = root.appendingPathComponent("plugins")
        let suite = "extension-checks-" + UUID().uuidString
        let prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        let catalog = PluginCatalog(bundledFolder: PromptSetup.folder, cache: cache, session: session,
                                    pluginsDirectory: plugins, defaults: prefs)
        let plugin = ShellPlugin(id: "zsh-remote-test")
        precondition(catalog.results(matching: "remote-test").isEmpty)
        precondition(catalog.results(matching: "alias").contains(ShellPlugin(id: "zsh-you-should-use")))
        let pinned = catalog.formulae[.highlighting]!
        let package = root.appendingPathComponent("build/release")
        try fm.createDirectory(at: package, withIntermediateDirectories: true)
        let script = package.appendingPathComponent("test.plugin.zsh")
        try "typeset -ga CHECK_ORDER\nCHECK_ORDER+=(downloaded)\n".write(to: script, atomically: true, encoding: .utf8)
        let archive = root.appendingPathComponent("release.tar.gz")
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-czf", archive.path, "-C", package.deletingLastPathComponent().path, "release"]
        try tar.run()
        tar.waitUntilExit()
        precondition(tar.terminationStatus == 0)
        let bytes = try Data(contentsOf: archive)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let url = URL(string: "https://github.com/example/remote-test/archive/refs/tags/9.9.9.tar.gz")!
        var release = HomebrewFormula(name: plugin.id, license: "MIT", versions: .init(stable: "9.9.9"),
                                      urls: .init(stable: .init(url: url, checksum: digest)))
        release.homepage = URL(string: "https://github.com/example/remote-test")
        release.desc = "Browse bookmarked directories"
        release.dependencies = []
        release.caveats = "  source $HOMEBREW_PREFIX/share/zsh-remote-test/test.plugin.zsh"
        let encoded = try JSONEncoder().encode(release)
        // Include a future extension unknown to the app, an unrelated formula and an invalid zsh row.
        let index = Data("[{\"name\":\"git\"},{\"name\":\"zsh-corrupt\"},".utf8) + encoded + Data("]".utf8)
        FormulaServer.responses = [ExtensionIndex.url: index, url: bytes]
        await catalog.refresh()
        precondition(catalog.results(matching: " REMOTE-test ") == [plugin])
        precondition(catalog.results(matching: "bookmarked BROWSE") == [plugin])
        precondition(catalog.results(matching: "browse", installedOnly: true).isEmpty)
        let restarted = PluginCatalog(bundledFolder: PromptSetup.folder, cache: cache, session: session,
                                      pluginsDirectory: plugins, defaults: prefs)
        precondition(restarted.results(matching: "bookmarked") == [plugin])
        FormulaServer.responses[ExtensionIndex.url] = Data("{}".utf8)
        await restarted.refresh()
        precondition(restarted.formulae[plugin] == release && restarted.catalogNote != nil)
        var wrongOrigin = release
        wrongOrigin.homepage = URL(string: "https://example.com/not-the-upstream")
        precondition((try? wrongOrigin.validated(for: plugin)) == nil)
        precondition((try? HomebrewFormula.decode(encoded, for: .suggestions)) == nil)
        var badSource = release
        badSource.caveats = "source $HOMEBREW_PREFIX/share/zsh-remote-test/../other.zsh"
        precondition((try? badSource.validated(for: plugin)) == nil)

        // Remote-only previews read usage notes from the selected release before installation.
        let readmeURL = URL(string: "https://api.github.com/repos/example/remote-test/readme?ref=9.9.9")!
        FormulaServer.responses[readmeURL] = Data("# Test plugin\n## Usage\nChoose a saved directory.\n## Install\nNot part of the preview.".utf8)
        let usage = await release.usageExcerpt(session: session)
        precondition(usage == "Choose a saved directory." && catalog.installed.isEmpty)
        FormulaServer.responses.removeValue(forKey: readmeURL)
        let offlineUsage = await release.usageExcerpt(session: session)
        precondition(offlineUsage == nil)

        let destination = plugins.appendingPathComponent(plugin.id)
        await catalog.install(catalog.results(matching: "bookmarked")[0])
        precondition(catalog.failure == nil && catalog.results(matching: "browse", installedOnly: true) == [plugin])
        precondition(release.isInstalled(in: destination) && prefs.bool(forKey: "plugin." + plugin.id))
        let sentinel = destination.appendingPathComponent("previous-install")
        try Data().write(to: sentinel)
        do {
            try pinned.installArchive(archive, for: plugin, to: destination)
            fatalError("Accepted a mismatched archive")
        } catch {}
        precondition(fm.fileExists(atPath: sentinel.path))
        prefs.set(false, forKey: "plugin." + plugin.id)
        await catalog.install(plugin)
        precondition(!prefs.bool(forKey: "plugin." + plugin.id))
        precondition(ShellPluginStartup.environment(in: plugins, defaults: prefs).isEmpty)
        prefs.set(true, forKey: "plugin." + plugin.id)
        precondition(!fm.fileExists(atPath: sentinel.path))
        precondition(release.isInstalled(in: destination))

        // Source the app's real zsh startup file with an isolated user rc and the installed script.
        try "typeset -ga CHECK_ORDER=(user)".write(to: root.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        let suggestion = root.appendingPathComponent("suggestions.zsh")
        try "CHECK_ORDER+=(suggest)".write(to: suggestion, atomically: true, encoding: .utf8)
        let highlighter = root.appendingPathComponent("highlight.zsh")
        try "CHECK_ORDER+=(highlight)".write(to: highlighter, atomically: true, encoding: .utf8)
        let zsh = Process()
        zsh.executableURL = URL(fileURLWithPath: "/bin/zsh")
        zsh.arguments = ["-dfi", "-c", #"source "$BANANA_STARTUP_DIR/.zshrc"; [[ ${(j:,:)CHECK_ORDER} == user,suggest,downloaded,highlight && -z ${BANANA_SYNTAX_HIGHLIGHTING+x} ]]"#]
        var env = ["HOME": root.path, "_banana_user_dotdir": root.path, "BANANA_STARTUP_DIR": PromptSetup.folder!.path,
                   "BANANA_AUTOSUGGESTIONS": suggestion.path, "BANANA_SYNTAX_HIGHLIGHTING": highlighter.path]
        for entry in ShellPluginStartup.environment(in: plugins, defaults: prefs) {
            let pair = entry.split(separator: "=", maxSplits: 1)
            env[String(pair[0])] = String(pair[1])
        }
        zsh.environment = env
        try zsh.run()
        zsh.waitUntilExit()
        precondition(zsh.terminationStatus == 0)
        await catalog.uninstall(plugin)
        precondition(catalog.failure == nil && !fm.fileExists(atPath: destination.path))
        precondition(prefs.object(forKey: "plugin." + plugin.id) == nil)
        precondition(catalog.results(matching: "browse", installedOnly: true).isEmpty)
        precondition(catalog.results(matching: "browse") == [plugin])
        precondition(ShellPluginStartup.environment(in: plugins, defaults: prefs).isEmpty)
        let afterRemoval = PluginCatalog(bundledFolder: PromptSetup.folder, cache: cache, session: session,
                                        pluginsDirectory: plugins, defaults: prefs)
        precondition(!afterRemoval.installed.contains(plugin))
        await afterRemoval.install(plugin)
        precondition(afterRemoval.installed.contains(plugin) && prefs.bool(forKey: "plugin." + plugin.id))

        // Also remove a previously installed, disabled legacy plugin. Only its app-owned link is removed.
        let original = root.appendingPathComponent("external-suggestions")
        try fm.createDirectory(at: original, withIntermediateDirectories: false)
        let originalScript = original.appendingPathComponent(ShellPlugin.suggestions.entryName)
        try Data().write(to: originalScript)
        let legacyLink = plugins.appendingPathComponent(ShellPlugin.suggestions.id)
        try fm.createSymbolicLink(at: legacyLink, withDestinationURL: original)
        let legacy = PluginCatalog(bundledFolder: PromptSetup.folder, cache: cache, session: session,
                                   pluginsDirectory: plugins, defaults: prefs)
        precondition(legacy.installed.contains(.suggestions))
        await legacy.uninstall(.suggestions)
        precondition(legacy.failure == nil && !legacy.installed.contains(.suggestions))
        precondition(fm.fileExists(atPath: originalScript.path) && !fm.fileExists(atPath: legacyLink.path))
        precondition(legacy.installed.contains(plugin) && fm.fileExists(atPath: destination.path))
        print("Passed remote discovery, README previews, installation, zsh startup, removal and reinstallation checks.")
    }
}
