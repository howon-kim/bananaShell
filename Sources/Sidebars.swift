import Combine
import SwiftUI
import AppKit

private enum ProgramLogos {
    static let images: [String: NSImage] = {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        var images: [String: NSImage] = [:]
        for url in bundle.urls(forResourcesWithExtension: "svg", subdirectory: "ProgramLogos") ?? [] {
            if let image = NSImage(contentsOf: url) {
                image.isTemplate = true
                images[url.deletingPathExtension().lastPathComponent] = image
            }
        }
        return images
    }()
}

enum ClaudeLimits {
    static func compactSummary(_ rows: [String]) -> String {
        rows.compactMap { row in
            guard let separator = row.range(of: ": ") else { return nil }
            let label = String(row[..<separator.lowerBound])
            let period = label == "5-hour" ? "5h" : label == "Weekly" ? "7d" : label
            let detail = row[separator.upperBound...]
            let remaining = detail.components(separatedBy: " · ").first { $0.hasSuffix("% left") }
            return period + " " + (remaining ?? "—")
        }.joined(separator: " · ")
    }


    static func rows(at file: URL, now: Date = Date()) -> [String] {
        guard let data = try? Data(contentsOf: file),
              let windows = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }
        return [("five_hour", "5-hour"), ("seven_day", "Weekly")].compactMap { key, label in
            guard let window = windows[key] as? [String: Any] else { return nil }
            func number(_ field: String) -> Double? {
                guard let value = window[field] as? NSNumber,
                      CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else { return nil }
                return value.doubleValue
            }
            var parts: [String] = []
            if let reset = number("resets_at"), reset > 0 {
                let remaining = reset - now.timeIntervalSince1970
                guard remaining > 0 else { return nil } // The snapshot describes an expired window.
                let formatter = DateComponentsFormatter()
                formatter.allowedUnits = remaining >= 86400 ? [.day, .hour] : [.hour, .minute]
                formatter.unitsStyle = .abbreviated
                if let duration = formatter.string(from: ceil(remaining / 60) * 60) {
                    parts.append("resets in " + duration)
                }
            }
            if let used = number("used_percentage"), (0...100).contains(used) {
                parts.insert((100 - used).formatted(.number.precision(.fractionLength(0...1))) + "% left", at: 0)
            }
            return parts.isEmpty ? nil : label + ": " + parts.joined(separator: " · ")
        }
    }
}

struct TabActivity: Identifiable, Equatable {
    let id: Int
    let shortcutSlot: Int
    let programIcon: String?
    let name: String
    let status: String
    let directory: String
    @ViewBuilder func icon(fallback: String, size: CGFloat) -> some View {
        if let programIcon, let image = ProgramLogos.images[programIcon] {
            Image(nsImage: image).renderingMode(.template).resizable().scaledToFit()
                .frame(width: size, height: size)
        } else {
            Image(systemName: programIcon == "network" || programIcon == "pencil" ? programIcon! : fallback)
        }
    }

    private var titlePath: Substring? {
        var path = name[...]
        if let colon = path.firstIndex(of: ":"), path[..<colon].contains("@") {
            path = path[path.index(after: colon)...]
        }
        guard path == "~" || path.hasPrefix("~/") || path.hasPrefix("/") else { return nil }
        return path
    }

    func titleLabel(weight: Font.Weight) -> Text {
        guard let path = titlePath else { return Text(verbatim: name).font(.system(size: 12, weight: weight)) }
        let component = path.split(separator: "/").last.map(String.init) ?? "/"
        return Text(verbatim: component).font(TabTypography.path(size: 12))
    }
    let busy: Bool
    let limits: [String]
}

enum NavigationModifier: String, CaseIterable {
    case control, option, command
    var symbol: String {
        switch self { case .control: return "⌃"; case .option: return "⌥"; case .command: return "⌘" }
    }
    var flags: NSEvent.ModifierFlags {
        switch self { case .control: return .control; case .option: return .option; case .command: return .command }
    }
}

enum ShortcutScope: String, CaseIterable {
    case group = "Group", page = "Page", terminal = "Terminal"
    var icon: String {
        switch self { case .group: return "folder"; case .page: return "rectangle.grid.2x2"; case .terminal: return "terminal" }
    }
}

