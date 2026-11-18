import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Prompts

/// A prompt that ships with bananaShell: a built-in layout, or an Oh My Posh or Starship theme.
struct PromptItem: Identifiable, Hashable {
    let id: String
    let name: String
    let library: ThemeLibrary
    let prompt: ThemePrompt
    let background: NSColor

    var engine: PromptEngine? { library.dependency }
    var sample: String {
        if library == .builtin, let design = prompt.design.flatMap(PromptDesign.init(rawValue:)) {
            return PromptSetup.builtInSample(design)
        }
        return prompt.file.flatMap { ThemeSampleView.samples[$0] } ?? ""
    }
    var license: String {
        switch library {
        case .builtin: return "MIT (bananaShell)"
        case .posh: return "MIT (Oh My Posh themes)"
        case .starship: return "ISC (Starship presets)"
        }
    }
}

enum PromptCatalog {
    static func id(library: ThemeLibrary, name: String) -> String {
        "prompt-" + ThemeStore.slug(library.rawValue) + "-" + ThemeStore.slug(name)
    }

    /// “catppuccin_mocha” → “Catppuccin Mocha”; names with capitals are kept.
    static func displayName(_ title: String) -> String {
        let spaced = title.replacingOccurrences(of: "[._-]+", with: " ", options: .regularExpression)
        guard spaced == spaced.lowercased() else { return spaced }
        return spaced.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    static func items() -> [PromptItem] {
        let builtins = PromptDesign.allCases.map { design in
            PromptItem(id: id(library: .builtin, name: design.rawValue), name: design.rawValue, library: .builtin,
                       prompt: ThemePrompt(engine: "builtin", design: design.rawValue), background: shellSurface)
        }
        let files = [ThemeLibrary.posh, .starship].flatMap { library in
            library.files.map { url in
                PromptItem(id: id(library: library, name: library.title(url)), name: displayName(library.title(url)), library: library,
                           prompt: ThemePrompt(engine: library.engine, file: url.lastPathComponent),
                           background: PromptSetup.background(file: url, follow: true, accent: .systemPurple))
            }
        }
        return builtins + files
    }

    /// The prompt in use, or nil when the custom prompt is off.
    static func currentID() -> String? {
        let prefs = UserDefaults.standard
        guard prefs.bool(forKey: "powerline") else { return nil }
        let library = ThemeLibrary(rawValue: prefs.string(forKey: "themeLibrary") ?? "") ?? .builtin
        if library == .builtin { return id(library: .builtin, name: prefs.string(forKey: "promptDesign") ?? PromptDesign.classic.rawValue) }
        let files = library.files
        guard let file = files.first(where: { $0.lastPathComponent == prefs.string(forKey: "themeFile." + library.rawValue) }) ?? files.first
        else { return nil }
        return id(library: library, name: library.title(file))
    }

    /// The catalog ID of the prompt inside a theme.
    static func id(for prompt: ThemePrompt?) -> String? {
        guard let prompt, let library = prompt.library.flatMap(ThemeLibrary.init(rawValue:)) else { return nil }
        if library == .builtin { return id(library: .builtin, name: prompt.design ?? PromptDesign.classic.rawValue) }
        guard let file = prompt.file else { return nil }
        return id(library: library, name: library.title(URL(fileURLWithPath: file)))
    }
}

// MARK: - Cards

/// One item in the gallery: a catalog theme or color scheme, an installed theme, or a prompt.
private struct ThemeCard: Identifiable, Hashable {
    enum Kind: Int { case bundle, prompt, scheme }

    let id: String
    let name: String
    var kind: Kind
    var summary: String?
    var author: String?
    var license: String?
    var source: String?
    var tags: [String]
    var scheme: ThemeScheme?
    var promptTitle: String?
    var engine: PromptEngine?
    var accent: String?
    var likes = 0
    var isLight: Bool
    var entry: CatalogEntry?
    var bundle: ThemeBundle?
    /// The prompt itself, for prompt items and themes that include one.
    var promptItem: PromptItem?

    init(entry: CatalogEntry, prompt: PromptItem? = nil) {
        id = entry.id; name = entry.name; kind = entry.isBundle ? .bundle : .scheme; summary = entry.summary
        author = entry.author; license = entry.license; source = entry.source; tags = entry.tags ?? []
        scheme = entry.preview; accent = entry.accent; likes = entry.likes ?? 0; isLight = entry.isLight; self.entry = entry
        engine = entry.prompt.flatMap(PromptEngine.init(rawValue:)); promptItem = prompt
        promptTitle = entry.prompt.map { $0 == "builtin" ? "Built-in prompt" : $0 == "starship" ? "Starship" : "Oh My Posh" }
    }

