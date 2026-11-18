import AppKit
import SwiftUI

private enum Palette: String, CaseIterable {
    case violet = "\u{bc14}\u{c774}\u{c62c}\u{b81b}", mint = "\u{bbfc}\u{d2b8}", ocean = "\u{c624}\u{c158}"
    var code: Int { switch self { case .violet: return 99; case .mint: return 79; case .ocean: return 75 } }
    var color: Color { switch self { case .violet: return Color(red: 0.53, green: 0.37, blue: 1); case .mint: return .mint; case .ocean: return .cyan } }
}

enum ThemeLibrary: String, CaseIterable {
    case builtin = "Built-in", posh = "Oh My Posh", starship = "Starship"
    var engine: String { self == .posh ? "oh-my-posh" : "starship" }
    var dependency: PromptEngine? { self == .builtin ? nil : self == .posh ? .posh : .starship }
    var files: [URL] {
        switch self {
        case .builtin: return []
        // Prompts installed from themes follow the bundled ones.
        case .posh: return Self.poshFiles + UserPromptFiles.files(rawValue)
        case .starship: return Self.starshipFiles + UserPromptFiles.files(rawValue)
        }
    }
    // Bundled themes cannot change while the app is running. Each library is
    // scanned and sorted once, rather than once per card on every UI update.
    private static let poshFiles = loadFiles(in: .posh)
    private static let starshipFiles = loadFiles(in: .starship)
    private static func loadFiles(in library: ThemeLibrary) -> [URL] {
        guard let folder = PromptSetup.folder else { return [] }
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder.appendingPathComponent(library.rawValue), includingPropertiesForKeys: nil)) ?? []
        return urls.filter { ["json", "yaml", "toml"].contains($0.pathExtension) }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
    func title(_ url: URL) -> String { url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: ".omp", with: "") }
}

private struct RGB {
    let value: Int
    init?(_ input: String) {
        let digits = input.hasPrefix("#") ? String(input.dropFirst()) : input
        guard digits.utf8.count == 6, digits.allSatisfy({ $0.isHexDigit }), let n = Int(digits, radix: 16) else { return nil }
        value = n
    }
    var hex: String { String(format: "#%06X", value) }
    var color: Color { Color(.sRGB, red: Double(value >> 16) / 255, green: Double(value >> 8 & 255) / 255, blue: Double(value & 255) / 255) }
}

enum PromptDesign: String, CaseIterable {
    case classic = "Classic", minimal = "Minimal", stacked = "Stacked", ribbon = "Ribbon"

    func prompt(color: String, identity: Bool) -> String {
        let accent = "%F{\(color)}"
        switch self {
        case .classic:
            let prefix = identity ? "%K{0}%F{15} %n@%m %K{\(color)}%F{0}▶" : "%K{\(color)}"
            return prefix + "%F{0} %~ %k" + accent + "▶%f "
        case .ribbon:
            let shade = color == "99" ? "57" : color
            let prefix = identity ? "%K{0}%F{15} %n@%m %K{\(shade)}%F{0}\u{E0B0}" : "%K{\(shade)}"
            return prefix + "%F{0} %~ %k%F{\(shade)}\u{E0B0}%f "
        case .minimal:
            return (identity ? "%F{7}%n@%m · %f" : "") + accent + "%~ ❯%f "
        case .stacked:
            return accent + "╭─ %f" + (identity ? "%F{7}%n@%m %f" : "") + accent + "%~\n╰─❯%f "
        }
    }
}

enum PromptSetup {
    static let folder: URL? = {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        return bundle.url(forResource: "PromptSupport", withExtension: nil)
    }()

    /// Persistent shells outlive the build that created them. Give them a stable
    /// path that each launch repoints at the running bundle, so `claude` always
    /// uses the current launcher and hooks instead of an old or deleted build's.
    static let shellFolder: URL? = {
        guard let folder else { return nil }
        let fm = FileManager.default
        let parent = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/bananaShell")
        let link = parent.appendingPathComponent("PromptSupport" + PersistentTerminal.profileSuffix)
        if (try? fm.destinationOfSymbolicLink(atPath: link.path)) == folder.path { return link }
        let staging = parent.appendingPathComponent(".PromptSupport-" + UUID().uuidString)
        do {
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
            try fm.createSymbolicLink(atPath: staging.path, withDestinationPath: folder.path)
            // rename(2) swaps the link atomically for shells reading it concurrently.
            guard rename(staging.path, link.path) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            return link
        } catch {
            try? fm.removeItem(at: staging)
            return folder
        }
    }()

    private static let backgrounds: [String: String] = {
        guard let url = folder?.appendingPathComponent("theme-backgrounds.json"),
              let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }()