final class NavigationKeys: ObservableObject {
    static let shared = NavigationKeys()
    private static let defaults: [ShortcutScope: NavigationModifier] = [.group: .control, .page: .option, .terminal: .command]
    private let storage: UserDefaults
    @Published private var assignments = defaults
    init(storage: UserDefaults = .standard) {
        self.storage = storage
        if let saved = storage.dictionary(forKey: "navigationModifiers") as? [String: String] {
            let pairs = ShortcutScope.allCases.compactMap { scope in
                saved[scope.rawValue].flatMap(NavigationModifier.init).map { (scope, $0) }
            }
            if Set(pairs.map { $0.1 }).count == ShortcutScope.allCases.count { assignments = Dictionary(uniqueKeysWithValues: pairs) }
        }
    }
    func modifier(_ scope: ShortcutScope) -> NavigationModifier { assignments[scope]! }
    func owner(_ modifier: NavigationModifier) -> ShortcutScope { assignments.first { $0.value == modifier }!.key }
    var isDefault: Bool { assignments == Self.defaults }
    func assign(_ modifier: NavigationModifier, to scope: ShortcutScope) {
        var next = assignments
        next[owner(modifier)] = assignments[scope]
        next[scope] = modifier
        save(next)
    }
    func reset() { save(Self.defaults) }
    private func save(_ next: [ShortcutScope: NavigationModifier]) {
        assignments = next
        storage.set(Dictionary(uniqueKeysWithValues: next.map { ($0.key.rawValue, $0.value.rawValue) }), forKey: "navigationModifiers")
        for item in NSApp?.mainMenu?.item(withTitle: "Shell")?.submenu?.items ?? [] where item.action == NSSelectorFromString("selectTab:") {
            item.keyEquivalentModifierMask = modifier(.terminal).flags
        }
    }
}

enum GridTabKind {
    case group, page

    var shortcutPrefix: String { NavigationKeys.shared.modifier(self == .group ? .group : .page).symbol }

    func shortcut(at index: Int) -> String? {
        (0..<10).contains(index) ? shortcutPrefix + String((index + 1) % 10) : nil
    }

    func hint(at index: Int) -> String {
        shortcut(at: index).map { " (" + $0 + ")" } ?? ""
    }
}

private struct TabShortcutLabel: View {
    let keys: String
    var body: some View {
        Text(verbatim: keys).font(TabTypography.suite(size: 11, relativeTo: .caption))
            .foregroundStyle(.secondary).fixedSize()
    }
}

enum GridTabTarget {
    case index(Int), step(Int)
}

final class WorkspaceState: ObservableObject {
    @Published var titleDirectory = ""
    @Published var tabColor = shellSurface
    let addAutomation = PassthroughSubject<Void, Never>()
    let generateKey = PassthroughSubject<Void, Never>()
    let importKey = PassthroughSubject<Void, Never>()
    let focusActivityTerminal = PassthroughSubject<Int, Never>()
    @Published var activityBoards = ActivityBoards()
    @Published var activityTerminal: Int?
    @Published var selected: WorkspaceTab = .keys
    @Published var tabs: [TabActivity] = []

    func navigate(_ kind: GridTabKind, to target: GridTabTarget) -> Bool {
        let groups = activityBoards.boards
        let board = activityBoards.current
        if kind == .page && (!selected.showsTerminals || board.pageCount < 2) { return false }
        let count = kind == .group ? groups.count : board.pageCount
        let index: Int
        switch target {
        case .index(let position): index = position
        case .step(let delta):
            let current = kind == .group ? (groups.firstIndex { $0.id == board.id } ?? 0) : board.page
            index = (current + delta + count) % count
        }
        guard (0..<count).contains(index) else { return false }
        activityTerminal = nil
        switch kind {
        case .group: activityBoards.select(groups[index].id)
        case .page: activityBoards.setPage(index)
        }
        return true
    }
}

enum WorkspaceTab: Hashable {
    case keys, activity, automations, settings, shell(Int)

    var showsTerminals: Bool {
        switch self {
        case .activity, .shell: return true
        default: return false
        }
    }
}

private struct ShellTabFramesKey: PreferenceKey {
    static let defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

private let sessionAccent = Color(red: 0.46, green: 0.87, blue: 0.76)

enum WorkspaceTabMetrics {
    static let height: CGFloat = 26
}

enum SurfaceRadius {
    static let control: CGFloat = 5
    static let tab: CGFloat = 7
    static let tile: CGFloat = 9
    static let panel: CGFloat = 12
}

private extension View {
    func tabFace(selected: Bool, cornerRadius: CGFloat = SurfaceRadius.tab) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return self
            .foregroundStyle(selected ? Color.white : Color(white: 0.70))
            .background(selected ? Color.white.opacity(0.12) : .clear, in: shape)
            .overlay(shape.strokeBorder(selected ? Color.white.opacity(0.11) : .clear)
                .allowsHitTesting(false))
    }
}

struct FavoriteTabs: View {
    @ObservedObject private var navigationKeys = NavigationKeys.shared
    @ObservedObject var state: WorkspaceState
    let select: (WorkspaceTab) -> Void
    private let badgeRadius = SurfaceRadius.tile

