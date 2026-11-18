// Link with the SwiftTerm.o and SwiftTerm module produced by the Xcode build:
// swiftc -parse-as-library -I <Products/Debug> <Products/Debug>/SwiftTerm.o Sources/ThemeMarketplace.swift \
//   Tests/ThemeMarketplaceChecks.swift -o /tmp/banana-theme-checks && /tmp/banana-theme-checks
// Stubs below replace the app's prompt setup; themes install into a throwaway profile folder.
import AppKit
import SwiftTerm

let shellSurface = NSColor(white: 0.08, alpha: 1)
enum PersistentTerminal { static let profileSuffix = "-theme-checks-\(getpid())" }
enum PromptEngine: String { case starship, posh = "oh-my-posh" }
struct PromptEngineTools { func executable(_ name: String, preferred: String? = nil) -> URL? { nil } }
enum PromptSetup {
    static let folder: URL? = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Sources/PromptSupport")
    static func promptSignature() -> String {
        let prefs = UserDefaults.standard
        return [prefs.string(forKey: "themeLibrary") ?? "", prefs.string(forKey: "promptDesign") ?? ""].joined(separator: "|")
    }
}

private var failures = 0
private func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if condition() { print("ok   " + message) } else { failures += 1; print("FAIL " + message) }
}

@main
struct ThemeMarketplaceChecks {
    @MainActor static func main() async {
        let prefs = UserDefaults.standard
        let keys = [ThemeKey.scheme, ThemeKey.active, ThemeKey.accent, ThemeKey.accentSignature, ThemeKey.font,
                    "powerline", "themeLibrary", "themeFile.Oh My Posh", "themeFile.Starship", "promptDesign",
                    "customAccent", "promptIdentity"]
        keys.forEach(prefs.removeObject(forKey:))
        defer {
            keys.forEach(prefs.removeObject(forKey:))
            try? FileManager.default.removeItem(at: ThemeStore.directory)
        }
        // Start offline with a cached Gogh feed containing a duplicate and one extra palette.
        var goghPalette = ["name": "Gogh Test", "foreground": "#eeeeee", "background": "#111111"]
        for index in 1...16 { goghPalette[String(format: "color_%02d", index)] = "#123456" }
        var duplicate = goghPalette
        duplicate["name"] = "0x96f"
        let cache = ThemeStore.directory.appendingPathComponent("Cache")
        do {
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            try JSONEncoder().encode([goghPalette, duplicate, ["name": "Invalid"]])
                .write(to: cache.appendingPathComponent("gogh.json"))
        } catch { print("FAIL setting up cached Gogh feed: \(error)"); exit(1) }
        let store = ThemeStore.shared
        let gogh = store.catalog.filter { $0.tags?.contains("Gogh") == true }
        check(gogh.map(\.id) == ["gogh-gogh-test"], "cached Gogh feed merges unique valid palettes")
        if let entry = gogh.first {
            let theme = try? await store.bundle(for: entry)
            check(theme?.scheme?.ansi.count == 16 && theme == store.localBundle(for: entry),
                  "Gogh palette opens from cache without a theme download")
        }
        var changes = 0
        store.changed = { changes += 1 }

        // Catalog
        check(store.catalog.count > 250, "bundled catalog loads (\(store.catalog.count) entries)")
        check(Set(store.catalog.map(\.id)).count == store.catalog.count, "catalog IDs are unique")
        let schemeEntry = store.catalog.first { !$0.isBundle }!
        let bundleEntry = store.catalog.first { $0.id == "catppuccin-mocha-posh" }!
        let builtinEntry = store.catalog.first { $0.id == "rose-pine-ribbon" }!
        guard let scheme = try? await store.bundle(for: schemeEntry),
              let posh = try? await store.bundle(for: bundleEntry),
              let builtin = try? await store.bundle(for: builtinEntry) else {
            print("FAIL catalog themes load offline"); exit(1)
        }
        check(scheme.scheme?.isValid == true, "scheme entry loads and verifies its checksum")
        var tampered = schemeEntry
        tampered.sha256 = String(repeating: "0", count: 64)
        prefs.set("https://127.0.0.1:9/", forKey: ThemeKey.catalog)
        let tamperedResult = try? await store.bundle(for: tampered)
        check(tamperedResult == nil, "a checksum mismatch is rejected")
        prefs.removeObject(forKey: ThemeKey.catalog)

        // Validation
        var broken = scheme
        broken.scheme?.ansi.removeLast()
        check((try? ThemeStore.validated(broken)) == nil, "incomplete colors are rejected")
        var traversal = posh
        traversal.prompt?.file = "../../evil.json"
        check((try? ThemeStore.validated(traversal)) == nil, "prompt file paths outside the bundle are rejected")
        var unknown = builtin
        unknown.prompt?.engine = "fish"
        check((try? ThemeStore.validated(unknown)) == nil, "unknown prompt engines are rejected")
        var custom = posh
        custom.prompt = ThemePrompt(engine: "starship", name: "mine.toml", content: "[custom.git]\ncommand = \"curl evil\"\n")
        check(!ThemeStore.warnings(for: custom).isEmpty, "prompts that run commands are flagged")
        check(ThemeStore.warnings(for: posh).isEmpty, "bundled prompts carry no warning")

        // Other terminals' formats
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("theme-checks-\(getpid())")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let palette = ["#000000", "#AA0000", "#00AA00", "#AAAA00", "#0000AA", "#AA00AA", "#00AAAA", "#AAAAAA",
                       "#555555", "#FF5555", "#55FF55", "#FFFF55", "#5555FF", "#FF55FF", "#55FFFF", "#FFFFFF"]
        func write(_ name: String, _ text: String) -> URL {
            let url = folder.appendingPathComponent(name)
            try? text.write(to: url, atomically: true, encoding: .utf8)
            return url
        }
        let ghostty = write("Ghost", palette.enumerated().map { "palette = \($0.offset)=\($0.element)" }.joined(separator: "\n")
                            + "\nbackground = 101010\nforeground = eeeeee\ncursor-color = ff0000\n")
        let kitty = write("kitty.conf", palette.enumerated().map { "color\($0.offset) \($0.element)" }.joined(separator: "\n")
                          + "\nbackground #101010\nforeground #EEEEEE\n")
        let names = ["black", "red", "green", "yellow", "blue", "magenta", "cyan", "white"]
        let alacritty = write("ala.toml", "[colors.primary]\nbackground = '#101010'\nforeground = '#eeeeee'\n[colors.normal]\n"
            + names.enumerated().map { "\($0.element) = '\(palette[$0.offset])'" }.joined(separator: "\n")
            + "\n[colors.bright]\n" + names.enumerated().map { "\($0.element) = '\(palette[$0.offset + 8])'" }.joined(separator: "\n") + "\n")
        let wtKeys = ["black", "red", "green", "yellow", "blue", "purple", "cyan", "white"]
        var wt: [String: String] = ["name": "WT", "background": "#101010", "foreground": "#EEEEEE"]
        for (i, key) in wtKeys.enumerated() {
            wt[key] = palette[i]
            wt["bright" + key.prefix(1).uppercased() + key.dropFirst()] = palette[i + 8]
        }
        let wtURL = folder.appendingPathComponent("wt.json")
        try? JSONSerialization.data(withJSONObject: wt).write(to: wtURL)
        var plist: [String: Any] = [:]
        func component(_ hex: String) -> [String: Any] {
            let c = HexColor(hex)!
            return ["Red Component": Double(c.red) / 255, "Green Component": Double(c.green) / 255, "Blue Component": Double(c.blue) / 255]
        }
        for (i, hex) in palette.enumerated() { plist["Ansi \(i) Color"] = component(hex) }
        plist["Background Color"] = component("#101010")
        plist["Foreground Color"] = component("#EEEEEE")
        let iterm = folder.appendingPathComponent("Theme.itermcolors")
        try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: iterm)
        for (label, url) in [("Ghostty", ghostty), ("kitty", kitty), ("Alacritty", alacritty), ("Windows Terminal", wtURL), ("iTerm2", iterm)] {
            let imported = try? ThemeStore.importTheme(from: url)
            check(imported?.scheme?.background == "#101010" && imported?.scheme?.ansi == palette, "imports \(label) colors")
        }
        let exported = folder.appendingPathComponent("round.bananatheme")
        try? ThemeStore.encoded(posh).write(to: exported)
        check((try? ThemeStore.importTheme(from: exported)) == posh, ".bananatheme files round-trip")
        check((try? ThemeStore.importTheme(from: write("junk.txt", "hello"))) == nil, "files without colors are rejected")