    static func background(file: URL?, follow: Bool, accent: NSColor) -> NSColor {
        guard follow else { return shellSurface }
        if let file, let hex = backgrounds[file.lastPathComponent], let rgb = RGB(hex) { return NSColor(rgb.color) }
        let color = accent.usingColorSpace(.sRGB) ?? .systemPurple
        return NSColor(calibratedHue: color.hueComponent, saturation: color.saturationComponent * 0.55,
                       brightness: 0.18, alpha: 1)
    }

    static func background(forShell shell: String) -> NSColor {
        let prefs = UserDefaults.standard
        guard URL(fileURLWithPath: shell).lastPathComponent == "zsh", prefs.bool(forKey: "powerline") else { return shellSurface }
        let library = ThemeLibrary(rawValue: prefs.string(forKey: "themeLibrary") ?? "") ?? .builtin
        let files = library.files
        let file = files.first { $0.lastPathComponent == prefs.string(forKey: "themeFile." + library.rawValue) } ?? files.first
        let palette = Palette(rawValue: prefs.string(forKey: "promptPalette") ?? "") ?? .violet
        let accent = RGB(prefs.string(forKey: "customAccent") ?? "")?.color ?? palette.color
        return background(file: file, follow: prefs.object(forKey: "followThemeBackground") as? Bool ?? true, accent: NSColor(accent))
    }

    /// Identifies the prompt choice, so a theme's interface accent applies only
    /// while the prompt is still the one the theme set.
    static func promptSignature() -> String {
        let prefs = UserDefaults.standard
        let library = prefs.string(forKey: "themeLibrary") ?? ThemeLibrary.builtin.rawValue
        let detail = library == ThemeLibrary.builtin.rawValue
            ? (prefs.string(forKey: "promptDesign") ?? "") + (prefs.string(forKey: "customAccent") ?? "")
            : prefs.string(forKey: "themeFile." + library) ?? ""
        return [String(prefs.bool(forKey: "powerline")), library, detail].joined(separator: "|")
    }

    /// ANSI preview of a built-in layout with the current accent and identity settings.
    static func builtInSample(_ layout: PromptDesign, compact: Bool = false) -> String {
        let prefs = UserDefaults.standard
        let palette = prefs.string(forKey: "promptPalette") ?? ""
        let customAccent = prefs.string(forKey: "customAccent") ?? ""
        let identity = prefs.object(forKey: "promptIdentity") as? Bool ?? true
        let reset = "\u{1b}[0m"
        let name = compact ? "mac" : "user@mac"
        let path = compact ? "~" : "~/work"
        let code = (Palette(rawValue: palette) ?? .violet).code
        let color = RGB(customAccent)
        let fg = color.map { "38;2;\($0.value >> 16);\($0.value >> 8 & 255);\($0.value & 255)" } ?? "38;5;\(code)"
        let bg = color.map { "48;2;\($0.value >> 16);\($0.value >> 8 & 255);\($0.value & 255)" } ?? "48;5;\(layout == .ribbon && code == 99 ? 57 : code)"
        let foreground = "\u{1b}[\(fg)m"
        let background = "\u{1b}[\(bg)m"
        let user = identity ? "\u{1b}[37m\(name) " : ""
        switch layout {
        case .minimal: return (identity ? "\u{1b}[37m\(name) · " : "") + foreground + path + " ❯ " + reset
        case .stacked: return foreground + "╭─ " + user + foreground + path + "\r\n╰─❯ " + reset
        case .classic, .ribbon:
            let tip = layout == .ribbon ? "\u{E0B0}" : "▶"
            let prefix = identity ? "\u{1b}[40;97m \(name) " + background + "\u{1b}[30m" + tip : background
            let end = layout == .ribbon && color == nil && code == 99 ? "\u{1b}[38;5;57m" : foreground
            return prefix + "\u{1b}[30m \(path) " + reset + end + tip + reset + " "
        }
    }

    static func liveConfiguration() -> String {
        let prefs = UserDefaults.standard
        guard prefs.bool(forKey: "powerline") else { return "off\n" }
        let library = ThemeLibrary(rawValue: prefs.string(forKey: "themeLibrary") ?? "") ?? .builtin
        if library != .builtin {
            let files = library.files
            guard let file = files.first(where: { $0.lastPathComponent == prefs.string(forKey: "themeFile." + library.rawValue) }) ?? files.first else { return "off\n" }
            let binary = PromptEngineTools().executable(library.engine, preferred: prefs.string(forKey: "enginePath." + library.rawValue))
            return library.engine + "\n" + file.path + "\n" + (binary?.path ?? "")
        }
        let color = Palette(rawValue: prefs.string(forKey: "promptPalette") ?? "") ?? .violet
        let identity = prefs.object(forKey: "promptIdentity") as? Bool ?? true
        let design = PromptDesign(rawValue: prefs.string(forKey: "promptDesign") ?? "") ?? .classic
        let prompt = design.prompt(color: RGB(prefs.string(forKey: "customAccent") ?? "")?.hex ?? String(color.code), identity: identity)
        return design.rawValue + "\n" + prompt
    }
}