    private func tabBadge(_ icon: String, title: String?) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
            if let title { Text(verbatim: title).font(TabTypography.favoriteLabel).lineLimit(1) }
        }
        .padding(.horizontal, title == nil ? 0 : 8)
        .frame(minWidth: 30, maxWidth: title == nil ? 30 : 148)
        .frame(height: WorkspaceTabMetrics.height)
        .fixedSize(horizontal: true, vertical: false)
        .contentShape(Rectangle())
        .tabFace(selected: title != nil, cornerRadius: badgeRadius)
    }
    private func favorite(_ tab: WorkspaceTab, _ icon: String, _ label: String) -> some View {
        Button { select(tab) } label: {
            tabBadge(icon, title: state.selected == tab ? label : nil)
        }.buttonStyle(HoverButtonStyle(cornerRadius: badgeRadius))
         .help(label).accessibilityLabel(label)
         .accessibilityAddTraits(state.selected == tab ? .isSelected : [])
    }
    private var showsAppName: Bool {
        if case .shell = state.selected { return false }
        return true
    }
    @State private var renaming: ActivityBoard?

    private func showBoard(_ id: Int) {
        state.activityTerminal = nil
        state.activityBoards.select(id)
        select(.activity)
    }

    var body: some View {
        GeometryReader { geometry in
            let showName = geometry.size.width >= 490 && showsAppName
            let showDirectory = geometry.size.width >= 680 && !state.titleDirectory.isEmpty
            HStack(spacing: 5) {
                if showName || showDirectory {
                    if showName { Text("bananaShell").font(Font(terminalFont(size: NSFont.systemFontSize))) }
                    if showDirectory {
                        Text(verbatim: state.titleDirectory).font(TabTypography.path(size: NSFont.systemFontSize)).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle).frame(maxWidth: 160, alignment: .leading)
                            .help(state.titleDirectory)
                    }
                }
                primaryRow.padding(.leading, showName || showDirectory ? 5 : 0)
            }.frame(maxHeight: .infinity)
        }
        .buttonStyle(HoverButtonStyle())
        .sheet(item: $renaming) { board in
            RenameBoardSheet(board: board) { name in state.activityBoards.rename(board.id, to: name) }
        }
    }

    private func closeBoard(_ id: Int) {
        let active = state.activityBoards.selected == id
        state.activityBoards.close(id)
        if active && state.selected.showsTerminals { showBoard(state.activityBoards.selected) }
    }

    private var primaryRow: some View {
        HStack(spacing: 5) {
            favorite(.keys, "key", "SSH Keys")
            favorite(.automations, "clock.arrow.circlepath", "Automations").padding(.trailing, 5)
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(Array(state.activityBoards.boards.enumerated()), id: \.element.id) { index, board in
                            let selected = state.selected.showsTerminals && state.activityBoards.selected == board.id
                            HStack(spacing: 0) {
                                HStack(spacing: 5) {
                                    Text(verbatim: board.title).font(TabTypography.favoriteLabel).lineLimit(1)
                                    if let keys = GridTabKind.group.shortcut(at: index) { TabShortcutLabel(keys: keys) }
                                }
                                    .padding(.leading, 10).padding(.trailing, 4).frame(maxWidth: 200).frame(height: WorkspaceTabMetrics.height)
                                    .fixedSize(horizontal: true, vertical: false)
                                    .contentShape(Rectangle())
                                    .gesture(TapGesture(count: 2).exclusively(before: TapGesture()).onEnded { tap in
                                        switch tap {
                                        case .first: renaming = board
                                        case .second: showBoard(board.id)
                                        }
                                    })
                                    .help(board.title + GridTabKind.group.hint(at: index) + " · Double-click to rename")
                                    .accessibilityAddTraits(.isButton)
                                    .accessibilityAddTraits(selected ? .isSelected : [])
                                    .accessibilityAction { showBoard(board.id) }
                                Button { closeBoard(board.id) } label: {
                                    TabActionIcon()
                                }.buttonStyle(.plain)
                                .opacity(state.activityBoards.boards.count == 1 ? 0.4 : 1)
                                .disabled(state.activityBoards.boards.count == 1)
                                .help(state.activityBoards.boards.count == 1 ? "Keep one group open" : "Close group and move its terminals to the adjacent group")
                                .accessibilityLabel("Close group " + board.title)
                            }
                            .tabFace(selected: selected)
                            .modifier(ControlHover(cornerRadius: SurfaceRadius.tab))
                            .contextMenu {
                                Button("Rename Group…") { renaming = board }
                                Button("Close Group") { closeBoard(board.id) }.disabled(state.activityBoards.boards.count == 1)
                            }.id(board.id)
                        }
                    }
                }.onChange(of: state.activityBoards.selected) { proxy.scrollTo($0) }
            }
            if state.selected == .keys {
                Menu {
                    Button("Generate New Key…") { state.generateKey.send() }
                    Button("Import Public Key…") { state.importKey.send() }
                } label: { Image(systemName: "plus").frame(width: 30, height: WorkspaceTabMetrics.height) }
                    .menuIndicator(.hidden).menuStyle(.borderlessButton).fixedSize().modifier(ControlHover())
                    .help("Add SSH key").accessibilityLabel("Add SSH key")
            } else {
                let automation = state.selected == .automations
                Button { if automation { state.addAutomation.send() } else { state.activityBoards.add(); showBoard(state.activityBoards.selected) } } label: {
                    Image(systemName: "plus").frame(width: 30, height: WorkspaceTabMetrics.height)
                }.help(automation ? "Add Automation" : "New group tab")
                 .accessibilityLabel(automation ? "Add Automation" : "New group tab")
            }
            favorite(.settings, "gearshape", "Settings").padding(.trailing, 3)
        }
    }

}