    init(bundle: ThemeBundle, entry: CatalogEntry? = nil, prompt: PromptItem? = nil) {
        id = bundle.id; name = bundle.name; kind = bundle.prompt == nil ? .scheme : .bundle; summary = bundle.summary
        author = bundle.author; license = bundle.license; source = bundle.source; tags = bundle.tags ?? []
        scheme = bundle.scheme; accent = bundle.accent; promptTitle = bundle.prompt?.title; likes = entry?.likes ?? 0
        engine = bundle.prompt.flatMap { PromptEngine(rawValue: $0.engine) }
        isLight = bundle.isLight; self.entry = entry; self.bundle = bundle; promptItem = prompt
    }

    init(prompt item: PromptItem) {
        id = item.id; name = item.name; kind = .prompt; license = item.license
        summary = item.library == .builtin ? "Built-in prompt layout in your accent color." : "\(item.library.rawValue) prompt theme."
        tags = [item.library.rawValue.lowercased()]; promptTitle = item.library == .builtin ? "Built-in" : item.library.rawValue
        engine = item.engine; isLight = (HexColor(item.background)?.luminance ?? 0) > 0.5; promptItem = item
    }

    var includesPrompt: Bool { kind != .scheme }
    var kindTitle: String {
        switch kind {
        case .bundle: return "Theme"
        case .prompt: return "Prompt"
        case .scheme: return "Colors"
        }
    }

    /// First distinctive word of the name, for pairing (“Catppuccin Mocha” ↔ “catppuccin_mocha”).
    var pairKey: String {
        let stop: Set = ["dark", "light", "theme", "shell", "default", "no", "plain", "pure", "simple", "the", "night", "my", "new"]
        let words = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
            .split { !$0.isLetter }.map(String.init)
        return words.first { !stop.contains($0) && $0.count >= 4 } ?? ""
    }
}

// MARK: - Marketplace

struct ThemeMarketplaceView: View {
    @ObservedObject private var store = ThemeStore.shared
    @AppStorage(ThemeKey.active) private var active = ""
    @AppStorage(ThemeKey.scheme) private var activeScheme = ""
    @AppStorage(ThemeKey.automatic) private var automatic = false
    @AppStorage(ThemeKey.light) private var lightTheme = ""
    @AppStorage(ThemeKey.dark) private var darkTheme = ""
    // Observed so “in use” marks follow prompt changes made anywhere.
    @AppStorage("powerline") private var promptEnabled = false
    @AppStorage("themeLibrary") private var promptLibrary = ""
    @AppStorage("themeFile.Oh My Posh") private var poshFile = ""
    @AppStorage("themeFile.Starship") private var starshipFile = ""
    @AppStorage("promptDesign") private var promptDesign = ""

    fileprivate enum Section: String, CaseIterable {
        case featured = "Featured", themes = "Themes", prompts = "Prompts", colors = "Colors", installed = "Installed"
        var icon: String {
            switch self {
            case .featured: return "sparkles"
            case .themes: return "paintpalette"
            case .prompts: return "chevron.right.square"
            case .colors: return "paintbrush"
            case .installed: return "checkmark.circle"
            }
        }
    }
    private enum Engine: String, CaseIterable { case any = "Any engine", builtin = "Built-in", posh = "Oh My Posh", starship = "Starship" }
    private enum Tone: String, CaseIterable { case any = "Dark and light", dark = "Dark", light = "Light" }
    private enum Order: String, CaseIterable { case featured = "Featured", popular = "Popular", name = "Name" }

    @State private var section = Section.featured
    @State private var search = ""
    @State private var engineFilter = Engine.any
    @State private var tone = Tone.any
    @State private var order = Order.featured
    @State private var detail: ThemeCard?
    @State private var busy: String?
    @State private var problem: String?
    @State private var caution: (ThemeBundle, [String])?
    @State private var engineRequest: EngineRequest?
    @State private var visible = false
    @State private var prompts: [PromptItem] = []
    @State private var bundlePrompts: [String: PromptItem] = [:]
    @State private var installedEngines: Set<PromptEngine> = []
    @State private var showingPromptOptions = false

    private struct EngineRequest: Identifiable {
        let id = UUID()
        let engine: PromptEngine
        let name: String
        let then: () -> Void
    }

    private let initialSelection: String?
    init(initialSelection: String? = nil) { self.initialSelection = initialSelection }

    // MARK: Data

    private var currentPrompt: String? {
        _ = (promptEnabled, promptLibrary, poshFile, starshipFile, promptDesign)
        return PromptCatalog.currentID()
    }

    private func isActive(_ card: ThemeCard, prompt: String?) -> Bool {
        switch card.kind {
        case .prompt: return card.id == prompt
        case .scheme: return activeScheme == card.id
        case .bundle:
            guard active == card.id, card.scheme == nil || activeScheme == card.id else { return false }
            let bundle = card.bundle ?? store.installed.first { $0.id == card.id }
            return PromptCatalog.id(for: bundle?.prompt) == prompt
        }
    }

    private var allCards: [ThemeCard] {
        store.catalog.map { ThemeCard(entry: $0, prompt: bundlePrompts[$0.id]) } + prompts.map(ThemeCard.init(prompt:))
    }