struct PromptSettings: View {
    let didChange: () -> Void
    let engineTools: PromptEngineTools
    @AppStorage(PersistentTerminal.interactionKey) private var tmuxInteraction = true
    @AppStorage("restoreLastWindow") private var restoreLastWindow = true
    @AppStorage(AlertDestination.storageKey) private var alertDestination = AlertDestination.notch
    @State private var query = ""
    @State private var selection = Section.general
    @State private var showingDetail = false

    init(engineTools: PromptEngineTools = PromptEngineTools(), initialSection: String? = nil, didChange: @escaping () -> Void) {
        self.engineTools = engineTools; self.didChange = didChange
        if let section = initialSection.flatMap(Section.init(rawValue:)) { _selection = State(initialValue: section) }
    }

    private enum Section: String, CaseIterable, Identifiable {
        case general = "General", alerts = "Alerts", terminal = "Terminal", shortcuts = "Keyboard shortcuts"
        var id: Self { self }
        var icon: String {
            switch self {
            case .general: return "macwindow"
            case .alerts: return "bell.badge"
            case .terminal: return "terminal"
            case .shortcuts: return "keyboard"
            }
        }
        var subtitle: String {
            switch self {
            case .general: return "Windows · Startup"
            case .alerts: return "Notch · Banners"
            case .terminal: return "tmux · Extensions"
            case .shortcuts: return "Groups · Pages · Terminals"
            }
        }
        /// Words that find the section in search.
        var keywords: String {
            switch self {
            case .general: return "window restore size position startup launch"
            case .alerts: return "notification notch claude completion automation question banner"
            case .terminal: return "tmux mouse scrollback oh my posh starship engine zsh autosuggestions pay-respects plugin extensions marketplace"
            case .shortcuts: return "keyboard shortcut key create select group page terminal notch"
            }
        }
    }

