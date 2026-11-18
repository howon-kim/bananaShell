import AppKit
import SwiftUI

// MARK: - Items

/// One card in the marketplace: a zsh extension or a prompt engine.
private enum ExtensionItem: Hashable, Identifiable {
    case plugin(ShellPlugin)
    case engine(PromptEngine)

    var id: String {
        switch self {
        case .plugin(let plugin): return "plugin-" + plugin.id
        case .engine(let engine): return "engine-" + engine.rawValue
        }
    }

    /// “zsh-history-substring-search” → “History Substring Search”.
    var name: String {
        switch self {
        case .engine(let engine): return engine.title
        case .plugin(let plugin):
            let base = plugin.id.hasPrefix("zsh-") ? String(plugin.id.dropFirst(4)) : plugin.id
            return base.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        }
    }

    var identifier: String {
        switch self {
        case .plugin(let plugin): return plugin.id
        case .engine(let engine): return engine.rawValue
        }
    }

    var symbol: String {
        switch self {
        case .engine(.starship): return "sparkles"
        case .engine(.posh): return "chevron.right.square"
        case .plugin(let plugin):
            switch plugin.id {
            case ShellPlugin.suggestions.id: return "text.line.last.and.arrowtriangle.forward"
            case ShellPlugin.highlighting.id: return "highlighter"
            case ShellPlugin.corrections.id: return "arrow.uturn.backward.circle"
            case "zsh-autopair": return "parentheses"
            case "zsh-vi-mode": return "keyboard"
            case "zsh-history-substring-search": return "clock.arrow.circlepath"
            case "zsh-you-should-use": return "lightbulb"
            case "zsh-system-clipboard": return "doc.on.clipboard"
            default: return "puzzlepiece.extension"
            }
        }
    }

    var kindTitle: String {
        switch self {
        case .plugin: return "Shell extension"
        case .engine: return "Prompt engine"
        }
    }
}

// MARK: - Marketplace

struct ExtensionMarketplaceView: View {
    @ObservedObject private var catalog = PluginCatalog.shared

    fileprivate enum Section: String, CaseIterable {
        case discover = "Discover", installed = "Installed", updates = "Updates"
        var icon: String {
            switch self {
            case .discover: return "sparkles"
            case .installed: return "checkmark.circle"
            case .updates: return "arrow.down.circle"
            }
        }
    }

    @State private var section = Section.discover
    @State private var query = ""
    @State private var selection: ExtensionItem?
    @State private var removal: ShellPlugin?
    @State private var installingEngine: EngineInstall?
    @State private var installedEngines: Set<PromptEngine> = []

    private struct EngineInstall: Identifiable {
        let engine: PromptEngine
        var id: String { engine.rawValue }
    }

    private static let engines: [PromptEngine] = [.starship, .posh]
    private let initialSelection: String?

    /// `initialSelection` opens the inspector on an extension ID or a prompt engine's executable name.
    init(initialSelection: String? = nil) { self.initialSelection = initialSelection }

    private func refreshEngines() {
        let prefs = UserDefaults.standard
        installedEngines = Set(Self.engines.filter {
            PromptEngineTools().executable($0.rawValue, preferred: prefs.string(forKey: "enginePath." + $0.title)) != nil
        })
    }

    // MARK: State

    private func isInstalled(_ item: ExtensionItem) -> Bool {
        switch item {
        case .plugin(let plugin): return catalog.installed.contains(plugin)
        case .engine(let engine): return installedEngines.contains(engine)
        }
    }

    private func hasUpdate(_ plugin: ShellPlugin) -> Bool {
        guard catalog.installed.contains(plugin), let formula = catalog.formulae[plugin] else { return false }
        return !formula.isInstalled(in: catalog.pluginsDirectory.appendingPathComponent(plugin.id))
    }

    private var updates: [ShellPlugin] { catalog.results(matching: "", installedOnly: true).filter(hasUpdate) }

    private func plugins(for section: Section) -> [ShellPlugin] {
        let all = catalog.results(matching: query, installedOnly: section != .discover)
        let sorted = all.sorted { ExtensionItem.plugin($0).name.localizedStandardCompare(ExtensionItem.plugin($1).name) == .orderedAscending }
        return section == .updates ? sorted.filter(hasUpdate) : sorted
    }

    private func engines(for section: Section) -> [PromptEngine] {
        guard section != .updates else { return [] }
        return Self.engines.filter {
            (section == .discover || installedEngines.contains($0))
                && ExtensionIndex.matches(query, in: [$0.title, $0.rawValue, "Homebrew prompt engine"])
        }
    }