private struct GridLayoutIcon: Shape {
    let columns: Int

    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let gap: CGFloat = columns == 1 ? 0 : 1.5
        let cell = (side - gap * CGFloat(columns - 1)) / CGFloat(columns)
        let origin = CGPoint(x: rect.midX - side / 2, y: rect.midY - side / 2)
        var path = Path()
        for row in 0..<columns {
            for column in 0..<columns {
                let tile = CGRect(x: origin.x + CGFloat(column) * (cell + gap),
                                  y: origin.y + CGFloat(row) * (cell + gap), width: cell, height: cell)
                path.addRoundedRect(in: tile, cornerSize: CGSize(width: min(1.5, cell * 0.22), height: min(1.5, cell * 0.22)))
            }
        }
        return path
    }
}

struct TerminalToolbar: View {
    @ObservedObject private var navigationKeys = NavigationKeys.shared
    @ObservedObject var state: WorkspaceState
    let select: (WorkspaceTab) -> Void
    let create: () -> Void
    let close: (Int) -> Void
    let move: (Int, Int) -> Void

    var body: some View {
        if state.selected.showsTerminals {
            terminalRow.buttonStyle(HoverButtonStyle()).background(Color(nsColor: state.tabColor))
        }
    }

    private var board: ActivityBoard { state.activityBoards.current }

    private var terminalRow: some View {
        HStack(spacing: 6) {
            TerminalTabStrip(state: state, select: select, close: close, move: move)
            let others = state.tabs.filter { !board.slots.contains($0.shortcutSlot) }
            if !others.isEmpty {
                Menu {
                    ForEach(others) { tab in
                        Button(tab.name + ShellTabShortcuts.hint(at: tab.shortcutSlot)) {
                            select(.activity)
                            state.activityBoards.move(tab.shortcutSlot, to: board.id)
                            state.activityTerminal = tab.id
                        }
                    }
                } label: { Image(systemName: "arrow.down.to.line") }
                    .menuStyle(.borderlessButton).fixedSize().modifier(ControlHover()).help("Move a running terminal here")
                    .accessibilityLabel("Move terminal here")
            }
            Button(action: create) { Image(systemName: "plus").frame(width: 24, height: 26) }
                .help("New terminal").accessibilityLabel("New terminal")
            if state.selected == .activity {
                HStack(spacing: 2) {
                    ForEach(ActivityGrid.allCases, id: \.self) { grid in
                        let selected = grid == board.grid
                        Button {
                            let slot = state.tabs.first { $0.id == state.activityTerminal }?.shortcutSlot
                            state.activityBoards.setGrid(grid, keeping: slot)
                        } label: {
                            HStack(spacing: 5) {
                                GridLayoutIcon(columns: grid.rawValue).frame(width: 14, height: 14)
                                    .accessibilityHidden(true)
                                Text(grid.label).font(TabTypography.suite(size: 12, relativeTo: .callout))
                            }.frame(maxWidth: .infinity).frame(height: 22)
                                .foregroundStyle(selected ? Color.black.opacity(0.86) : .primary)
                                .background(selected ? sessionAccent : .clear, in: RoundedRectangle(cornerRadius: SurfaceRadius.control))
                                .contentShape(Rectangle())
                        }
                        .help("Show \(grid.capacity) \(grid == .single ? "terminal" : "terminals")")
                        .accessibilityLabel("Show \(grid.capacity) \(grid == .single ? "terminal" : "terminals")")
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }.padding(2).frame(width: 148)
                 .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: SurfaceRadius.tab))
            }
        }.padding(.horizontal, 10).frame(height: 36)
    }
}

private struct RenameBoardSheet: View {
    let board: ActivityBoard
    let save: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @FocusState private var focused: Bool

    init(board: ActivityBoard, save: @escaping (String) -> Void) {
        self.board = board
        self.save = save
        _name = State(initialValue: board.title)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename Group").font(.headline)
            TextField("Group name", text: $name).focused($focused)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Rename") { save(name); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(20).frame(width: 300).onAppear { focused = true }
    }
}