    private var installedCards: [ThemeCard] {
        let entries = Dictionary(store.catalog.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return store.installed.map { theme in
            ThemeCard(bundle: theme, entry: entries[theme.id],
                      prompt: PromptCatalog.id(for: theme.prompt).flatMap { id in prompts.first { $0.id == id } })
        }
    }

    private func filtered(_ list: [ThemeCard]) -> [ThemeCard] {
        let query = search.trimmingCharacters(in: .whitespaces)
        let result = list.filter { card in
            let engineMatches: Bool
            switch engineFilter {
            case .any: engineMatches = true
            case .builtin: engineMatches = card.includesPrompt && card.engine == nil
            case .posh: engineMatches = card.engine == .posh
            case .starship: engineMatches = card.engine == .starship
            }
            return engineMatches && (tone == .any || (tone == .light) == card.isLight)
                && (query.isEmpty || card.name.localizedCaseInsensitiveContains(query)
                    || card.tags.contains { $0.localizedCaseInsensitiveContains(query) }
                    || (card.author ?? "").localizedCaseInsensitiveContains(query))
        }
        switch order {
        case .featured: return result.sorted { ($0.kind.rawValue, -$0.likes) < ($1.kind.rawValue, -$1.likes) }
        case .popular: return result.sorted { $0.likes != $1.likes ? $0.likes > $1.likes : $0.name < $1.name }
        case .name: return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }

    private func cards(for section: Section) -> [ThemeCard] {
        switch section {
        case .featured: return filtered(allCards)
        case .themes: return filtered(allCards.filter { $0.kind == .bundle })
        case .prompts: return filtered(allCards.filter { $0.kind == .prompt })
        case .colors: return filtered(allCards.filter { $0.kind == .scheme })
        case .installed: return filtered(installedCards)
        }
    }

    /// Prompts, colors and themes that share a name with the card, plus curated themes using its colors.
    private func pairs(for card: ThemeCard) -> [ThemeCard] {
        let key = card.pairKey
        let everything = allCards
        var result = everything.filter { other in
            other.id != card.id && other.kind != card.kind && !key.isEmpty && !other.pairKey.isEmpty
                && (other.pairKey.hasPrefix(key) || key.hasPrefix(other.pairKey))
        }
        if card.kind == .scheme, let name = card.scheme?.name {
            result += everything.filter { $0.kind == .bundle && $0.scheme?.name == name && !result.contains($0) }
        }
        return Array(result.sorted { ($0.kind.rawValue, $0.name) < ($1.kind.rawValue, $1.name) }.prefix(8))
    }

    private static let featuredPrompts = ["Classic", "Ribbon", "Minimal", "Stacked", "Catppuccin Mocha", "Dracula", "Tokyonight Storm",
                                          "Atomic", "Night Owl", "Tokyo Night", "Gruvbox Rainbow", "Pastel Powerline", "Jetpack", "Pure Preset"]
    private static let featuredColors = ["Catppuccin Mocha", "TokyoNight", "Nord", "Gruvbox Dark", "Rose Pine", "Kanagawa Wave",
                                         "Catppuccin Latte", "Rose Pine Dawn", "Gruvbox Light", "Nord Light", "TokyoNight Day", "Kanagawa Lotus"]

    // MARK: Body

    var body: some View {
        let prompt = currentPrompt
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: MarketplaceMetrics.headerSpacing) {
                header
                ScrollView {
                    VStack(alignment: .leading, spacing: MarketplaceMetrics.contentSpacing) {
                        hero(prompt: prompt)
                        toolbar
                        if let note = store.catalogNote, section != .installed {
                            Label(note, systemImage: "wifi.exclamationmark").font(.caption).foregroundStyle(.secondary)
                        }
                        if section == .installed { appearancePanel }
                        if section == .featured && search.isEmpty { shelves(prompt: prompt) } else { grid(prompt: prompt) }
                    }.padding(.bottom, store.trying == nil ? MarketplaceMetrics.bottomPadding : 76)
                }
            }
            .padding(.horizontal, MarketplaceMetrics.horizontalPadding).padding(.top, MarketplaceMetrics.topPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .overlay(alignment: .bottom) { if let trying = store.trying { trialBar(trying) } }
            if let card = detail {
                Divider()
                ThemeInspector(card: card, active: isActive(card, prompt: prompt), installed: store.isInstalled(card.id),
                               engineMissing: card.engine.map { !installedEngines.contains($0) } ?? false,
                               pairs: pairs(for: card), open: { detail = $0 }, close: { detail = nil },
                               use: { use(card) }, tryOn: { tryOn(card) }, remove: { store.uninstall(card.id); detail = nil })
                    .frame(width: MarketplaceMetrics.inspectorWidth)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.18), value: detail?.id)
        .task { await store.refresh(ifOlderThan: 600) }
        .sheet(item: $engineRequest) { request in
            PromptEngineInstallView(engine: request.engine, theme: request.name, tools: PromptEngineTools()) { binary in
                UserDefaults.standard.set(binary.path, forKey: "enginePath." + request.engine.title)
                engineRequest = nil
                refreshEngines()
                request.then()
            }
        }
        // Every window has a marketplace tab; only the one on screen takes an opened theme.
        .onChange(of: store.pending) { _ in if visible { takePending() } }
        .onAppear {
            visible = true
            loadPrompts()
            refreshEngines()
            takePending()
            if let id = initialSelection { detail = allCards.first { $0.id == id } }
        }
        .onChange(of: store.catalog) { _ in loadPrompts() }
        .onDisappear { visible = false }
        .alert("Theme", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(problem ?? "") }
        .alert("Install this theme?", isPresented: Binding(get: { caution != nil }, set: { if !$0 { caution = nil } })) {
            Button("Install Anyway") { if let theme = caution?.0 { caution = nil; install(theme) } }
            Button("Cancel", role: .cancel) {}
        } message: { Text((caution?.1 ?? []).joined(separator: "\n")) }
    }

    // MARK: Sections

    private var header: some View {
        MarketplaceHeader(title: "Themes", subtitle: "Colors and prompts for your terminals, alone or as a set.") {
            Button { importFile() } label: { Image(systemName: "square.and.arrow.down") }
                .help("Import a theme or color scheme").buttonStyle(MarketIconButtonStyle())
            Button(action: exportCurrent) { Image(systemName: "square.and.arrow.up") }
                .accessibilityLabel("Save Current Setup as File")
                .help("Save current setup as a theme file").buttonStyle(MarketIconButtonStyle())
            Button { Task { await store.refresh() } } label: {
                if store.refreshing { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") }
            }.help("Refresh the catalog").disabled(store.refreshing).buttonStyle(MarketIconButtonStyle())
        }
    }

    /// The current look: colors and prompt together, each with its own change button.
    private func hero(prompt: String?) -> some View {
        let scheme = store.scheme(for: nil)
        let item = prompt.flatMap { id in prompts.first { $0.id == id } }
        return HStack(spacing: 0) {
            LookPreview(scheme: scheme ?? .standard, prompt: item, large: true)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .padding(10)
            VStack(alignment: .leading, spacing: 14) {
                MarketplaceEyebrow("Your setup")
                layerRow(icon: "paintbrush", title: "Colors", value: scheme?.name ?? "bananaShell default") { section = .colors }
                layerRow(icon: "chevron.right.square", title: "Prompt",
                         value: item.map { "\($0.name) · \($0.library.rawValue)" } ?? "Off") { section = .prompts }
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    Button { showingPromptOptions = true } label: { Label("Prompt Options", systemImage: "slider.horizontal.3") }
                        .popover(isPresented: $showingPromptOptions, arrowEdge: .bottom) {
                            PromptOptionsView(changed: { store.changed() }, turnOn: turnPromptOn)
                        }
                    if scheme != nil { Button("Default Colors") { store.resetToDefault() } }
                    Button("Save as Theme…") { exportCurrent() }
                }.controlSize(.small)
            }
            .padding(18)
            .frame(width: 300, alignment: .leading)
        }
        .frame(height: 188)
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.08)))
    }

    private func layerRow(icon: String, title: String, value: String, change: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).frame(width: 18).foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.system(size: 13, weight: .medium)).lineLimit(1)
            }
            Spacer(minLength: 6)
            Button("Change", action: change).buttonStyle(.borderless).font(.caption)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            MarketplaceTabBar {
                ForEach(Section.allCases, id: \.self) { item in
                    MarketplaceTab(title: item.rawValue, icon: item.icon, selected: section == item) { section = item }
                }
            }
            Spacer(minLength: 8)
            MarketplaceSearchField(prompt: "Search themes", text: $search)
            Menu {
                Picker("Engine", selection: $engineFilter) { ForEach(Engine.allCases, id: \.self) { Text($0.rawValue) } }
                Picker("Tone", selection: $tone) { ForEach(Tone.allCases, id: \.self) { Text($0.rawValue) } }
                Picker("Sort", selection: $order) { ForEach(Order.allCases, id: \.self) { Text($0.rawValue) } }
            } label: {
                Image(systemName: filtersActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Filter and sort")
        }
    }

    private var filtersActive: Bool { engineFilter != .any || tone != .any || order != .featured }

    private func shelves(prompt: String?) -> some View {
        let everything = filtered(allCards)
        let themes = everything.filter { $0.kind == .bundle }
        let allPrompts = everything.filter { $0.kind == .prompt }
        let promptPicks = Self.featuredPrompts.compactMap { name in allPrompts.first { $0.name == name } }
        let colors = everything.filter { $0.kind == .scheme }
        func picks(light: Bool) -> [ThemeCard] {
            let curated = Self.featuredColors.compactMap { name in colors.first { $0.name == name && $0.isLight == light } }
            return curated + colors.filter { $0.isLight == light && !curated.contains($0) }.prefix(14 - curated.count)
        }
        let currentScheme = colors.first { $0.id == activeScheme }
        let matches = currentScheme.map { pairs(for: $0).filter { $0.kind == .prompt } } ?? []
        return VStack(alignment: .leading, spacing: MarketplaceMetrics.shelfSpacing) {
            shelf("Complete themes", subtitle: "Colors, prompt and accent that belong together.", cards: themes, prompt: prompt, wide: true) { section = .themes }
            if let currentScheme, !matches.isEmpty {
                shelf("Prompts for \(currentScheme.name)", subtitle: "Made for the colors you use.", cards: matches, prompt: prompt) { section = .prompts }
            }
            shelf("Prompts", subtitle: "Built-in layouts and Oh My Posh and Starship themes.", cards: promptPicks, prompt: prompt) { section = .prompts }
            shelf("Dark colors", subtitle: nil, cards: picks(light: false), prompt: prompt) { tone = .dark; section = .colors }
            shelf("Light colors", subtitle: nil, cards: picks(light: true), prompt: prompt) { tone = .light; section = .colors }
        }
    }

    private func shelf(_ title: String, subtitle: String?, cards: [ThemeCard], prompt: String?, wide: Bool = false,
                       seeAll: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: MarketplaceMetrics.shelfHeaderSpacing) {
            MarketplaceShelfHeader(title: title, subtitle: subtitle) {
                Button("See All", action: seeAll).buttonStyle(.borderless).font(.callout)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: MarketplaceMetrics.gridColumnSpacing) {
                    ForEach(cards) { card in tile(card, prompt: prompt).frame(width: wide ? 290 : 230) }
                }.padding(.vertical, 2)
            }
        }
    }

    private func grid(prompt: String?) -> some View {
        let list = cards(for: section)
        return Group {
            if list.isEmpty {
                MarketplaceEmptyState(symbol: section == .installed ? "tray" : "magnifyingglass",
                                      message: section == .installed ? "Themes and color schemes you get appear here." : "No matches.")
            } else {
                VStack(alignment: .leading, spacing: MarketplaceMetrics.shelfHeaderSpacing) {
                    Text("\(list.count) \(list.count == 1 ? "item" : "items")").font(.caption).foregroundStyle(.secondary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: MarketplaceMetrics.gridColumnSpacing)],
                              spacing: MarketplaceMetrics.gridRowSpacing) {
                        ForEach(list) { card in tile(card, prompt: prompt) }
                    }
                }
            }
        }
    }

    private func tile(_ card: ThemeCard, prompt: String?) -> some View {
        ThemeTile(card: card, active: isActive(card, prompt: prompt), selected: detail?.id == card.id,
                  installed: card.kind == .prompt || store.isInstalled(card.id),
                  engineMissing: card.engine.map { !installedEngines.contains($0) } ?? false,
                  busy: busy == card.id, open: { detail = card }, use: { use(card) }, tryOn: { tryOn(card) })
    }

    private var appearancePanel: some View {
        let options = store.installed
        return HStack(spacing: 12) {
            Image(systemName: "circle.lefthalf.filled").foregroundStyle(Color.accentColor)
            Toggle("Match macOS light and dark", isOn: $automatic).toggleStyle(.switch).controlSize(.small)
                .onChange(of: automatic) { _ in store.followAppearance() }
            Spacer()
            Picker("Light", selection: $lightTheme) {
                Text("None").tag("")
                ForEach(options) { Text($0.name).tag($0.id) }
            }.disabled(!automatic).fixedSize()
            Picker("Dark", selection: $darkTheme) {
                Text("None").tag("")
                ForEach(options) { Text($0.name).tag($0.id) }
            }.disabled(!automatic).fixedSize()
        }
        .controlSize(.small)
        .onChange(of: lightTheme) { _ in store.followAppearance() }
        .onChange(of: darkTheme) { _ in store.followAppearance() }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
    }

    private func trialBar(_ name: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "eye.fill").foregroundStyle(Color.accentColor)
            Text("Trying ").foregroundColor(.secondary) + Text(name).bold()
            Spacer(minLength: 16)
            Button("Revert") { store.revert() }
            Button("Keep") { store.keep() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
        }
        .font(.callout)
        .padding(.leading, 18).padding(.trailing, 10).frame(height: 46)
        .frame(maxWidth: 520)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
        .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
        .padding(.bottom, 18)
    }

    // MARK: Actions

    private func loadPrompts() {
        prompts = PromptCatalog.items()
        var map: [String: PromptItem] = [:]
        for entry in store.catalog where entry.isBundle {
            if let id = PromptCatalog.id(for: store.localBundle(for: entry)?.prompt), let item = prompts.first(where: { $0.id == id }) {
                map[entry.id] = item
            }
        }
        bundlePrompts = map
    }

    private func refreshEngines() {
        let prefs = UserDefaults.standard
        installedEngines = Set([PromptEngine.posh, .starship].filter {
            PromptEngineTools().executable($0.rawValue, preferred: prefs.string(forKey: "enginePath." + $0.title)) != nil
        })
    }

    /// Turns the custom prompt back on with the last chosen prompt.
    private func turnPromptOn() {
        let prefs = UserDefaults.standard
        let library = ThemeLibrary(rawValue: prefs.string(forKey: "themeLibrary") ?? "") ?? .builtin
        let prompt: ThemePrompt
        if library == .builtin {
            prompt = ThemePrompt(engine: "builtin", design: prefs.string(forKey: "promptDesign") ?? PromptDesign.classic.rawValue)
        } else {
            let file = prefs.string(forKey: "themeFile." + library.rawValue) ?? library.files.first?.lastPathComponent
            prompt = ThemePrompt(engine: library.engine, file: file)
        }
        if case .needsEngine(let engine) = store.applyPrompt(prompt) {
            showingPromptOptions = false
            engineRequest = EngineRequest(engine: engine, name: library.rawValue) { store.applyPrompt(prompt) }
        }
    }

    private func takePending() {
        guard let theme = store.pending else { return }
        store.pending = nil
        detail = ThemeCard(bundle: theme, prompt: PromptCatalog.id(for: theme.prompt).flatMap { id in prompts.first { $0.id == id } })
    }

    private func load(_ card: ThemeCard) async -> ThemeBundle? {
        if let bundle = store.installed.first(where: { $0.id == card.id }) ?? card.bundle { return bundle }
        guard let entry = card.entry else { return nil }
        busy = card.id
        defer { busy = nil }
        do { return try await store.bundle(for: entry) } catch { problem = error.localizedDescription; return nil }
    }

    private func use(_ card: ThemeCard) {
        if card.kind == .prompt, let item = card.promptItem {
            if store.trying != nil { store.keep() }
            if case .needsEngine(let engine) = store.applyPrompt(item.prompt) {
                engineRequest = EngineRequest(engine: engine, name: item.name) { store.applyPrompt(item.prompt) }
            }
            return
        }
        Task {
            guard let theme = await load(card) else { return }
            if !store.isInstalled(theme.id) {
                let warnings = ThemeStore.warnings(for: theme)
                if !warnings.isEmpty { caution = (theme, warnings); return }
            }
            install(theme)
        }
    }

    private func install(_ theme: ThemeBundle) {
        do {
            if store.trying != nil { store.keep() }
            if !store.isInstalled(theme.id) { try store.install(theme) }
            finishUse(store.installed.first { $0.id == theme.id } ?? theme)
        } catch { problem = error.localizedDescription }
    }

    private func finishUse(_ theme: ThemeBundle) {
        if case .needsEngine(let engine) = store.apply(theme) {
            engineRequest = EngineRequest(engine: engine, name: theme.name) { finishUse(theme) }
        }
    }

    private func tryOn(_ card: ThemeCard) {
        if card.kind == .prompt, let item = card.promptItem {
            if case .needsEngine(let engine) = store.tryPrompt(item.prompt, name: item.name) {
                engineRequest = EngineRequest(engine: engine, name: item.name) { _ = store.tryPrompt(item.prompt, name: item.name) }
            }
            return
        }
        Task {
            guard let theme = await load(card) else { return }
            guard ThemeStore.warnings(for: theme).isEmpty || store.isInstalled(theme.id) else {
                problem = "Review this theme before using it: " + ThemeStore.warnings(for: theme).joined(separator: " ")
                return
            }
            do { try store.tryOn(theme) } catch { problem = error.localizedDescription }
        }
    }

    private func importFile() {
        let panel = NSOpenPanel()
        panel.message = "Choose a .bananatheme file or a color scheme from iTerm2, Windows Terminal, Ghostty, kitty or Alacritty."
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { detail = ThemeCard(bundle: try ThemeStore.importTheme(from: url)) } catch { problem = error.localizedDescription }
    }

    private func exportCurrent() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "My Theme.bananatheme"
        panel.allowedContentTypes = [UTType(filenameExtension: "bananatheme") ?? .json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let name = url.deletingPathExtension().lastPathComponent
        let theme = store.exportCurrent(named: name)
        guard theme.scheme != nil || theme.prompt != nil else {
            problem = "Choose a color scheme or a custom prompt before saving a theme."
            return
        }
        do { try ThemeStore.encoded(theme).write(to: url, options: .atomic) } catch { problem = error.localizedDescription }
    }
}