    // MARK: Body

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: MarketplaceMetrics.headerSpacing) {
                header
                ScrollView {
                    VStack(alignment: .leading, spacing: MarketplaceMetrics.contentSpacing) {
                        toolbar
                        notices
                        content
                    }
                    .padding(.bottom, MarketplaceMetrics.bottomPadding)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, MarketplaceMetrics.horizontalPadding).padding(.top, MarketplaceMetrics.topPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            if let item = selection {
                Divider()
                inspector(for: item)
                    .frame(width: MarketplaceMetrics.inspectorWidth)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.18), value: selection)
        .onAppear {
            refreshEngines()
            if let id = initialSelection {
                selection = PromptEngine(rawValue: id).map(ExtensionItem.engine) ?? .plugin(ShellPlugin(id: id))
            }
        }
        .task { await catalog.refresh(ifOlderThan: 86_400) }
        .alert("Remove " + (removal.map { ExtensionItem.plugin($0).name } ?? "extension") + "?",
               isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } }),
               presenting: removal) { plugin in
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) { Task { await catalog.uninstall(plugin) } }
        } message: { _ in
            Text("This deletes the installed copy from bananaShell. The change takes effect in new zsh tabs.")
        }
        .sheet(item: $installingEngine) { request in
            PromptEngineInstallView(engine: request.engine, theme: nil, tools: PromptEngineTools()) { binary in
                UserDefaults.standard.set(binary.path, forKey: "enginePath." + request.engine.title)
                installingEngine = nil
                refreshEngines()
            }
        }
    }

    private var header: some View {
        MarketplaceHeader(title: "Extensions", subtitle: "Zsh add-ons and prompt engines. Changes apply to new zsh tabs.") {
            Button { Task { await catalog.refresh() } } label: {
                if catalog.refreshing { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") }
            }
            .buttonStyle(MarketIconButtonStyle()).disabled(catalog.refreshing)
            .help("Refresh the Homebrew catalog").accessibilityLabel("Refresh Homebrew catalog")
        }
    }

    private var toolbar: some View {
        let pending = updates.count
        return HStack(spacing: 10) {
            MarketplaceTabBar {
                ForEach(Section.allCases, id: \.self) { item in
                    if item != .updates || pending > 0 || section == .updates {
                        MarketplaceTab(title: item.rawValue, icon: item.icon, selected: section == item,
                                       badge: item == .updates ? pending : nil) { section = item }
                    }
                }
            }
            Spacer(minLength: 8)
            MarketplaceSearchField(prompt: "Search extensions", text: $query)
        }
    }

    @ViewBuilder private var notices: some View {
        if let failure = catalog.failure {
            banner(failure, symbol: "exclamationmark.triangle.fill", tint: .orange)
        }
        if let note = catalog.catalogNote {
            banner(note, symbol: "wifi.exclamationmark", tint: .secondary)
        }
    }

    private func banner(_ text: String, symbol: String, tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(text).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.07)))
    }

    @ViewBuilder private var content: some View {
        let plugins = plugins(for: section)
        let engines = engines(for: section)
        if plugins.isEmpty && engines.isEmpty {
            emptyState
        } else {
            VStack(alignment: .leading, spacing: MarketplaceMetrics.shelfSpacing) {
            if !plugins.isEmpty {
                shelf(section == .updates ? "Updates available" : "Shell extensions",
                      subtitle: section == .updates ? "Newer releases from Homebrew."
                        : "Installed into bananaShell only, never into your Homebrew prefix.",
                      count: plugins.count, items: plugins.map(ExtensionItem.plugin))
            }
            if !engines.isEmpty {
                shelf("Prompt engines", subtitle: "Required by Starship and Oh My Posh themes.",
                      count: engines.count, items: engines.map(ExtensionItem.engine))
            }
            }
        }
    }

    private var emptyState: some View {
        MarketplaceEmptyState(
            symbol: catalog.refreshing ? "hourglass" : section == .installed && query.isEmpty ? "tray" : "magnifyingglass",
            message: catalog.refreshing ? "Searching the catalog…"
                : section == .updates ? "Everything is up to date."
                : section == .installed && query.isEmpty ? "Extensions you install appear here." : "No matching extensions.")
    }

    private func shelf(_ title: String, subtitle: String, count: Int, items: [ExtensionItem]) -> some View {
        VStack(alignment: .leading, spacing: MarketplaceMetrics.shelfHeaderSpacing) {
            MarketplaceShelfHeader(title: title, subtitle: subtitle) {
                Text("\(count)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 270), spacing: MarketplaceMetrics.gridColumnSpacing)],
                      spacing: MarketplaceMetrics.gridRowSpacing) {
                ForEach(items) { item in card(item) }
            }
        }
    }

    // MARK: Cards

    private func card(_ item: ExtensionItem) -> some View {
        let installed = isInstalled(item)
        return ExtensionCard(item: item, summary: summary(item), meta: meta(item), installed: installed,
                             selected: selection == item) {
            selection = selection == item ? nil : item
        } accessory: {
            accessory(for: item, compact: true)
        }
    }

    private func summary(_ item: ExtensionItem) -> String {
        switch item {
        case .plugin(let plugin): return catalog.formulae[plugin]?.desc ?? plugin.detail
        case .engine(let engine): return "Prompt engine for " + engine.title + " themes, installed with Homebrew."
        }
    }

    private func meta(_ item: ExtensionItem) -> [String] {
        switch item {
        case .engine: return ["Homebrew"]
        case .plugin(let plugin):
            guard let formula = catalog.formulae[plugin] else { return plugin == .corrections ? ["Bundled"] : ["Local copy"] }
            return ["v" + formula.versions.stable, formula.license]
        }
    }

    /// Install, update or enable controls. Cards show the compact form; the inspector shows the large one.
    @ViewBuilder private func accessory(for item: ExtensionItem, compact: Bool) -> some View {
        switch item {
        case .engine(let engine):
            if installedEngines.contains(engine) {
                statusLabel("Installed")
            } else {
                Button("Install") { installingEngine = EngineInstall(engine: engine) }
                    .buttonStyle(.borderedProminent).controlSize(compact ? .small : .large)
                    .accessibilityLabel("Install " + engine.title)
            }
        case .plugin(let plugin):
            if catalog.installed.contains(plugin) {
                HStack(spacing: 8) {
                    if hasUpdate(plugin) { installButton(plugin, updating: true, compact: compact) }
                    PluginSwitch(plugin: plugin).disabled(catalog.removing == plugin)
                }
            } else {
                installButton(plugin, updating: false, compact: compact)
            }
        }
    }

    private func statusLabel(_ text: String) -> some View {
        Label(text, systemImage: "checkmark.circle.fill").font(.caption.weight(.medium)).foregroundStyle(.secondary)
    }

    private func installButton(_ plugin: ShellPlugin, updating: Bool, compact: Bool) -> some View {
        let busy = catalog.installing == plugin.id
        return Button {
            Task { await catalog.install(plugin) }
        } label: {
            HStack(spacing: 6) {
                if busy { ProgressView().controlSize(.mini) }
                Text(updating ? (busy ? "Updating…" : "Update") : (busy ? "Installing…" : "Install"))
            }
            .frame(maxWidth: compact ? nil : .infinity)
        }
        .buttonStyle(.borderedProminent).controlSize(compact ? .small : .large)
        .disabled(catalog.changingInstallation)
        .accessibilityLabel((updating ? "Update " : "Install ") + plugin.id)
    }

    // MARK: Inspector

    private func inspector(for item: ExtensionItem) -> some View {
        let installed = isInstalled(item)
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    MarketplaceEyebrow(item.kindTitle)
                    Spacer()
                    Button { selection = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless).keyboardShortcut(.cancelAction).help("Close")
                }
                HStack(spacing: 12) {
                    ExtensionIcon(symbol: item.symbol, installed: installed, size: 52)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.name).font(.system(size: 20, weight: .bold)).lineLimit(2)
                        Text(item.identifier).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                Text(summary(item)).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                inspectorActions(item)
                if case .plugin(let plugin) = item {
                    ExtensionPreview(plugin: plugin, formula: catalog.formulae[plugin]).id(plugin)
                }
                VStack(alignment: .leading, spacing: 8) { details(item) }
                links(item)
            }
            .padding(MarketplaceMetrics.inspectorPadding)
        }
        .background(Color.white.opacity(0.025))
    }

    @ViewBuilder private func inspectorActions(_ item: ExtensionItem) -> some View {
        switch item {
        case .plugin(let plugin) where catalog.installed.contains(plugin):
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Enabled").font(.callout.weight(.medium))
                        Text("Loads in new zsh tabs.").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    PluginSwitch(plugin: plugin).disabled(catalog.removing == plugin)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                if hasUpdate(plugin) { installButton(plugin, updating: true, compact: false) }
            }
        case .plugin(let plugin):
            installButton(plugin, updating: false, compact: false)
        case .engine(let engine):
            if installedEngines.contains(engine) {
                Label("Installed", systemImage: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
                    .font(.callout.weight(.medium))
            } else {
                Button { installingEngine = EngineInstall(engine: engine) } label: {
                    Text("Install").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
            }
        }
    }

    @ViewBuilder private func details(_ item: ExtensionItem) -> some View {
        switch item {
        case .engine(let engine):
            info("Source", "Homebrew")
            info("Used by", engine.title + " themes")
            if let path = PromptEngineTools().executable(engine.rawValue,
                                                         preferred: UserDefaults.standard.string(forKey: "enginePath." + engine.title)) {
                info("Location", path.path)
            }
        case .plugin(let plugin):
            let formula = catalog.formulae[plugin]
            info("Source", formula == nil ? (plugin == .corrections ? "bananaShell" : "Installed copy") : "Homebrew")
            if let formula {
                info("Version", formula.versions.stable)
                info("License", formula.license)
                if let dependencies = formula.dependencies, !dependencies.isEmpty {
                    info("Requires", dependencies.joined(separator: ", "))
                }
            }
            if catalog.installed.contains(plugin) {
                info("Location", catalog.pluginsDirectory.appendingPathComponent(plugin.id).path)
            }
        }
    }

    @ViewBuilder private func links(_ item: ExtensionItem) -> some View {
        if case .plugin(let plugin) = item {
            let homepage = catalog.formulae[plugin]?.homepage
            let removable = catalog.installed.contains(plugin)
            if homepage != nil || removable {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    if let homepage { Button("View Project") { NSWorkspace.shared.open(homepage) } }
                    if removable {
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([catalog.pluginsDirectory.appendingPathComponent(plugin.id)])
                        }
                        Button("Remove", role: .destructive) { removal = plugin }
                            .foregroundStyle(.red)
                            .disabled(catalog.changingInstallation)
                            .accessibilityLabel("Remove " + plugin.id)
                    }
                }
                .buttonStyle(.borderless).font(.callout)
            }
        }
    }

    private func info(_ title: String, _ value: String) -> some View { MarketplaceInfoRow(title, value) }

    fileprivate struct PluginSwitch: View {
        let plugin: ShellPlugin
        @AppStorage var enabled: Bool
        init(plugin: ShellPlugin) {
            self.plugin = plugin
            _enabled = AppStorage(wrappedValue: false, "plugin." + plugin.id)
        }
        var body: some View {
            Toggle("Enabled", isOn: $enabled).toggleStyle(.switch).labelsHidden().controlSize(.small)
                .accessibilityLabel("Enable " + plugin.id)
        }
    }
}