private struct TerminalTabStrip: View {
    @ObservedObject private var navigationKeys = NavigationKeys.shared
    private enum Anchor: Hashable { case page(group: Int, index: Int), terminal(Int) }

    private enum TabFocus: Hashable { case title(Anchor), close(Anchor) }
    @FocusState private var focus: TabFocus?
    @State private var hoveredPageGroup: Anchor?
    @State private var hovered: Anchor?

    private func revealsClose(_ item: Anchor) -> Bool {
        hovered == item || focus == .title(item) || focus == .close(item)
    }

    private func track(_ item: Anchor, inside: Bool) {
        if inside { hovered = item } else if hovered == item { hovered = nil }
    }

    private var showsPageGroups: Bool {
        let board = state.activityBoards.current
        return board.grid != .single && board.pageCount > 1
    }

    private var scrollAnchor: Anchor? {
        let board = state.activityBoards.current
        if case .shell(let id) = state.selected { return .terminal(id) }
        if showsPageGroups { return .page(group: board.id, index: board.page) }
        if board.grid == .single, let slot = board.visibleSlots.first,
           let tab = state.tabs.first(where: { $0.shortcutSlot == slot }) { return .terminal(tab.id) }
        return nil
    }

    @ObservedObject var state: WorkspaceState
    let select: (WorkspaceTab) -> Void
    let close: (Int) -> Void
    let move: (Int, Int) -> Void
    @State private var dropTarget: Int?
    @State private var tabFrames: [Int: CGRect] = [:]
    @GestureState private var draggedTab: Int?

    private func dragTarget(at point: CGPoint) -> Int? {
        guard let row = tabFrames.values.first,
              (row.minY - 14 ... row.maxY + 14).contains(point.y) else { return nil }
        return tabFrames.min { abs($0.value.midX - point.x) < abs($1.value.midX - point.x) }?.key
    }
    private struct PageClosure {
        let number: Int
        let sessionIDs: [Int]
    }
    @State private var pendingClosure: PageClosure?