    private var matches: [Section] {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return Section.allCases }
        return Section.allCases.filter {
            $0.rawValue.localizedCaseInsensitiveContains(text) || $0.keywords.localizedCaseInsensitiveContains(text)
                || $0.subtitle.localizedCaseInsensitiveContains(text)
        }
    }
    private var current: Section? { matches.contains(selection) ? selection : matches.first }

    var body: some View {
        GeometryReader { geo in
            let narrow = geo.size.width < 690
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Settings")
                        .font(TabTypography.suite(size: NSFont.preferredFont(forTextStyle: .title1).pointSize, relativeTo: .title))
                        .bold().kerning(-0.6)
                    Text("Preferences · Terminal · Shortcuts")
                        .font(TabTypography.suite(size: NSFont.preferredFont(forTextStyle: .caption1).pointSize + 1, relativeTo: .caption))
                        .foregroundStyle(.secondary)
                }
                HStack(alignment: .top, spacing: 16) {
                    if !narrow || !showingDetail {
                        VStack(alignment: .leading, spacing: 14) {
                            TextField("Search settings", text: $query)
                                .textFieldStyle(.roundedBorder)
                                .accessibilityLabel("Search settings")
                            ScrollView {
                                VStack(spacing: 4) {
                                    ForEach(matches) { section in sidebarRow(section) }
                                    if matches.isEmpty { Text("No matching settings").foregroundStyle(.secondary) }
                                }
                            }
                        }.frame(maxWidth: narrow ? .infinity : 260)
                    }
                    if !narrow { Divider() }
                    if !narrow || showingDetail {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 16) {
                                if narrow { Button("‹  All Settings") { showingDetail = false } }
                                if let section = current { detail(section) }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading).padding(4)
                            .padding(.trailing, 20)
                        }
                    }
                }
            }.padding([.leading, .vertical], 20)
             .padding(.trailing, narrow && !showingDetail ? 20 : 0)
        }
        .onChange(of: restoreLastWindow) { enabled in
            if !enabled { UserDefaults.standard.removeObject(forKey: "lastWindowSnapshot") }
        }
    }

    private func mark(_ section: Section, size: CGFloat) -> some View {
        Image(systemName: section.icon)
            .font(.system(size: size * 0.42, weight: .medium)).foregroundStyle(Color.accentColor)
            .frame(width: size, height: size)
            .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: SurfaceRadius.tile))
            .accessibilityHidden(true)
    }

    private func sidebarRow(_ section: Section) -> some View {
        LibraryRow(selected: current == section, select: { selection = section; showingDetail = true }) {
            HStack {
                mark(section, size: 34)
                VStack(alignment: .leading, spacing: 3) {
                    Text(section.rawValue).lineLimit(1)
                    Text(section.subtitle).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
        } action: { EmptyView() }
    }

    @ViewBuilder private func detail(_ section: Section) -> some View {
        HStack(alignment: .top, spacing: 14) {
            mark(section, size: 56)
            VStack(alignment: .leading, spacing: 4) {
                Text(section.rawValue).font(.title2.bold())
                Text(section.subtitle).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        Divider()
        switch section {
        case .general:
            SettingsLabel("Windows")
            SettingsBox {
                SettingsRow(title: "Restore window size and position",
                            detail: "Terminals and their processes reconnect either way.") {
                    Toggle("Restore window size and position", isOn: $restoreLastWindow)
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
            }
        case .alerts:
            SettingsLabel("Show alerts in")
            alertChoices
            Text("Claude completions and automation questions appear in one place.")
                .font(.caption).foregroundStyle(.secondary)
        case .terminal:
            SettingsBox {
                SettingsRow(title: "tmux", detail: "Select, scroll back and copy with tmux. Turn off to use the native terminal.") {
                    Toggle("Enabled", isOn: $tmuxInteraction).toggleStyle(.switch).labelsHidden().controlSize(.small)
                        .accessibilityLabel("Enable tmux mouse and scrollback")
                }
                .onChange(of: tmuxInteraction) { _ in
                    // Rewrites tmux.conf and reloads it into the running server.
                    _ = try? PersistentTerminal()
                }
            }
            Button("Open Extension Marketplace…") {
                NSApp.sendAction(#selector(AppDelegate.showExtensionMarketplace(_:)), to: nil, from: nil)
            }
        case .shortcuts:
            ShortcutSettings()
        }
    }

    private var alertChoices: some View {
        HStack(spacing: 10) {
            ForEach(AlertDestination.allCases) { item in
                let selected = alertDestination == item
                Button { alertDestination = item } label: {
                    HStack(spacing: 12) {
                        Image(systemName: item == .notch ? "laptopcomputer" : "bell.badge")
                            .font(.system(size: 18)).frame(width: 26)
                            .foregroundStyle(selected ? Color.accentColor : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                            Text(item == .notch ? "Cards at the top of the screen" : "macOS banners and alerts")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.85)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selected ? Color.accentColor : Color.secondary.opacity(0.5))
                    }
                    .padding(12)
                    .modifier(LibraryRowSurface(selected: selected))
                    .overlay(RoundedRectangle(cornerRadius: SurfaceRadius.tile, style: .continuous)
                        .strokeBorder(selected ? Color.accentColor.opacity(0.5) : .white.opacity(0.08)))
                    .contentShape(RoundedRectangle(cornerRadius: SurfaceRadius.tile))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }
}

/// A small heading above a group of settings, as in Keys and Automations details.
struct SettingsLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text).font(.callout.weight(.semibold)).foregroundStyle(.secondary) }
}

/// Rows of settings on one rounded surface.
struct SettingsBox<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        VStack(spacing: 0) { content }
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.07)))
    }
}

/// One line in a settings box: title and detail on the left, a control on the right.
struct SettingsRow<Accessory: View>: View {
    let title: String
    var detail: String?
    let accessory: Accessory

    init(title: String, detail: String? = nil, @ViewBuilder accessory: () -> Accessory) {
        self.title = title; self.detail = detail; self.accessory = accessory()
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout)
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 12)
            accessory
        }.padding(.horizontal, 16).padding(.vertical, 12)
    }
}

/// Prompt switch and personalization, shown from the Theme Marketplace.
struct PromptOptionsView: View {
    /// Applies prompt changes to open terminals.
    let changed: () -> Void
    /// Turns the custom prompt on, installing its engine first if needed.
    let turnOn: () -> Void
    @AppStorage("powerline") private var enabled = false
    @AppStorage("promptPalette") private var palette = Palette.violet.rawValue
    @AppStorage("promptIdentity") private var identity = true
    @AppStorage("themeLibrary") private var library = ThemeLibrary.builtin
    @AppStorage("customAccent") private var customAccent = ""
    @AppStorage("followThemeBackground") private var followBackground = true
    @AppStorage("followThemeAccent") private var followThemeAccent = true
    @AppStorage(ThemeKey.scheme) private var scheme = ""
    @ObservedObject private var store = ThemeStore.shared
    @State private var hexDraft = ""

