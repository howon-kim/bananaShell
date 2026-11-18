import AppKit
import CryptoKit
import SwiftTerm
import SwiftUI

// MARK: - Theme format
//
// A theme (`.bananatheme`, JSON) bundles any of: a terminal color scheme, a
// prompt, an interface accent and a font. A plain color scheme is a theme with
// only `scheme`. The catalog in PromptSupport/Catalog ships with the app and is
// refreshed from the repository, so the gallery works offline.

struct ThemeScheme: Codable, Hashable {
    var name: String
    var background: String
    var foreground: String
    var cursor: String?
    var selection: String?
    /// The 16 ANSI colors: black, red, green, yellow, blue, magenta, cyan, white, then the bright set.
    var ansi: [String]

    /// bananaShell's own colors, for previews of themes without a scheme.
    static let standard = ThemeScheme(
        name: "bananaShell", background: "#13151A", foreground: "#EDEDED", cursor: nil, selection: nil,
        ansi: ["#000000", "#CD3131", "#0DBC79", "#E5E510", "#2472C8", "#BC3FBC", "#11A8CD", "#E5E5E5",
               "#666666", "#F14C4C", "#23D18B", "#F5F543", "#3B8EEA", "#D670D6", "#29B8DB", "#FFFFFF"])

    var isValid: Bool {
        ansi.count == 16 && ([background, foreground] + ansi).allSatisfy { HexColor($0) != nil }
            && [cursor, selection].allSatisfy { $0 == nil || HexColor($0!) != nil }
    }
    var backgroundColor: NSColor { HexColor(background)?.nsColor ?? shellSurface }
    var foregroundColor: NSColor { HexColor(foreground)?.nsColor ?? .white }
    var isLight: Bool { (HexColor(background)?.luminance ?? 0) > 0.5 }
    func ansiColor(_ index: Int) -> SwiftUI.Color { HexColor(ansi[index])?.color ?? .primary }
}

struct ThemePrompt: Codable, Hashable {
    /// "builtin", "oh-my-posh" or "starship".
    var engine: String
    /// A prompt file that ships with bananaShell (Oh My Posh / Starship).
    var file: String?
    /// Built-in prompt options.
    var design: String?
    var accent: String?
    var identity: Bool?
    /// A prompt file carried inside the theme: its file name and contents.
    var name: String?
    var content: String?

    var library: String? {
        switch engine {
        case "builtin": return "Built-in"
        case PromptEngine.posh.rawValue: return "Oh My Posh"
        case PromptEngine.starship.rawValue: return "Starship"
        default: return nil
        }
    }
    var title: String {
        switch engine {
        case "builtin": return "Built-in " + (design ?? "Classic")
        case PromptEngine.posh.rawValue: return "Oh My Posh"
        case PromptEngine.starship.rawValue: return "Starship"
        default: return engine
        }
    }
}

struct ThemeFont: Codable, Hashable {
    /// PostScript name; ignored when the font is not installed.
    var name: String
}

struct ThemeBundle: Codable, Identifiable, Hashable {
    var format = 1
    var id: String
    var name: String
    var author: String?
    var summary: String?
    var license: String?
    var source: String?
    var tags: [String]?
    var appearance: String?
    var scheme: ThemeScheme?
    var prompt: ThemePrompt?
    var accent: String?
    var font: ThemeFont?

    var isLight: Bool { appearance == "light" || (appearance == nil && scheme?.isLight == true) }
    var kindTitle: String { prompt == nil ? "Color scheme" : "Theme" }
}

struct CatalogEntry: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var kind: String
    var author: String?
    var license: String?
    var source: String?
    var tags: [String]?
    var appearance: String?
    var preview: ThemeScheme?
    var prompt: String?
    var accent: String?
    var summary: String?
    var likes: Int?
    var file: String
    var sha256: String

    var isBundle: Bool { kind == "bundle" }
    var isLight: Bool { appearance == "light" }
}

private struct CatalogIndex: Codable {
    var format: Int
    var themes: [CatalogEntry]
}