    private func pageTab(_ page: Int, board: ActivityBoard) -> some View {
        let active = page == board.page
        let item = Anchor.page(group: board.id, index: page)
        return HStack(spacing: 0) {
            Button {
                if state.navigate(.page, to: .index(page)) { select(.activity) }
            } label: {
                HStack(spacing: 6) {
                    Capsule().fill(active ? sessionAccent : Color.secondary.opacity(0.55))
                        .frame(width: 3, height: active ? 14 : 8)
                    Text("Page \(page + 1)").font(TabTypography.favoriteLabel).monospacedDigit()
                    if let shortcut = GridTabKind.page.shortcut(at: page) {
                        TabShortcutLabel(keys: shortcut)
                    }
                }
                .fixedSize().padding(.leading, 10).padding(.trailing, 4).frame(height: WorkspaceTabMetrics.height)
                .foregroundStyle(active ? sessionAccent : Color.primary.opacity(0.8))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focused($focus, equals: .title(item))
            .help("Page \(page + 1) of \(board.pageCount)" + GridTabKind.page.hint(at: page))
            .accessibilityLabel("Page \(page + 1) of \(board.pageCount)")
            .accessibilityAddTraits(active ? .isSelected : [])

            Button {
                let slots = Set(board.slots(on: page))
                let ids = state.tabs.filter { slots.contains($0.shortcutSlot) }.map(\.id)
                if !ids.isEmpty { pendingClosure = PageClosure(number: page + 1, sessionIDs: ids) }
            } label: {
                TabActionIcon().opacity(revealsClose(item) ? 1 : 0)
            }.buttonStyle(.plain)
            .focused($focus, equals: .close(item))
            .allowsHitTesting(revealsClose(item))
            .help("Close page and its terminals")
            .accessibilityLabel("Close page \(page + 1)")
        }
        .contentShape(Rectangle())
        .onHover { track(item, inside: $0) }
        .overlay(alignment: .trailing) {
            Rectangle().fill(Color.primary.opacity(0.16)).frame(width: 1, height: 16)
        }
    }

    private func terminalTab(_ tab: TabActivity) -> some View {
        let board = state.activityBoards.current
        let item = Anchor.terminal(tab.id)
        let visibleSingle = board.grid == .single && board.visibleSlots.first == tab.shortcutSlot
        let selected = state.selected == .shell(tab.id) || (state.selected == .activity && (state.activityTerminal == tab.id || visibleSingle))
        return HStack(spacing: 0) {
            Button { select(.shell(tab.id)) } label: {
                HStack(spacing: 6) {
                    tab.icon(fallback: "terminal.fill", size: 16)
                        .font(.system(size: 12))
                        .foregroundStyle(selected ? sessionAccent : Color.secondary)
                        .accessibilityHidden(true)
                    tab.titleLabel(weight: .medium)
                        .frame(maxWidth: 150, alignment: .leading)
                        .fixedSize(horizontal: true, vertical: false)
                    if ShellTabShortcuts.keys.indices.contains(tab.shortcutSlot) {
                        TabShortcutLabel(keys: navigationKeys.modifier(.terminal).symbol + ShellTabShortcuts.keys[tab.shortcutSlot]).opacity(0.8)
                    }
                }
                .lineLimit(1).padding(.leading, 8).padding(.trailing, 2).frame(height: WorkspaceTabMetrics.height)
                .contentShape(Rectangle())
            }.buttonStyle(.plain)
                .focused($focus, equals: .title(item))
                .simultaneousGesture(DragGesture(minimumDistance: 4, coordinateSpace: .named("shellTabs"))
                    .updating($draggedTab) { _, dragged, _ in dragged = tab.id }
                    .onChanged { dropTarget = dragTarget(at: $0.location) }
                    .onEnded { value in
                        if let target = dragTarget(at: value.location) {
                            withAnimation(.easeInOut(duration: 0.15)) { move(tab.id, target) }
                        }
                    })
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { select(.shell(tab.id)) }
                .help(tab.name + ShellTabShortcuts.hint(at: tab.shortcutSlot))
             .accessibilityAddTraits(selected ? .isSelected : [])
            Button { close(tab.id) } label: { TabActionIcon(width: 26).opacity(revealsClose(item) ? 1 : 0) }.buttonStyle(.plain)
                .focused($focus, equals: .close(item))
                .allowsHitTesting(revealsClose(item))
                .help("Close tab").accessibilityLabel("Close tab")
        }.tabFace(selected: selected)
         .onHover { track(item, inside: $0) }
         .modifier(ControlHover(cornerRadius: SurfaceRadius.tab))
         .background(GeometryReader { geometry in
             Color.clear.preference(key: ShellTabFramesKey.self,
                                    value: [tab.id: geometry.frame(in: .named("shellTabs"))])
         })
         .opacity(draggedTab == tab.id ? 0.65 : 1)
         .overlay(RoundedRectangle(cornerRadius: SurfaceRadius.tab).strokeBorder(
            draggedTab != nil && draggedTab != tab.id && dropTarget == tab.id
                ? sessionAccent : .clear, lineWidth: 1.5)
            .allowsHitTesting(false))
         .id(Anchor.terminal(tab.id))
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: showsPageGroups ? 12 : 4) {
                    let board = state.activityBoards.current
                    ForEach(0..<board.pageCount, id: \.self) { page in
                        let grouped = showsPageGroups
                        let group = Anchor.page(group: board.id, index: page)
                        HStack(spacing: 0) {
                            if grouped {
                                pageTab(page, board: board)
                                    .id(Anchor.page(group: board.id, index: page))
                            }
                            HStack(spacing: 4) {
                                ForEach(board.slots(on: page), id: \.self) { slot in
                                    if let tab = state.tabs.first(where: { $0.shortcutSlot == slot }) { terminalTab(tab) }
                                }
                            }
                            .padding(.leading, grouped ? 8 : 0)
                        }
                        .background(grouped && hoveredPageGroup == group ? sessionAccent.opacity(0.09) : .clear,
                                    in: RoundedRectangle(cornerRadius: SurfaceRadius.tab))
                        .contentShape(Rectangle())
                        .onHover { inside in
                            if inside && grouped { hoveredPageGroup = group }
                            else if hoveredPageGroup == group { hoveredPageGroup = nil }
                        }

                    }
                }.coordinateSpace(name: "shellTabs")
                 .onPreferenceChange(ShellTabFramesKey.self) { tabFrames = $0 }
            }.frame(minWidth: 80)
             .onAppear { if let anchor = scrollAnchor { proxy.scrollTo(anchor) } }
             .onChange(of: scrollAnchor) { if let anchor = $0 { proxy.scrollTo(anchor) } }
        }
        .alert("Close Page \(pendingClosure?.number ?? 1)?",
               isPresented: Binding(get: { pendingClosure != nil }, set: { if !$0 { pendingClosure = nil } }),
               presenting: pendingClosure) { request in
            Button("Cancel", role: .cancel) {}
            Button("Close Page", role: .destructive) { request.sessionIDs.forEach(close) }
        } message: { request in
            Text("Terminals to close: \(request.sessionIDs.count). Running processes in these terminals will stop.")
        }
    }
}

struct ActivityPanel: View {
    @ObservedObject private var navigationKeys = NavigationKeys.shared
    @ObservedObject var state: WorkspaceState
    let terminalView: (Int) -> NSView?
    let close: (Int) -> Void
    let create: () -> Void
    let releaseFocus: () -> Void
    let expand: (Int) -> Void