// MARK: - Previews

/// A small terminal session in a scheme's colors, with a prompt drawn on top when there is one.
private struct LookPreview: View {
    let scheme: ThemeScheme
    var prompt: PromptItem?
    var accent: String?
    var large = false
    /// Prompt items keep the background their theme was designed on.
    var promptBackground = false

    var body: some View {
        let s = scheme
        let fg = HexColor(s.foreground)?.color ?? .white
        let accentColor = accent.flatMap(HexColor.init)?.color ?? s.ansiColor(4)
        let background = promptBackground ? (prompt?.background ?? s.backgroundColor) : s.backgroundColor
        let size: CGFloat = large ? 12.5 : 10.5
        VStack(alignment: .leading, spacing: large ? 5 : 3) {
            if let prompt, !prompt.sample.isEmpty {
                ThemeSampleView(sample: prompt.sample, background: background, fontSize: size)
                    .frame(height: large ? 40 : 30, alignment: .topLeading)
                    .allowsHitTesting(false).accessibilityHidden(true)
            } else {
                (Text("❯ ").foregroundColor(accentColor) + Text("~/project ").foregroundColor(s.ansiColor(4))
                 + Text("git status").foregroundColor(fg))
                    .font(.system(size: size, design: .monospaced))
            }
            if promptBackground, let prompt, !prompt.sample.isEmpty {
                // A prompt on its own: a command's output between two prompts.
                Text("Sources/  build.sh  notes.md").font(.system(size: size, design: .monospaced))
                    .foregroundColor(.white.opacity(0.62))
                ThemeSampleView(sample: prompt.sample, background: background, fontSize: size)
                    .frame(height: large ? 40 : 30, alignment: .topLeading)
                    .allowsHitTesting(false).accessibilityHidden(true)
            } else {
                Group {
                    (Text("On branch ").foregroundColor(fg) + Text("main").foregroundColor(s.ansiColor(2)))
                    (Text("  modified: ").foregroundColor(s.ansiColor(1)) + Text("README.md").foregroundColor(s.ansiColor(1)))
                    if large {
                        (Text("  new file: ").foregroundColor(s.ansiColor(2)) + Text("theme.json").foregroundColor(s.ansiColor(2)))
                        (Text("Sources/  ").foregroundColor(s.ansiColor(12)) + Text("build.sh  ").foregroundColor(s.ansiColor(10))
                         + Text("warn.log").foregroundColor(s.ansiColor(3)))
                    }
                }
                .font(.system(size: size, design: .monospaced))
            }
            Spacer(minLength: 0)
            if !promptBackground {
                HStack(spacing: 2) {
                    ForEach(0..<16, id: \.self) { index in
                        RoundedRectangle(cornerRadius: 1.5).fill(s.ansiColor(index)).frame(height: large ? 8 : 5)
                    }
                }
            }
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(large ? 16 : 11)
        .background(Color(nsColor: background))
    }
}

private struct CardPreview: View {
    let card: ThemeCard
    var large = false