        // Install, apply, try and revert
        do { try store.install(scheme) } catch { check(false, "install: \(error)") }
        check(store.isInstalled(scheme.id), "install writes the theme")
        check(store.apply(scheme) == .applied, "a color scheme applies without an engine")
        check(prefs.string(forKey: ThemeKey.scheme) == scheme.id && store.scheme(for: nil) == scheme.scheme, "the theme's scheme becomes current")
        check(store.scheme(for: TerminalTheme.defaultScheme) == nil, "a group can opt out to default colors")
        check(changes > 0, "applying notifies the app")
        try? store.install(posh)
        check(store.apply(posh) == .needsEngine(.posh), "a prompt theme asks for its engine first")
        check(prefs.string(forKey: ThemeKey.scheme) == scheme.id && !prefs.bool(forKey: "powerline"), "nothing changes while the engine is missing")
        try? store.install(builtin)
        check(store.apply(builtin) == .applied && prefs.string(forKey: "promptDesign") == "Ribbon"
              && prefs.bool(forKey: "powerline"), "a built-in prompt theme sets the prompt")
        check(prefs.string(forKey: ThemeKey.accentSignature) == PromptSetup.promptSignature(), "the accent is tied to the prompt it came with")
        let accentBefore = prefs.string(forKey: ThemeKey.accent)
        store.apply(scheme)
        check(prefs.string(forKey: ThemeKey.scheme) == scheme.id && prefs.string(forKey: "promptDesign") == "Ribbon"
              && prefs.string(forKey: ThemeKey.accent) == accentBefore && prefs.string(forKey: ThemeKey.active) == builtin.id,
              "a color scheme alone keeps the prompt and accent")
        check(store.applyPrompt(ThemePrompt(engine: "builtin", design: "Minimal")) == .applied
              && prefs.string(forKey: "promptDesign") == "Minimal" && prefs.string(forKey: ThemeKey.scheme) == nil,
              "a prompt takes over the terminal colors")
        store.apply(scheme)
        check(store.applyPrompt(ThemePrompt(engine: "starship", file: "tokyo-night.toml")) == .needsEngine(.starship)
              && prefs.string(forKey: "themeLibrary") == "Built-in", "a prompt waits for its engine")
        check(store.tryPrompt(ThemePrompt(engine: "builtin", design: "Stacked"), name: "Stacked") == .applied
              && prefs.string(forKey: "promptDesign") == "Stacked" && store.trying == "Stacked", "trying a prompt applies it")
        store.revert()
        check(prefs.string(forKey: "promptDesign") == "Minimal" && store.trying == nil, "reverting a prompt trial restores the prompt")
        check(prefs.string(forKey: ThemeKey.scheme) == scheme.id, "reverting a prompt trial restores the colors")
        store.apply(builtin)