struct HexColor {
    let red: Int, green: Int, blue: Int
    init?(_ text: String) {
        var digits = text.trimmingCharacters(in: .whitespaces)
        if digits.hasPrefix("#") { digits.removeFirst() } else if digits.lowercased().hasPrefix("0x") { digits.removeFirst(2) }
        guard digits.utf8.count == 6, digits.allSatisfy(\.isHexDigit), let value = Int(digits, radix: 16) else { return nil }
        red = value >> 16; green = value >> 8 & 255; blue = value & 255
    }
    init(red: Int, green: Int, blue: Int) {
        self.red = max(0, min(255, red)); self.green = max(0, min(255, green)); self.blue = max(0, min(255, blue))
    }
    init?(_ color: NSColor) {
        guard let c = color.usingColorSpace(.sRGB) else { return nil }
        self.init(red: Int((c.redComponent * 255).rounded()), green: Int((c.greenComponent * 255).rounded()),
                  blue: Int((c.blueComponent * 255).rounded()))
    }
    var hex: String { String(format: "#%02X%02X%02X", red, green, blue) }
    var nsColor: NSColor { NSColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1) }
    var color: SwiftUI.Color { SwiftUI.Color(nsColor) }
    var terminalColor: SwiftTerm.Color { SwiftTerm.Color(red8: UInt16(red), green8: UInt16(green), blue8: UInt16(blue)) }
    var luminance: Double { (0.2126 * Double(red) + 0.7152 * Double(green) + 0.0722 * Double(blue)) / 255 }
}

// MARK: - Applying colors to terminals

enum TerminalTheme {
    /// Group setting meaning "the default colors", as opposed to nil ("follow the theme").
    static let defaultScheme = "default"

    /// Applies a scheme, or bananaShell's default colors when nil.
    @MainActor static func apply(_ scheme: ThemeScheme?, to view: TerminalView, defaultBackground: NSColor) {
        guard let scheme, scheme.isValid else {
            view.installColors(SwiftTerm.Color.defaultInstalledColors)
            if view.nativeBackgroundColor != defaultBackground { view.nativeBackgroundColor = defaultBackground }
            view.nativeForegroundColor = NSColor(white: 0.93, alpha: 1)
            view.caretColor = .selectedControlColor
            view.selectedTextBackgroundColor = .selectedTextBackgroundColor
            return
        }
        view.installColors(scheme.ansi.compactMap { HexColor($0)?.terminalColor })
        view.nativeBackgroundColor = scheme.backgroundColor
        view.nativeForegroundColor = scheme.foregroundColor
        view.caretColor = scheme.cursor.flatMap { HexColor($0)?.nsColor } ?? scheme.foregroundColor
        view.selectedTextBackgroundColor = (scheme.selection.flatMap { HexColor($0)?.nsColor } ?? scheme.foregroundColor)
            .withAlphaComponent(0.35)
    }
}

/// Prompt files that came inside themes, by library ("Oh My Posh", "Starship").
enum UserPromptFiles {
    static func folder(_ library: String) -> URL {
        ThemeStore.directory.appendingPathComponent("Prompts").appendingPathComponent(library)
    }
    static func files(_ library: String) -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder(library), includingPropertiesForKeys: nil)) ?? []
        return urls.filter { ["json", "yaml", "toml"].contains($0.pathExtension) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
}

// MARK: - Store

/// UserDefaults keys for the current theme.
enum ThemeKey {
    static let scheme = "terminalScheme", active = "activeTheme", accent = "themeAccent"
    static let accentSignature = "themeAccentSignature", font = "themeFont", catalog = "themeCatalogURL"
    static let automatic = "themeFollowsAppearance", light = "themeLight", dark = "themeDark"
}

@MainActor final class ThemeStore: ObservableObject {
    static let shared = ThemeStore()