    private var tint: Color { RGB(customAccent)?.color ?? (Palette(rawValue: palette) ?? .violet).color }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Prompt options").font(.system(size: 13, weight: .semibold)).padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 4)
            SettingsRow(title: "Custom prompt", detail: "Off uses your shell's own prompt.") {
                Toggle("Custom prompt", isOn: Binding(get: { enabled }, set: { $0 ? turnOn() : (enabled = false) }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            if enabled {
                if library == .builtin {
                    Divider().padding(.leading, 16)
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Accent color").font(.callout)
                        colorControls
                    }.padding(.horizontal, 16).padding(.vertical, 12)
                    Divider().padding(.leading, 16)
                    SettingsRow(title: "Show identity", detail: "User and computer name in the prompt.") { toggle($identity) }
                }
                Divider().padding(.leading, 16)
                SettingsRow(title: "Match interface accent", detail: "Tabs, buttons and selections use the prompt's color.") { toggle($followThemeAccent) }
                Divider().padding(.leading, 16)
                SettingsRow(title: "Prompt background", detail: "Terminals without a color scheme use the prompt's background.") {
                    Toggle("", isOn: Binding(get: { followBackground }, set: { if $0 { store.releaseScheme() }; followBackground = $0 }))
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
                // Read so the row follows scheme changes made elsewhere.
                if !scheme.isEmpty, let name = store.currentSchemeName {
                    Divider().padding(.leading, 16)
                    SettingsRow(title: "Terminal colors", detail: "\(name) colors the terminals, not the prompt.") {
                        Button("Use Prompt Colors") { store.releaseScheme() }.controlSize(.small)
                    }
                }
            }
        }
        .padding(.bottom, 6)
        .frame(width: 400)
        .onAppear { hexDraft = customAccent }
        .onChange(of: [String(enabled), palette, String(identity), customAccent, String(followBackground), scheme]) { _ in changed() }
    }

    private func toggle(_ value: Binding<Bool>) -> some View {
        Toggle("", isOn: value).labelsHidden().toggleStyle(.switch).controlSize(.small)
    }

    private var colorControls: some View {
        HStack(spacing: 10) {
            ForEach(Palette.allCases, id: \.rawValue) { item in
                let selected = customAccent.isEmpty && palette == item.rawValue
                Button { store.releaseScheme(); palette = item.rawValue; customAccent = ""; hexDraft = "" } label: {
                    Circle().fill(item.color).frame(width: 22, height: 22)
                        .overlay { if selected { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.black) } }
                        .padding(3).overlay(Circle().strokeBorder(selected ? item.color.opacity(0.65) : .clear))
                }.buttonStyle(HoverButtonStyle(cornerRadius: 14)).help(String(describing: item).capitalized)
                 .accessibilityLabel(String(describing: item).capitalized)
                 .accessibilityAddTraits(selected ? .isSelected : [])
            }
            Divider().frame(height: 18)
            ColorPicker("Custom accent", selection: Binding(get: { tint }, set: { next in
                guard let c = NSColor(next).usingColorSpace(.sRGB) else { return }
                store.releaseScheme()
                customAccent = String(format: "#%02X%02X%02X", Int((c.redComponent * 255).rounded()),
                                      Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()))
                hexDraft = customAccent
            }), supportsOpacity: false).labelsHidden()
            TextField("#RRGGBB", text: $hexDraft)
                .font(.system(size: 12, design: .monospaced)).textFieldStyle(.roundedBorder).frame(width: 88)
                .accessibilityLabel("Accent hex color")
                // Only a typed color differs from the stored one; syncing from customAccent does not.
                .onChange(of: hexDraft) { if let rgb = RGB($0), rgb.hex != customAccent { store.releaseScheme(); customAccent = rgb.hex } }
                .onChange(of: customAccent) { if hexDraft != $0 { hexDraft = $0 } }
        }
    }
}

// Every AppKit hosting view is a separate SwiftUI root, including the title bar.
struct ThemedRoot<Content: View>: View {
    let content: Content
    @AppStorage("powerline") private var enabled = false
    @AppStorage("followThemeAccent") private var follow = true
    @AppStorage("themeLibrary") private var library = ThemeLibrary.builtin
    @AppStorage("themeFile.Oh My Posh") private var poshFile = ""
    @AppStorage("themeFile.Starship") private var starshipFile = ""
    @AppStorage("promptPalette") private var palette = Palette.violet.rawValue
    @AppStorage("customAccent") private var custom = ""
    @AppStorage("promptDesign") private var design = ""
    @AppStorage(ThemeKey.accent) private var themeAccent = ""
    @AppStorage(ThemeKey.accentSignature) private var themeSignature = ""

    private var color: Color {
        guard enabled && follow else { return InterfaceAccent.mint }
        // Reads the same settings observed above, so the accent updates with them.
        _ = (design, poshFile, starshipFile, custom)
        if !themeAccent.isEmpty, themeSignature == PromptSetup.promptSignature(), let hex = HexColor(themeAccent) {
            return hex.color
        }
        if library == .builtin {
            return RGB(custom)?.color ?? (Palette(rawValue: palette) ?? .violet).color
        }
        let name = library == .posh ? poshFile : starshipFile
        let applied = InterfaceAccent.catalog[name] != nil ? name : library.files.first?.lastPathComponent ?? ""
        return InterfaceAccent.catalog[applied].flatMap(RGB.init)?.color ?? InterfaceAccent.mint
    }