    private var board: ActivityBoard { state.activityBoards.current }

    private func blur() {
        state.activityTerminal = nil
        releaseFocus()
    }

    private func toggleFocus(_ tab: TabActivity) {
        if state.activityTerminal == tab.id { blur() }
        else {
            state.activityBoards.reveal(tab.shortcutSlot)
            state.activityTerminal = tab.id
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            if board.slots.isEmpty {
                VStack(spacing: 8) {
                    Text("No terminals in this tab").foregroundStyle(.secondary)
                    Button("New Terminal", action: create)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { geometry in
                    let layout = ActivityTileLayout(viewport: geometry.size, grid: board.grid)
                    let gap = ActivityTileLayout.gap
                    ScrollView(.vertical) {
                        LazyVGrid(columns: Array(repeating: GridItem(.fixed(layout.cardSize.width), spacing: gap), count: board.grid.rawValue), spacing: gap) {
                            ForEach(Array(board.visibleSlots), id: \.self) { slot in
                                if let tab = state.tabs.first(where: { $0.shortcutSlot == slot }) {
                                    card(tab, layout: layout).frame(width: layout.cardSize.width, height: layout.cardSize.height).clipped()
                                }
                            }
                        }
                    }.padding(ActivityTileLayout.outerInset)
                }
            }
        }
        .onReceive(state.focusActivityTerminal) { id in
            guard state.selected == .activity, let tab = state.tabs.first(where: { $0.id == id }) else { return }
            toggleFocus(tab)
        }
    }

    @ViewBuilder
    private func cardTitle(_ tab: TabActivity, width: CGFloat) -> some View {
        let usage = ClaudeLimits.compactSummary(tab.limits)
        let details = ([tab.name, tab.directory, tab.status] + tab.limits).filter { !$0.isEmpty }.joined(separator: "\n")
        let label = HStack(spacing: 5) {
            if width >= 170 {
                tab.icon(fallback: "terminal", size: 14)
                    .foregroundStyle(tab.busy ? sessionAccent : .secondary)
            }
            tab.titleLabel(weight: .semibold).lineLimit(1)
            if width >= 390 {
                Text(verbatim: tab.directory).font(TabTypography.path(size: NSFont.preferredFont(forTextStyle: .caption1).pointSize)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
            if width >= 245 && (!usage.isEmpty || (width >= 390 && !tab.status.isEmpty)) {
                Text(usage.isEmpty ? tab.status : usage).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if width >= 150, ShellTabShortcuts.keys.indices.contains(tab.shortcutSlot) {
                TabShortcutLabel(keys: navigationKeys.modifier(.terminal).symbol + ShellTabShortcuts.keys[tab.shortcutSlot])
            }
        }.frame(height: ActivityTileLayout.header).contentShape(Rectangle())

        if board.grid == .single {
            Button { toggleFocus(tab) } label: { label }.buttonStyle(.plain).help(details)
        } else {
            label.overlay {
                TerminalTitleClickArea(single: { toggleFocus(tab) }, double: { expand(tab.id) })
                    .accessibilityHidden(true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { toggleFocus(tab) }
            .accessibilityAction(named: Text("Expand terminal")) { expand(tab.id) }
            .help(details + "\nDouble-click to expand terminal")
        }
    }

    private func card(_ tab: TabActivity, layout: ActivityTileLayout) -> some View {
        let width = layout.cardSize.width
        let focused = state.activityTerminal == tab.id
        return VStack(spacing: 0) {
            HStack(spacing: 4) {
                cardTitle(tab, width: width)
                Button { expand(tab.id) } label: {
                    TabActionIcon(symbol: "arrow.up.left.and.arrow.down.right", width: 20, height: 22, font: .caption)
                }.buttonStyle(.plain).help("Expand terminal").accessibilityLabel("Expand " + tab.name)
                Button { close(tab.id) } label: {
                    TabActionIcon(width: 20, height: 22, font: .caption)
                }.buttonStyle(.plain).help("Close terminal").accessibilityLabel("Close " + tab.name)
            }.padding(.horizontal, 6).frame(height: ActivityTileLayout.header)
             .background(.white.opacity(0.055))
             .modifier(ControlHover(cornerRadius: 0))
             .contextMenu {
                 ForEach(state.activityBoards.boards.filter { $0.id != board.id }) { target in
                     Button("Move to " + target.title) {
                         if focused { blur() }
                         state.activityBoards.move(tab.shortcutSlot, to: target.id)
                     }
                 }
             }

            if state.selected == .activity, let terminal = terminalView(tab.id) {
                ActivityTerminal(terminal: terminal, size: layout.terminalSize, isVisible: {
                    state.selected == .activity && state.activityBoards.current.visibleSlots.contains(tab.shortcutSlot)
                }, wantsFocus: {
                    state.selected == .activity && state.activityTerminal == tab.id
                }).padding([.horizontal, .bottom], ActivityTileLayout.inset)
            } else { Spacer() }
        }.background(Color(nsColor: state.tabColor))
         .clipShape(RoundedRectangle(cornerRadius: SurfaceRadius.tile))
         .overlay(RoundedRectangle(cornerRadius: SurfaceRadius.tile).strokeBorder(focused ? sessionAccent : .white.opacity(0.14)).allowsHitTesting(false))
    }
}

// AppKit supplies the user's system double-click interval and click count.
private struct TerminalTitleClickArea: NSViewRepresentable {
    let single: () -> Void
    let double: () -> Void

    final class HitArea: NSView {
        var click: ((Int) -> Void)?
        override func mouseDown(with event: NSEvent) { click?(event.clickCount) }
        override var mouseDownCanMoveWindow: Bool { false }
    }

    func makeNSView(context: Context) -> HitArea { HitArea() }
    func updateNSView(_ view: HitArea, context: Context) {
        view.click = { count in
            if count == 2 { double() }
            else if count == 1 { single() }
        }
    }
}

/// Borrow the existing terminal view so input, scrollback and the PTY stay in the same session.
private struct ActivityTerminal: NSViewRepresentable {
    let terminal: NSView
    let size: CGSize
    let isVisible: () -> Bool
    let wantsFocus: () -> Bool

    final class Container: NSView {
        private var terminal: NSView?
        private var requestedFocus = false
        private var pendingFocus: (() -> Bool)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            focusWhenAttached()
        }

        func attach(_ view: NSView, size: CGSize, isVisible: @escaping () -> Bool, wantsFocus: @escaping () -> Bool) {
            guard isVisible() else { detach(); return }
            let attaching = view.superview !== self
            if attaching {
                detach()
                terminal = view
                view.removeFromSuperview()
                view.autoresizingMask = []
                addSubview(view)
            }
            // SwiftUI may first mount this container with empty bounds. Only
            // resize the borrowed terminal to the measured tile, never a probe size.
            let frame = CGRect(origin: .zero, size: size)
            if view.frame != frame { view.frame = frame }
            guard wantsFocus() else {
                requestedFocus = false
                pendingFocus = nil
                return
            }
            guard attaching || !requestedFocus else { return }
            requestedFocus = true
            pendingFocus = wantsFocus
            focusWhenAttached()
        }

        private func focusWhenAttached() {
            DispatchQueue.main.async { [weak self] in
                guard let self, let requested = self.pendingFocus else { return }
                guard requested(), let terminal = self.terminal, terminal.superview === self else {
                    self.pendingFocus = nil
                    return
                }
                guard let window = self.window else { return }
                if window.makeFirstResponder(terminal) { self.pendingFocus = nil }
            }
        }

        func detach() {
            // Tab navigation may already have moved the view to the main content area.
            if let terminal, terminal.superview === self {
                if let responder = window?.firstResponder as? NSView,
                   responder === terminal || responder.isDescendant(of: terminal) {
                    window?.makeFirstResponder(nil)
                }
                terminal.removeFromSuperview()
            }
            terminal = nil
            requestedFocus = false
            pendingFocus = nil
        }
    }

    func makeNSView(context: Context) -> Container {
        let container = Container()
        container.attach(terminal, size: size, isVisible: isVisible, wantsFocus: wantsFocus)
        return container
    }
    func updateNSView(_ view: Container, context: Context) { view.attach(terminal, size: size, isVisible: isVisible, wantsFocus: wantsFocus) }
    static func dismantleNSView(_ view: Container, coordinator: ()) { view.detach() }
}

private struct TabActionIcon: View {
    var symbol = "xmark"
    var width: CGFloat = 22
    var height: CGFloat = WorkspaceTabMetrics.height
    var font: Font = .caption2
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovered = false

    var body: some View {
        Image(systemName: symbol)
            .font(font)
            .frame(width: 18, height: 18)
            .background {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.primary.opacity(hovered && isEnabled ? 0.36 : 0))
            }
            .frame(width: width, height: height)
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
    }
}

private struct ControlHover: ViewModifier {
    var cornerRadius: CGFloat = SurfaceRadius.control
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovered = false

    func body(content: Content) -> some View {
        content.contentShape(Rectangle())
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.primary.opacity(hovered && isEnabled ? 0.13 : 0))
                    .allowsHitTesting(false)
            }
            .onHover { hovered = $0 }
    }
}

struct HoverButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = SurfaceRadius.control

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .modifier(ControlHover(cornerRadius: cornerRadius))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