    typealias Key = ThemeKey
    static let defaultCatalog = "https://raw.githubusercontent.com/howon-kim/bananaShell/main/Sources/PromptSupport/Catalog/"
    static let repository = "https://github.com/howon-kim/bananaShell"
    nonisolated static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/bananaShell/Themes" + PersistentTerminal.profileSuffix)
    }
    private static var installedFolder: URL { directory.appendingPathComponent("Installed") }
    private static var cacheFolder: URL { directory.appendingPathComponent("Cache") }

    @Published private(set) var catalog: [CatalogEntry] = []
    @Published private(set) var installed: [ThemeBundle] = []
    @Published private(set) var refreshing = false
    @Published private(set) var catalogNote: String?
    /// Snapshot of settings while a theme is being tried, and the theme's name.
    @Published private(set) var trying: String?
    /// A theme opened from a file or link, shown for review before installing.
    @Published var pending: ThemeBundle?
    private var trySnapshot: [String: Any]?

    /// Called after any change that terminals or the interface must pick up.
    var changed: () -> Void = {}

    private var primaryCatalog: [CatalogEntry] = []
    private var goghCatalog: [CatalogEntry] = []
    private var goghEntries: Set<CatalogEntry> = []
    private static let goghURL = URL(string: "https://raw.githubusercontent.com/Gogh-Co/Gogh/master/data/themes.json")!
    private static var goghCache: URL { cacheFolder.appendingPathComponent("gogh.json") }

    private init() {
        loadInstalled()
        primaryCatalog = Self.readIndex(at: Self.cacheFolder.appendingPathComponent("index.json")) ?? Self.bundledIndex ?? []
        if catalogBase?.absoluteString == Self.defaultCatalog,
           let data = try? Data(contentsOf: Self.goghCache) {
            goghCatalog = (try? Self.decodeGogh(data)) ?? []
        }
        mergeCatalogs()
        _ = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { ThemeStore.shared.followAppearance() }
        }
    }

    private var prefs: UserDefaults { .standard }
    var activeID: String? { prefs.string(forKey: Key.active) }

    // MARK: Catalog

    private static var bundledCatalog: URL? { PromptSetup.folder?.appendingPathComponent("Catalog") }
    private static var bundledIndex: [CatalogEntry]? {
        bundledCatalog.flatMap { readIndex(at: $0.appendingPathComponent("index.json")) }
    }
    private static func readIndex(at url: URL) -> [CatalogEntry]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return decodeIndex(data)
    }
    private static func decodeIndex(_ data: Data) -> [CatalogEntry]? {
        guard let index = try? JSONDecoder().decode(CatalogIndex.self, from: data), index.format == 1 else { return nil }
        return index.themes.filter { !$0.file.contains("..") && !$0.file.hasPrefix("/") }
    }
    private var catalogBase: URL? {
        let text = prefs.string(forKey: Key.catalog) ?? Self.defaultCatalog
        guard let url = URL(string: text.hasSuffix("/") ? text : text + "/"), url.scheme == "https" else { return nil }
        return url
    }

    static func decodeGogh(_ data: Data) throws -> [CatalogEntry] {
        let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []
        var entries: [CatalogEntry] = []
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        for row in rows {
            guard let name = row["name"] as? String, !slug(name).isEmpty,
                  let background = row["background"] as? String, let foreground = row["foreground"] as? String else { continue }
            let scheme = ThemeScheme(name: name, background: background, foreground: foreground,
                                     cursor: row["cursor"] as? String, ansi: (1...16).compactMap {
                                         row[String(format: "color_%02d", $0)] as? String
                                     })
            guard scheme.isValid else { continue }
            let id = "gogh-" + slug(name)
            let appearance = scheme.isLight ? "light" : "dark"
            entries.append(CatalogEntry(id: id, name: name, kind: "scheme", author: row["author"] as? String,
                                        source: "https://github.com/Gogh-Co/Gogh", tags: [appearance, "Gogh"],
                                        appearance: appearance, preview: scheme, file: "gogh/" + id,
                                        sha256: sha256(try encoder.encode(scheme))))
        }
        guard !entries.isEmpty else { throw failure("The Gogh catalog contains no usable palettes.") }
        return entries
    }

    private func mergeCatalogs() {
        var ids = Set(primaryCatalog.map(\.id))
        var names = Set(primaryCatalog.filter { !$0.isBundle }.map { Self.slug($0.name) })
        let additions = goghCatalog.filter {
            ids.insert($0.id).inserted && names.insert(Self.slug($0.name)).inserted
        }
        goghEntries = Set(additions)
        catalog = primaryCatalog + additions
    }

    private var lastRefresh: Date?

    /// Downloads the latest catalog index; the bundled or cached one stays on failure.
    func refresh(ifOlderThan age: TimeInterval = 0) async {
        if let lastRefresh, Date().timeIntervalSince(lastRefresh) < age { return }
        guard !refreshing, let base = catalogBase else { return }
        refreshing = true
        defer { refreshing = false }
        var primaryRefreshed = false
        do {
            let data = try await Self.download(base.appendingPathComponent("index.json"))
            guard let themes = Self.decodeIndex(data) else { throw Self.failure("The catalog could not be read.") }
            try FileManager.default.createDirectory(at: Self.cacheFolder, withIntermediateDirectories: true)
            try data.write(to: Self.cacheFolder.appendingPathComponent("index.json"), options: .atomic)
            primaryCatalog = themes
            primaryRefreshed = true
            catalogNote = nil
        } catch let error as DownloadStatus where error.code == 404
                    && base.absoluteString == Self.defaultCatalog && !primaryCatalog.isEmpty {
            // The bundled catalog can ship before its index is published on main.
            catalogNote = age > 0 ? nil : "Using the local catalog. The online index returned HTTP 404."
        } catch {
            catalogNote = (primaryCatalog.isEmpty ? "" : "Showing the local catalog. ") + error.localizedDescription
        }
        if base.absoluteString == Self.defaultCatalog {
            do {
                let data = try await Self.download(Self.goghURL)
                let entries = try Self.decodeGogh(data)
                try FileManager.default.createDirectory(at: Self.cacheFolder, withIntermediateDirectories: true)
                try data.write(to: Self.goghCache, options: .atomic)
                goghCatalog = entries
            } catch {
                catalogNote = [catalogNote, "Gogh: " + error.localizedDescription].compactMap { $0 }.joined(separator: " ")
            }
        } else {
            goghCatalog = []
        }
        mergeCatalogs()
        if primaryRefreshed && catalogNote == nil { lastRefresh = Date() }
    }

    /// The theme file for a catalog entry, verified against the index checksum.
    func bundle(for entry: CatalogEntry) async throws -> ThemeBundle {
        if let local = localGoghBundle(for: entry) { return local }
        var data: Data?
        if let local = Self.bundledCatalog?.appendingPathComponent(entry.file),
           let bytes = try? Data(contentsOf: local), Self.sha256(bytes) == entry.sha256 { data = bytes }
        if data == nil, let base = catalogBase {
            let bytes = try await Self.download(base.appendingPathComponent(entry.file))
            guard Self.sha256(bytes) == entry.sha256 else { throw Self.failure("The downloaded theme does not match the catalog.") }
            data = bytes
        }
        guard let data else { throw Self.failure("The theme is not available offline.") }
        return try Self.decode(data)
    }

    private func localGoghBundle(for entry: CatalogEntry) -> ThemeBundle? {
        guard entry.file.hasPrefix("gogh/"), goghEntries.contains(entry) else { return nil }
        return ThemeBundle(id: entry.id, name: entry.name, author: entry.author, source: entry.source,
                           tags: entry.tags, appearance: entry.appearance, scheme: entry.preview)
    }

    /// A catalog theme from the copy bundled with the app, when it is there and unchanged.
    func localBundle(for entry: CatalogEntry) -> ThemeBundle? {
        if let local = localGoghBundle(for: entry) { return local }
        guard let url = Self.bundledCatalog?.appendingPathComponent(entry.file), let data = try? Data(contentsOf: url),
              Self.sha256(data) == entry.sha256 else { return nil }
        return try? Self.decode(data)
    }

    // MARK: Install

    func isInstalled(_ id: String) -> Bool { installed.contains { $0.id == id } }

    private func loadInstalled() {
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.installedFolder, includingPropertiesForKeys: nil)) ?? []
        installed = files.filter { $0.pathExtension == "bananatheme" }
            .compactMap { (try? Data(contentsOf: $0)).flatMap { try? Self.decode($0) } }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func install(_ bundle: ThemeBundle) throws {
        let theme = try Self.validated(bundle)
        let fm = FileManager.default
        try fm.createDirectory(at: Self.installedFolder, withIntermediateDirectories: true)
        if let prompt = theme.prompt, let content = prompt.content, let name = prompt.name, let library = prompt.library {
            let folder = UserPromptFiles.folder(library)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(content.utf8).write(to: folder.appendingPathComponent(Self.promptFileName(theme.id, name)), options: .atomic)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(theme).write(to: Self.installedFolder.appendingPathComponent(theme.id + ".bananatheme"), options: .atomic)
        loadInstalled()
    }

    func uninstall(_ id: String) {
        if activeID == id { resetToDefault() }
        if prefs.string(forKey: Key.scheme) == id { prefs.removeObject(forKey: Key.scheme) }
        if let theme = installed.first(where: { $0.id == id }), let prompt = theme.prompt, let name = prompt.name,
           let library = prompt.library {
            try? FileManager.default.removeItem(at: UserPromptFiles.folder(library).appendingPathComponent(Self.promptFileName(id, name)))
        }
        try? FileManager.default.removeItem(at: Self.installedFolder.appendingPathComponent(id + ".bananatheme"))
        loadInstalled()
        changed()
    }

    private static func promptFileName(_ id: String, _ name: String) -> String {
        id + "-" + URL(fileURLWithPath: name).lastPathComponent
    }

    // MARK: Apply

    enum Outcome: Equatable { case applied, needsEngine(PromptEngine) }

    /// Makes the theme current: scheme, prompt, accent and font. Asks for the
    /// prompt engine first if the theme needs one that is not installed.
    @discardableResult
    func apply(_ theme: ThemeBundle, skippingPrompt: Bool = false) -> Outcome {
        if !skippingPrompt, let prompt = theme.prompt, let engine = PromptEngine(rawValue: prompt.engine),
           PromptEngineTools().executable(engine.rawValue, preferred: prefs.string(forKey: "enginePath." + (prompt.library ?? ""))) == nil {
            return .needsEngine(engine)
        }
        // Colors and prompt are separate layers: a color scheme alone keeps the prompt, accent and font.
        if theme.scheme != nil { prefs.set(theme.id, forKey: Key.scheme) }
        guard theme.prompt != nil || theme.font != nil || theme.accent != nil else { changed(); return .applied }
        if !skippingPrompt, let prompt = theme.prompt { applyPrompt(prompt, theme: theme.id) }
        if let font = theme.font, NSFont(name: font.name, size: 12) != nil { prefs.set(font.name, forKey: Key.font) }
        else { prefs.removeObject(forKey: Key.font) }
        if let accent = theme.accent.flatMap(HexColor.init) {
            prefs.set(accent.hex, forKey: Key.accent)
            prefs.set(PromptSetup.promptSignature(), forKey: Key.accentSignature)
        } else {
            prefs.removeObject(forKey: Key.accent)
        }
        prefs.set(theme.id, forKey: Key.active)
        changed()
        return .applied
    }

    /// Applies a prompt that ships with bananaShell. Terminals then take the
    /// prompt's background instead of the current color scheme; groups keep their own colors.
    @discardableResult
    func applyPrompt(_ prompt: ThemePrompt) -> Outcome {
        if let engine = missingEngine(for: prompt) { return .needsEngine(engine) }
        applyPrompt(prompt, theme: "")
        releaseScheme()
        changed()
        return .applied
    }

    /// Shows a prompt in every terminal until `keep()` or `revert()`.
    func tryPrompt(_ prompt: ThemePrompt, name: String) -> Outcome {
        if let engine = missingEngine(for: prompt) { return .needsEngine(engine) }
        beginTrial()
        applyPrompt(prompt, theme: "")
        releaseScheme()
        trying = name
        changed()
        return .applied
    }

    private func missingEngine(for prompt: ThemePrompt) -> PromptEngine? {
        guard let engine = PromptEngine(rawValue: prompt.engine) else { return nil }
        let found = PromptEngineTools().executable(engine.rawValue, preferred: prefs.string(forKey: "enginePath." + (prompt.library ?? "")))
        return found == nil ? engine : nil
    }

    private func applyPrompt(_ prompt: ThemePrompt, theme: String) {
        switch prompt.engine {
        case "builtin":
            prefs.set("Built-in", forKey: "themeLibrary")
            if let design = prompt.design { prefs.set(design, forKey: "promptDesign") }
            if let accent = prompt.accent.flatMap(HexColor.init) { prefs.set(accent.hex, forKey: "customAccent") }
            if let identity = prompt.identity { prefs.set(identity, forKey: "promptIdentity") }
        default:
            guard let library = prompt.library else { return }
            let file = prompt.content != nil && prompt.name != nil
                ? Self.promptFileName(theme, prompt.name!) : prompt.file.map { URL(fileURLWithPath: $0).lastPathComponent }
            guard let file else { return }
            prefs.set(library, forKey: "themeLibrary")
            prefs.set(file, forKey: "themeFile." + library)
        }
        prefs.set(true, forKey: "powerline")
    }

    func resetToDefault() {
        for key in [Key.scheme, Key.active, Key.accent, Key.accentSignature, Key.font] { prefs.removeObject(forKey: key) }
        changed()
    }

    /// Name of the current color scheme, which colors terminals instead of the prompt's background.
    var currentSchemeName: String? {
        guard let id = prefs.string(forKey: Key.scheme) else { return nil }
        return installed.first { $0.id == id && $0.scheme != nil }?.name
    }

    /// Drops the current color scheme so terminals follow the prompt's colors.
    /// Groups with their own colors keep them.
    func releaseScheme() {
        prefs.removeObject(forKey: Key.scheme)
    }

    /// Terminal colors: a group's own choice, otherwise the current theme's scheme.
    func scheme(for groupChoice: String?) -> ThemeScheme? {
        let id = groupChoice ?? prefs.string(forKey: Key.scheme)
        guard let id, id != TerminalTheme.defaultScheme else { return nil }
        return installed.first { $0.id == id }?.scheme
    }

    // MARK: Trying

    private static let trialKeys = [Key.scheme, Key.active, Key.accent, Key.accentSignature, Key.font, "powerline", "themeLibrary",
                                    "themeFile.Oh My Posh", "themeFile.Starship", "promptDesign", "customAccent", "promptIdentity"]

    /// Shows a theme in every terminal until `keep()` or `revert()`. A catalog
    /// theme is installed for the trial and removed again on revert.
    private func beginTrial() {
        guard trySnapshot == nil else { return }
        var snapshot: [String: Any] = [:]
        for key in Self.trialKeys { if let value = prefs.object(forKey: key) { snapshot[key] = value } }
        snapshot["#installed"] = installed.map(\.id)
        trySnapshot = snapshot
    }

    func tryOn(_ theme: ThemeBundle) throws {
        beginTrial()
        if !isInstalled(theme.id) { try install(theme) }
        let engineReady = apply(theme) == .applied
        if !engineReady { apply(theme, skippingPrompt: true) }
        trying = theme.name
    }

    func keep() { trySnapshot = nil; trying = nil }

    func revert() {
        guard let snapshot = trySnapshot else { return }
        let keepInstalled = Set(snapshot["#installed"] as? [String] ?? [])
        for theme in installed where !keepInstalled.contains(theme.id) {
            try? FileManager.default.removeItem(at: Self.installedFolder.appendingPathComponent(theme.id + ".bananatheme"))
            if let prompt = theme.prompt, let name = prompt.name, let library = prompt.library {
                try? FileManager.default.removeItem(at: UserPromptFiles.folder(library).appendingPathComponent(Self.promptFileName(theme.id, name)))
            }
        }
        for key in Self.trialKeys {
            if let value = snapshot[key] { prefs.set(value, forKey: key) } else { prefs.removeObject(forKey: key) }
        }
        trySnapshot = nil
        trying = nil
        loadInstalled()
        changed()
    }

    // MARK: Light and dark

    func followAppearance() {
        guard prefs.bool(forKey: Key.automatic), trySnapshot == nil else { return }
        let dark = prefs.string(forKey: "AppleInterfaceStyle") == "Dark"
        guard let id = prefs.string(forKey: dark ? Key.dark : Key.light), id != activeID,
              let theme = installed.first(where: { $0.id == id }) else { return }
        apply(theme)
    }

    // MARK: Import and export

    /// The current setup as a shareable theme.
    func exportCurrent(named name: String) -> ThemeBundle {
        var theme = ThemeBundle(id: Self.slug(name), name: name)
        theme.author = NSFullUserName().isEmpty ? nil : NSFullUserName()
        theme.scheme = scheme(for: nil)
        theme.appearance = theme.scheme.map { $0.isLight ? "light" : "dark" }
        if prefs.bool(forKey: "powerline") {
            let library = prefs.string(forKey: "themeLibrary") ?? "Built-in"
            if library == "Built-in" {
                theme.prompt = ThemePrompt(engine: "builtin", design: prefs.string(forKey: "promptDesign") ?? "Classic",
                                           accent: prefs.string(forKey: "customAccent").flatMap(HexColor.init)?.hex,
                                           identity: prefs.object(forKey: "promptIdentity") as? Bool ?? true)
            } else if let file = prefs.string(forKey: "themeFile." + library) {
                let engine = library == "Starship" ? PromptEngine.starship.rawValue : PromptEngine.posh.rawValue
                let custom = UserPromptFiles.folder(library).appendingPathComponent(file)
                if let content = try? String(contentsOf: custom, encoding: .utf8) {
                    theme.prompt = ThemePrompt(engine: engine, name: file, content: content)
                } else {
                    theme.prompt = ThemePrompt(engine: engine, file: file)
                }
            }
        }
        if prefs.string(forKey: Key.accentSignature) == PromptSetup.promptSignature() { theme.accent = prefs.string(forKey: Key.accent) }
        theme.font = prefs.string(forKey: Key.font).map(ThemeFont.init)
        return theme
    }

    static func encoded(_ theme: ThemeBundle) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(theme)
    }

    /// Reads a `.bananatheme` or a color scheme exported by another terminal:
    /// iTerm2 (.itermcolors), Windows Terminal (JSON), Ghostty, kitty or Alacritty (TOML).
    static func importTheme(from url: URL) throws -> ThemeBundle {
        let data = try Data(contentsOf: url)
        guard data.count < 1_000_000 else { throw failure("The file is too large to be a theme.") }
        let base = url.deletingPathExtension().lastPathComponent
        if let theme = try? decode(data) { return try validated(theme) }
        let scheme: ThemeScheme?
        if url.pathExtension.lowercased() == "itermcolors" {
            scheme = SchemeParsers.iTerm(data, name: base)
        } else if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            scheme = SchemeParsers.windowsTerminal(json, name: base)
        } else {
            let text = String(decoding: data, as: UTF8.self)
            scheme = SchemeParsers.alacritty(text, name: base) ?? SchemeParsers.keyValue(text, name: base)
        }
        guard let scheme, scheme.isValid else { throw failure("No terminal colors were found in this file.") }
        return ThemeBundle(id: slug(scheme.name), name: scheme.name, summary: "Imported color scheme.",
                           tags: [scheme.isLight ? "light" : "dark"], appearance: scheme.isLight ? "light" : "dark", scheme: scheme)
    }

    /// Opens a theme shared as a link: an HTTPS file or a catalog ID.
    func resolve(link: URL) async throws -> ThemeBundle {
        let items = URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let id = items.first(where: { $0.name == "id" })?.value {
            if catalog.first(where: { $0.id == id }) == nil { await refresh() }
            guard let entry = catalog.first(where: { $0.id == id }) else { throw Self.failure("No theme named “\(id)” is in the catalog.") }
            return try await bundle(for: entry)
        }
        guard let text = items.first(where: { $0.name == "url" })?.value, let url = URL(string: text), url.scheme == "https" else {
            throw Self.failure("Theme links must point to an HTTPS file.")
        }
        return try Self.validated(try Self.decode(try await Self.download(url)))
    }

    /// Prompt settings that can run commands each time the prompt draws.
    static func warnings(for theme: ThemeBundle) -> [String] {
        guard let prompt = theme.prompt, let content = prompt.content else { return [] }
        var result: [String] = []
        let lower = content.lowercased()
        if prompt.engine == PromptEngine.starship.rawValue, lower.contains("[custom.") || lower.contains("command =") || lower.contains("command=") {
            result.append("Its Starship prompt runs custom shell commands every time the prompt appears.")
        }
        if prompt.engine == PromptEngine.posh.rawValue, lower.contains("\"command\"") {
            result.append("Its Oh My Posh prompt runs shell commands every time the prompt appears.")
        }
        return result
    }

    // MARK: Helpers

    static func decode(_ data: Data) throws -> ThemeBundle {
        try JSONDecoder().decode(ThemeBundle.self, from: data)
    }

    static func validated(_ input: ThemeBundle) throws -> ThemeBundle {
        var theme = input
        theme.id = slug(theme.id.isEmpty ? theme.name : theme.id)
        guard theme.format == 1, !theme.id.isEmpty, !theme.name.isEmpty else { throw failure("This theme file is not supported.") }
        if let scheme = theme.scheme, !scheme.isValid { throw failure("The theme’s colors are incomplete.") }
        if let prompt = theme.prompt {
            guard prompt.library != nil else { throw failure("The theme uses an unknown prompt engine.") }
            if prompt.engine == "builtin" {
                guard prompt.design.map({ ["Classic", "Minimal", "Stacked", "Ribbon"].contains($0) }) ?? true else {
                    throw failure("The theme uses an unknown prompt layout.")
                }
            } else if let content = prompt.content {
                guard let name = prompt.name, ["json", "yaml", "toml"].contains(URL(fileURLWithPath: name).pathExtension),
                      content.utf8.count < 200_000 else { throw failure("The theme’s prompt file is not supported.") }
            } else {
                // Only prompt files that ship with bananaShell may be referenced by name.
                guard let file = prompt.file, !file.contains("/"), let library = prompt.library,
                      FileManager.default.fileExists(atPath: PromptSetup.folder?.appendingPathComponent(library)
                        .appendingPathComponent(file).path ?? "") else {
                    throw failure("The theme’s prompt is not included with this version of bananaShell.")
                }
            }
        }
        if theme.scheme == nil && theme.prompt == nil { throw failure("The theme has no colors or prompt.") }
        if theme.appearance == nil { theme.appearance = theme.scheme.map { $0.isLight ? "light" : "dark" } }
        return theme
    }

    nonisolated static func slug(_ text: String) -> String {
        let lowered = text.lowercased().unicodeScalars.map { CharacterSet.alphanumerics.contains($0) && $0.isASCII ? Character($0) : "-" }
        return String(lowered).split(separator: "-").joined(separator: "-")
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private struct DownloadStatus: LocalizedError {
        let code: Int
        var errorDescription: String? { "The server returned HTTP \(code)." }
    }

    private static func download(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("bananaShell", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw failure("The server returned an invalid response.") }
        guard http.statusCode == 200 else { throw DownloadStatus(code: http.statusCode) }
        guard data.count < 5_000_000 else { throw failure("The download is too large.") }
        return data
    }

    static func failure(_ message: String) -> NSError {
        NSError(domain: "bananaShell.themes", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

// MARK: - Color scheme formats from other terminals

enum SchemeParsers {
    private static let names = ["black", "red", "green", "yellow", "blue", "magenta", "cyan", "white"]

    static func iTerm(_ data: Data, name: String) -> ThemeScheme? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        func color(_ key: String) -> String? {
            guard let entry = plist[key] as? [String: Any],
                  let r = entry["Red Component"] as? Double, let g = entry["Green Component"] as? Double,
                  let b = entry["Blue Component"] as? Double else { return nil }
            return HexColor(red: Int((r * 255).rounded()), green: Int((g * 255).rounded()), blue: Int((b * 255).rounded())).hex
        }
        let ansi = (0..<16).compactMap { color("Ansi \($0) Color") }
        guard ansi.count == 16, let bg = color("Background Color"), let fg = color("Foreground Color") else { return nil }
        return ThemeScheme(name: name, background: bg, foreground: fg, cursor: color("Cursor Color"),
                           selection: color("Selection Color"), ansi: ansi)
    }

    static func windowsTerminal(_ json: [String: Any], name: String) -> ThemeScheme? {
        let keys = ["black", "red", "green", "yellow", "blue", "purple", "cyan", "white"]
        let ansi = (keys + keys.map { "bright" + $0.prefix(1).uppercased() + $0.dropFirst() })
            .compactMap { (json[$0] as? String).flatMap(HexColor.init)?.hex }
        guard ansi.count == 16, let bg = (json["background"] as? String).flatMap(HexColor.init),
              let fg = (json["foreground"] as? String).flatMap(HexColor.init) else { return nil }
        return ThemeScheme(name: json["name"] as? String ?? name, background: bg.hex, foreground: fg.hex,
                           cursor: (json["cursorColor"] as? String).flatMap(HexColor.init)?.hex,
                           selection: (json["selectionBackground"] as? String).flatMap(HexColor.init)?.hex, ansi: ansi)
    }

    /// Ghostty (`palette = 0=#rrggbb`, `background = …`) and kitty (`color0 #rrggbb`).
    static func keyValue(_ text: String, name: String) -> ThemeScheme? {
        var ansi = [String?](repeating: nil, count: 16)
        var values: [String: String] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), !line.isEmpty else { continue }
            let parts: [String]
            if let eq = line.firstIndex(of: "=") {
                parts = [String(line[..<eq]), String(line[line.index(after: eq)...])].map { $0.trimmingCharacters(in: .whitespaces) }
            } else {
                parts = line.split(maxSplits: 1, whereSeparator: \.isWhitespace).map { $0.trimmingCharacters(in: .whitespaces) }
            }
            guard parts.count == 2 else { continue }
            let key = parts[0].lowercased(), value = parts[1]
            if key == "palette", let eq = value.firstIndex(of: "="), let index = Int(value[..<eq]), (0..<16).contains(index) {
                ansi[index] = HexColor(String(value[value.index(after: eq)...]))?.hex
            } else if key.hasPrefix("color"), let index = Int(key.dropFirst(5)), (0..<16).contains(index) {
                ansi[index] = HexColor(value)?.hex
            } else if let color = HexColor(value) {
                values[key] = color.hex
            }
        }
        let colors = ansi.compactMap { $0 }
        guard colors.count == 16, let bg = values["background"], let fg = values["foreground"] else { return nil }
        return ThemeScheme(name: name, background: bg, foreground: fg, cursor: values["cursor-color"] ?? values["cursor"],
                           selection: values["selection-background"] ?? values["selection_background"], ansi: colors)
    }

    /// Alacritty TOML: [colors.primary], [colors.normal], [colors.bright], [colors.cursor], [colors.selection].
    static func alacritty(_ text: String, name: String) -> ThemeScheme? {
        guard text.contains("[colors.") else { return nil }
        var section = "", values: [String: String] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { section = line.trimmingCharacters(in: CharacterSet(charactersIn: "[]")); continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: eq)...].trimmingCharacters(in: CharacterSet(charactersIn: " '\""))
            if let color = HexColor(value) { values[section + "." + key] = color.hex }
        }
        let ansi = names.compactMap { values["colors.normal." + $0] } + names.compactMap { values["colors.bright." + $0] }
        guard ansi.count == 16, let bg = values["colors.primary.background"], let fg = values["colors.primary.foreground"] else { return nil }
        return ThemeScheme(name: name, background: bg, foreground: fg, cursor: values["colors.cursor.cursor"],
                           selection: values["colors.selection.background"], ansi: ansi)
    }
}