        let before = Dictionary(uniqueKeysWithValues: keys.compactMap { key in prefs.object(forKey: key).map { (key, "\($0)") } })
        let trial = try! await store.bundle(for: store.catalog.first { !$0.isBundle && $0.id != scheme.id }!)
        try? store.tryOn(trial)
        check(store.trying == trial.name && prefs.string(forKey: ThemeKey.scheme) == trial.id, "trying applies the theme")
        store.revert()
        let after = Dictionary(uniqueKeysWithValues: keys.compactMap { key in prefs.object(forKey: key).map { (key, "\($0)") } })
        check(after == before && !store.isInstalled(trial.id) && store.trying == nil, "revert restores settings and removes the trial theme")

        let shared = store.exportCurrent(named: "My Setup")
        check(shared.id == "my-setup" && shared.scheme == builtin.scheme && shared.prompt?.design == "Ribbon", "export captures the current setup")

        store.uninstall(builtin.id)
        check(!store.isInstalled(builtin.id) && prefs.string(forKey: ThemeKey.active) == nil, "removing the theme in use resets it")

        // Terminal colors
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        TerminalTheme.apply(scheme.scheme, to: view, defaultBackground: shellSurface)
        check(HexColor(view.nativeBackgroundColor)?.hex == scheme.scheme?.background, "a scheme colors the terminal")
        TerminalTheme.apply(nil, to: view, defaultBackground: shellSurface)
        check(view.nativeBackgroundColor == shellSurface, "default colors come back")

        print(failures == 0 ? "All theme checks passed." : "\(failures) theme check(s) failed.")
        // exit() skips defers; clean up first.
        keys.forEach(prefs.removeObject(forKey:))
        try? FileManager.default.removeItem(at: ThemeStore.directory)
        try? FileManager.default.removeItem(at: folder)
        exit(failures == 0 ? 0 : 1)
    }
}