    var body: some View {
        let accent = color
        content.accentColor(accent).tint(accent)
    }
}

private enum InterfaceAccent {
    static let mint = Color(red: 0.46, green: 0.87, blue: 0.76)
    static let catalog: [String: String] = {
        guard let url = PromptSetup.folder?.appendingPathComponent("theme-accents.json"),
              let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }()
}

extension View {
    func settingsSectionTitle() -> some View {
        self.font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
    }

    func settingsSurface(selected: Bool = false, accent: Color = Color.accentColor) -> some View {
        self.background(selected ? accent.opacity(0.065) : Color.white.opacity(0.025))
            .clipShape(RoundedRectangle(cornerRadius: SurfaceRadius.tile))
            .overlay(RoundedRectangle(cornerRadius: SurfaceRadius.tile).strokeBorder(selected ? accent.opacity(0.65) : .white.opacity(0.09)))
    }
}

/// Static ANSI previews keep theme galleries lightweight and never start a shell.
struct ThemeSampleView: NSViewRepresentable {
    let sample: String
    let background: NSColor
    var fontSize: CGFloat = 13
    static let samples: [String: String] = {
        guard let url = PromptSetup.folder?.appendingPathComponent("preview-samples.json"),
              let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }()

    final class SampleView: NSView {
        var rendered = NSAttributedString()
        var backdrop = NSColor.black
        var previousSample = ""
        var previousSize: CGFloat = 0
        var previousBackground: NSColor?
        override var isFlipped: Bool { true }
        override func draw(_ dirtyRect: NSRect) {
            backdrop.setFill()
            bounds.fill()
            NSGraphicsContext.saveGraphicsState()
            bounds.clip()
            rendered.draw(in: bounds)
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    func makeNSView(context: Context) -> SampleView { SampleView() }
    func updateNSView(_ view: SampleView, context: Context) {
        guard view.previousSample != sample || view.previousSize != fontSize || view.previousBackground != background else { return }
        view.previousSample = sample
        view.previousSize = fontSize
        view.previousBackground = background
        view.backdrop = background
        view.rendered = attributedSample
        view.needsDisplay = true
    }

    var fittingWidth: CGFloat { ceil(attributedSample.size().width) }

    private var attributedSample: NSAttributedString {
        let text = sample.replacingOccurrences(of: "\r\n", with: "\n")
        let raw = text as NSString
        let result = NSMutableAttributedString()
        let sgr = try! NSRegularExpression(pattern: #"\x1b\[([0-9;]*)m"#)
        var foreground = NSColor.white, fill = background
        var bold = false, italic = false, underline = false, inverse = false, dim = false
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byClipping
        paragraph.lineSpacing = 2
        func append(_ range: NSRange) {
            guard range.length > 0 else { return }
            let base = terminalFont(size: fontSize)
            var font = base
            let ink = inverse ? fill : foreground
            var attributes: [NSAttributedString.Key: Any] = [:]
            // The bundled Nerd Font has only a regular face. Converting to bold or
            // italic would switch to another family without the prompt icons, so
            // draw a synthetic bold or slant on the same font instead.
            if bold {
                let converted = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
                if converted.familyName == base.familyName && converted.fontName != base.fontName { font = converted }
                else { attributes[.strokeWidth] = -2.5; attributes[.strokeColor] = dim ? ink.withAlphaComponent(0.6) : ink }
            }
            if italic {
                let converted = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
                if converted.familyName == base.familyName && converted.fontName != font.fontName { font = converted }
                else { attributes[.obliqueness] = 0.18 }
            }
            attributes[.font] = font
            attributes[.foregroundColor] = dim ? ink.withAlphaComponent(0.6) : ink
            attributes[.backgroundColor] = inverse ? foreground : fill
            attributes[.underlineStyle] = underline ? NSUnderlineStyle.single.rawValue : 0
            attributes[.paragraphStyle] = paragraph
            result.append(NSAttributedString(string: raw.substring(with: range), attributes: attributes))
        }
        var offset = 0
        for match in sgr.matches(in: text, range: NSRange(location: 0, length: raw.length)) {
            append(NSRange(location: offset, length: match.range.location - offset))
            let values = raw.substring(with: match.range(at: 1)).split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
            var index = 0
            while index < values.count {
                let code = values[index]
                switch code {
                case 0: foreground = .white; fill = background; bold = false; italic = false; underline = false; inverse = false; dim = false
                case 1: bold = true
                case 2: dim = true
                case 3: italic = true
                case 4: underline = true
                case 7: inverse = true
                case 22: bold = false; dim = false
                case 23: italic = false
                case 24: underline = false
                case 27: inverse = false
                case 30...37: foreground = ansiColor(code - 30)
                case 40...47: fill = ansiColor(code - 40)
                case 90...97: foreground = ansiColor(code - 90 + 8)
                case 100...107: fill = ansiColor(code - 100 + 8)
                case 39: foreground = .white
                case 49: fill = background
                case 38, 48:
                    var color: NSColor?
                    if index + 2 < values.count, values[index + 1] == 5 {
                        color = ansiColor(values[index + 2]); index += 2
                    } else if index + 4 < values.count, values[index + 1] == 2 {
                        let rgb = values[(index + 2)...(index + 4)].map { CGFloat(max(0, min(255, $0))) / 255 }
                        color = NSColor(srgbRed: rgb[0], green: rgb[1], blue: rgb[2], alpha: 1); index += 4
                    }
                    if let color { if code == 38 { foreground = color } else { fill = color } }
                default: break
                }
                index += 1
            }
            offset = NSMaxRange(match.range)
        }
        append(NSRange(location: offset, length: raw.length - offset))
        return result
    }

    private func ansiColor(_ value: Int) -> NSColor {
        let value = max(0, min(255, value))
        if value < 16 {
            let colors = [0x000000, 0xcd0000, 0x00cd00, 0xcdcd00, 0x0000ee, 0xcd00cd, 0x00cdcd, 0xe5e5e5,
                          0x7f7f7f, 0xff0000, 0x00ff00, 0xffff00, 0x5c5cff, 0xff00ff, 0x00ffff, 0xffffff]
            let rgb = colors[value]
            return NSColor(srgbRed: CGFloat(rgb >> 16) / 255, green: CGFloat(rgb >> 8 & 255) / 255, blue: CGFloat(rgb & 255) / 255, alpha: 1)
        }
        if value >= 232 {
            let gray = CGFloat(8 + (value - 232) * 10) / 255
            return NSColor(srgbRed: gray, green: gray, blue: gray, alpha: 1)
        }
        let levels: [CGFloat] = [0, 95, 135, 175, 215, 255]
        let cube = value - 16
        return NSColor(srgbRed: levels[cube / 36] / 255, green: levels[cube / 6 % 6] / 255, blue: levels[cube % 6] / 255, alpha: 1)
    }
}

// Keep letter preferences from earlier versions; missing modifiers default to Command.
final class CreationKeys: ObservableObject {
    static let shared = CreationKeys()
    static let actions = ["Group", "Page", "Terminal"]
    static let defaults = ["Group": "g", "Page": "p", "Terminal": "t"]
    @Published private var overrides = UserDefaults.standard.dictionary(forKey: "creationCommandLetters") as? [String: String] ?? [:]
    @Published private var modifiers = UserDefaults.standard.dictionary(forKey: "creationCommandModifiers") as? [String: String] ?? [:]

    func key(_ action: String) -> String { overrides[action] ?? Self.defaults[action]! }
    func modifier(_ action: String) -> NavigationModifier { modifiers[action].flatMap(NavigationModifier.init) ?? .command }
    var windowKey: String {
        Self.actions.contains { key($0) == "n" && modifier($0) == .command } ? "" : "n"
    }
    var isDefault: Bool { Self.actions.allSatisfy { key($0) == Self.defaults[$0] && modifier($0) == .command } }
    func set(_ letter: String, modifier: NavigationModifier, for action: String) -> String? {
        if modifier == .command && "acvwxzqhm".contains(letter) { return "That shortcut is reserved for editing or window controls." }
        if Self.actions.contains(where: { $0 != action && key($0) == letter && self.modifier($0) == modifier }) {
            return "Another creation action already uses that shortcut."
        }
        overrides[action] = letter
        modifiers[action] = modifier.rawValue
        apply()
        return nil
    }
    func reset() { overrides = [:]; modifiers = [:]; apply() }
    private func apply() {
        UserDefaults.standard.set(overrides, forKey: "creationCommandLetters")
        UserDefaults.standard.set(modifiers, forKey: "creationCommandModifiers")
        let menu = NSApp.mainMenu?.item(withTitle: "Shell")?.submenu
        menu?.item(withTitle: "New Window")?.keyEquivalent = windowKey
        for action in Self.actions {
            let item = menu?.item(withTitle: "New " + action)
            item?.keyEquivalent = key(action)
            item?.keyEquivalentModifierMask = modifier(action).flags
        }
    }
}

private struct ShortcutSettings: View {
    @ObservedObject private var creation = CreationKeys.shared
    @ObservedObject private var navigation = NavigationKeys.shared
    @ObservedObject private var notch = NotchTerminalKey.shared
    private let keyWidth: CGFloat = 80

    private enum Column { case create, select, notch }
    private struct Target: Equatable { let scope: ShortcutScope; let column: Column }
    @State private var recording: Target?
    @State private var monitor: Any?
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SettingsLabel("Shortcuts")
                Spacer()
                Button("Restore Defaults") { stop(); creation.reset(); navigation.reset(); notch.reset() }
                    .controlSize(.small)
                    .disabled(navigation.isDefault && creation.isDefault && notch.isDefault)
            }
            SettingsBox {
                HStack {
                    Spacer()
                    Text("Create").frame(width: keyWidth)
                    Text("Select").frame(width: keyWidth)
                }
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.vertical, 8)
                ForEach(ShortcutScope.allCases, id: \.self) { scope in
                    Divider()
                    HStack {
                        Image(systemName: scope.icon).foregroundStyle(Color.accentColor).frame(width: 20)
                        Text(scope.rawValue).font(.callout)
                        Spacer(minLength: 4)
                        let name = scope.rawValue
                        keycap(creation.modifier(name).symbol + creation.key(name).uppercased(), Target(scope: scope, column: .create))
                        keycap(navigation.modifier(scope).symbol + " 1–0", Target(scope: scope, column: .select))
                            .help("Select by position in the current " + (scope == .group ? "window." : scope == .page ? "group." : "page.") + " Numbers follow the tab order.")
                    }
                    .padding(.horizontal, 16).padding(.vertical, 7)
                }
                Divider()
                HStack {
                    Image(systemName: "rectangle.topthird.inset.filled").foregroundStyle(Color.accentColor).frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Notch terminal").font(.callout)
                        Text("Works from any app.").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    keycap(notch.current.display, Target(scope: .terminal, column: .notch), width: keyWidth * 2 + 8)
                        .help("Show or hide the notch terminal from any app.")
                }
                .padding(.horizontal, 16).padding(.vertical, 7)
                Divider()
                Text(message ?? (recording == nil ? "Click a keycap, then press your shortcut." : recording?.column == .notch
                    ? "Press a key with ⌘, ⌥ or ⌃ (⇧ optional). Esc cancels."
                    : "Press ⌘, ⌥ or ⌃ with " + (recording?.column == .create ? "a letter." : "a number. Shared modifiers swap rows.") + " Esc cancels."))
                    .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.vertical, 12)
            }
        }
        .onDisappear { stop() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in stop() }
    }

    private func keycap(_ value: String, _ target: Target, width: CGFloat? = nil) -> some View {
        let active = recording == target
        return Button {
            if active { stop() } else { start(target) }
        } label: {
            Text(verbatim: active ? "Press keys…" : value)
                .font(TabTypography.suite(size: 12, relativeTo: .callout))
                .foregroundStyle(active ? Color.accentColor : Color.primary)
                .frame(width: width ?? keyWidth, height: 26, alignment: .center)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: SurfaceRadius.control))
                .overlay(RoundedRectangle(cornerRadius: SurfaceRadius.control).strokeBorder(active ? Color.accentColor : .clear))
        }
        .buttonStyle(HoverButtonStyle())
        .accessibilityLabel(target.column == .notch ? "Notch terminal shortcut"
            : (target.column == .create ? "Create " : "Select ") + target.scope.rawValue + " shortcut")
        .accessibilityValue(active ? "Recording" : value)
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = nil
        message = nil
    }

    private func start(_ target: Target) {
        stop()
        recording = target
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { event in
            guard event.type == .keyDown else { stop(); return event }
            if event.keyCode == 53 { stop(); return nil }
            if target.column == .notch {
                if let error = notch.set(keyCode: event.keyCode, flags: event.modifierFlags) { message = error; return nil }
                stop()
                return nil
            }
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard let modifier = NavigationModifier.allCases.first(where: { $0.flags == flags }) else {
                message = "Use one modifier: ⌘, ⌥ or ⌃. Esc cancels."
                return nil
            }
            switch target.column {
            case .select:
                guard ShellTabShortcuts.keyCodes.prefix(10).contains(event.keyCode) else {
                    message = "Press the modifier with a number from the top row."
                    return nil
                }
                navigation.assign(modifier, to: target.scope)
            case .notch: break
            case .create:
                guard let letter = event.characters(byApplyingModifiers: [])?.lowercased(), letter.count == 1,
                      letter.first?.isASCII == true, letter.first?.isLetter == true else {
                    message = "Press the modifier with a letter (A–Z)."
                    return nil
                }
                if let error = creation.set(letter, modifier: modifier, for: target.scope.rawValue) {
                    message = error
                    return nil
                }
            }
            stop()
            return nil
        }
    }
}