// MARK: - Pieces

/// A rounded symbol tile; tinted with the accent once installed.
private struct ExtensionIcon: View {
    let symbol: String
    let installed: Bool
    var size: CGFloat = 40

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26)
            .fill(installed ? Color.accentColor.opacity(0.18) : Color.white.opacity(0.06))
            .overlay(RoundedRectangle(cornerRadius: size * 0.26)
                .strokeBorder(installed ? Color.accentColor.opacity(0.35) : .white.opacity(0.08)))
            .overlay(Image(systemName: symbol).font(.system(size: size * 0.42, weight: .medium))
                .foregroundStyle(installed ? Color.accentColor : .secondary))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

private struct ExtensionCard<Accessory: View>: View {
    let item: ExtensionItem
    let summary: String
    let meta: [String]
    let installed: Bool
    let selected: Bool
    let open: () -> Void
    @ViewBuilder let accessory: () -> Accessory
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                ExtensionIcon(symbol: item.symbol, installed: installed)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                    Text(item.identifier).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                if installed {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor).font(.system(size: 13))
                        .accessibilityLabel("Installed")
                }
            }
            Text(summary).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                .frame(maxWidth: .infinity, minHeight: 34, alignment: .topLeading)
            HStack(spacing: 5) {
                ForEach(meta, id: \.self) { badge($0) }
                Spacer(minLength: 6)
                accessory()
            }
            .frame(height: 24)
        }
        .padding(14)
        .background(Color.white.opacity(hovering || selected ? 0.06 : 0.035), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(
            selected ? Color.accentColor : .white.opacity(hovering ? 0.14 : 0.08), lineWidth: selected ? 2 : 1))
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onTapGesture(perform: open)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Show details", open)
    }

    private func badge(_ text: String) -> some View {
        Text(text).font(.system(size: 10.5, weight: .medium)).lineLimit(1)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .foregroundStyle(.secondary)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
    }
}