    var body: some View {
        LookPreview(scheme: card.scheme ?? .standard, prompt: card.promptItem, accent: card.accent, large: large,
                    promptBackground: card.kind == .prompt)
    }
}

/// A thumbnail for lists: palette dots on the background, or the start of the prompt.
private struct MiniPreview: View {
    let card: ThemeCard

    var body: some View {
        let scheme = card.scheme ?? .standard
        let background = card.kind == .prompt ? (card.promptItem?.background ?? scheme.backgroundColor) : scheme.backgroundColor
        ZStack(alignment: .leading) {
            Color(nsColor: background)
            if card.kind == .prompt, let item = card.promptItem {
                ThemeSampleView(sample: item.sample, background: background, fontSize: 7.5)
                    .frame(height: 12).padding(.leading, 5).allowsHitTesting(false)
            } else {
                HStack(spacing: 3) {
                    ForEach([1, 2, 3, 4, 5, 6], id: \.self) { index in
                        Circle().fill(scheme.ansiColor(index)).frame(width: 5, height: 5)
                    }
                }.padding(.leading, 7)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(0.1)))
    }
}

private struct ThemeTile: View {
    let card: ThemeCard
    let active: Bool
    let selected: Bool
    let installed: Bool
    let engineMissing: Bool
    let busy: Bool
    let open: () -> Void
    let use: () -> Void
    let tryOn: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topTrailing) {
                Button(action: open) { CardPreview(card: card).frame(height: 112) }
                    .buttonStyle(.plain).accessibilityLabel("Details for " + card.name)
                if active {
                    Label("In use", systemImage: "checkmark").font(.system(size: 10.5, weight: .semibold))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .foregroundStyle(Color.black.opacity(0.85)).background(Color.accentColor, in: Capsule())
                        .padding(8)
                } else if busy {
                    ProgressView().controlSize(.small).padding(10)
                } else if hovering {
                    HStack(spacing: 6) {
                        Button(action: tryOn) { Label("Try", systemImage: "eye") }
                        Button(installed ? "Use" : "Get", action: use).buttonStyle(.borderedProminent)
                    }
                    .controlSize(.small).padding(8)
                    .transition(.opacity)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(
                active || selected ? Color.accentColor.opacity(selected ? 1 : 0.7) : .white.opacity(0.08), lineWidth: active || selected ? 2 : 1))
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(card.name).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 4)
                if card.likes > 0 { Text("♥ \(card.likes)").font(.caption2).foregroundStyle(.secondary) }
            }
            HStack(spacing: 5) {
                badge(card.kindTitle)
                if let engine = card.promptTitle, card.kind != .scheme { badge(engine) }
                if engineMissing { badge("Needs install", warning: true) }
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    private func badge(_ text: String, warning: Bool = false) -> some View {
        Text(text).font(.system(size: 10.5, weight: .medium)).lineLimit(1)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .foregroundStyle(warning ? Color.orange : .secondary)
            .background((warning ? Color.orange : Color.white).opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
    }
}

private struct ThemeInspector: View {
    let card: ThemeCard
    let active: Bool
    let installed: Bool
    let engineMissing: Bool
    let pairs: [ThemeCard]
    let open: (ThemeCard) -> Void
    let close: () -> Void
    let use: () -> Void
    let tryOn: () -> Void
    let remove: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    MarketplaceEyebrow(card.kindTitle)
                    Spacer()
                    Button(action: close) { Image(systemName: "xmark") }.buttonStyle(.borderless).keyboardShortcut(.cancelAction)
                        .help("Close")
                }
                CardPreview(card: card, large: true).frame(height: 170).clipShape(RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 4) {
                    Text(card.name).font(.system(size: 20, weight: .bold))
                    if let summary = card.summary { Text(summary).font(.callout).foregroundStyle(.secondary) }
                }
                actions
                ForEach(card.bundle.map(ThemeStore.warnings(for:)) ?? [], id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout)
                }
                VStack(alignment: .leading, spacing: 8) {
                    info("Changes", includes)
                    if let author = card.author, !author.isEmpty { info("Author", author) }
                    if let license = card.license, !license.isEmpty { info("License", license) }
                    if engineMissing, let engine = card.engine { info("Requires", "\(engine.title), installed when you use it") }
                    if card.likes > 0 { info("Likes", "♥ \(card.likes)") }
                }
                if !pairs.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Goes well with").font(.system(size: 13, weight: .semibold))
                        ForEach(pairs) { other in
                            Button { open(other) } label: {
                                HStack(spacing: 10) {
                                    MiniPreview(card: other).frame(width: 52, height: 36)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(other.name).font(.callout).lineLimit(1)
                                        Text(other.kindTitle + (other.kind == .scheme ? "" : " · " + (other.promptTitle ?? "")))
                                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer(minLength: 0)
                                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                                }.contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }
                }
                links
            }.padding(MarketplaceMetrics.inspectorPadding)
        }
        .background(Color.white.opacity(0.025))
    }

    @ViewBuilder private var actions: some View {
        if active {
            Label("In use", systemImage: "checkmark.circle.fill").foregroundStyle(Color.accentColor).font(.callout.weight(.medium))
        } else {
            HStack(spacing: 8) {
                Button(action: use) {
                    Text(installed || card.kind == .prompt ? "Use" : "Get").frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent)
                Button(action: tryOn) { Label("Try", systemImage: "eye").frame(maxWidth: .infinity) }
            }.controlSize(.large)
        }
    }

    @ViewBuilder private var links: some View {
        let source = card.source.flatMap(URL.init(string:)).flatMap { $0.scheme == "https" ? $0 : nil }
        if source != nil || card.entry != nil || (installed && !active && card.kind != .prompt) {
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                if let source { Button("View Source") { NSWorkspace.shared.open(source) } }
                if card.entry != nil {
                    Button("Copy Link") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("bananashell://theme?id=" + card.id, forType: .string)
                    }
                    Button("Rate on GitHub") { rate() }
                }
                if installed && !active && card.kind != .prompt {
                    Button("Remove", role: .destructive, action: remove)
                }
            }.buttonStyle(.borderless).font(.callout)
        }
    }

    private var includes: String {
        switch card.kind {
        case .prompt: return "Prompt; terminals take its background"
        case .scheme: return "Terminal colors only; your prompt stays"
        case .bundle:
            var parts = ["Terminal colors"]
            if let prompt = card.promptTitle { parts.append(prompt.lowercased().contains("prompt") ? prompt.lowercased() : prompt + " prompt") }
            if card.accent != nil { parts.append("accent") }
            return parts.joined(separator: ", ")
        }
    }

    private func info(_ title: String, _ value: String) -> some View { MarketplaceInfoRow(title, value) }

    /// Ratings are reactions on the theme's catalog issue.
    private func rate() {
        var components = URLComponents(string: ThemeStore.repository + "/issues")!
        components.queryItems = [URLQueryItem(name: "q", value: "is:issue label:theme \"[theme] \(card.id)\" in:title")]
        if let url = components.url { NSWorkspace.shared.open(url) }
    }
}
