import Combine
import SwiftUI
import AppKit
import QuartzCore

private enum ProgramLogos {
    private final class CachedImage {
        let image: NSImage?
        init(_ image: NSImage?) { self.image = image }
    }
    private static let cache: NSCache<NSString, CachedImage> = {
        let cache = NSCache<NSString, CachedImage>()
        cache.countLimit = 64
        return cache
    }()
    private static let bundle: Bundle = {
        #if SWIFT_PACKAGE
        return Bundle.module
        #else
        return Bundle.main
        #endif
    }()

    static func image(named name: String) -> NSImage? {
        let key = name as NSString
        if let cached = cache.object(forKey: key) { return cached.image }
        // Load only icons the UI uses, and cache missing names for SF Symbol
        // fallbacks. NSCache can release decoded images under memory pressure.
        let image = bundle.url(forResource: name, withExtension: "svg", subdirectory: "ProgramLogos")
            .flatMap { NSImage(contentsOf: $0) }
        image?.isTemplate = true
        cache.setObject(CachedImage(image), forKey: key)
        return image
    }
}

enum ClaudeLimits {
    static func summary(_ rows: [String]) -> String {
        rows.compactMap { row in
            guard let separator = row.range(of: ": ") else { return nil }
            let label = String(row[..<separator.lowerBound])
            let period = label == "5-hour" ? "5h" : label == "Weekly" ? "7d" : label
            let detail = row[separator.upperBound...]
            let parts = detail.components(separatedBy: " · ")
            let remaining = parts.first { $0.hasSuffix("% left") }
            let reset = parts.first { $0.hasPrefix("resets in ") }
            return period + " " + (remaining ?? "—") + (reset.map { " (" + $0 + ")" } ?? "")
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
                var calendar = Calendar(identifier: .gregorian)
                calendar.locale = Locale(identifier: "en_US_POSIX")
                formatter.calendar = calendar
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
        if let programIcon, let image = ProgramLogos.image(named: programIcon) {
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
    let id = UUID()
    @Published var titleDirectory = ""
    @Published var tabColor = shellSurface
    let addAutomation = PassthroughSubject<Void, Never>()
    let openAutomation = CurrentValueSubject<UUID?, Never>(nil)
    let generateKey = PassthroughSubject<Void, Never>()
    let importKey = PassthroughSubject<Void, Never>()
    let addAPIKey = PassthroughSubject<Void, Never>()
    let focusActivityTerminal = PassthroughSubject<Int, Never>()
    @Published var activityBoards = ActivityBoards() {
        didSet {
            // A one-terminal layout puts every terminal on its own page, so number
            // the whole group; otherwise numbers follow the current page.
            let board = activityBoards.current
            visibleTerminalSlots = board.grid == .single ? board.slots : Array(board.visibleSlots)
            terminalPositions = Dictionary(visibleTerminalSlots.enumerated().map { ($0.element, $0.offset) },
                                           uniquingKeysWith: { first, _ in first })
        }
    }
    @Published var activityTerminal: Int?
    @Published var selected: WorkspaceTab = .keys
    @Published var tabs: [TabActivity] = [] {
        didSet {
            tabsBySlot = Dictionary(tabs.map { ($0.shortcutSlot, $0) }, uniquingKeysWith: { first, _ in first })
            tabsByID = Dictionary(tabs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        }
    }
    private var tabsBySlot: [Int: TabActivity] = [:]
    private var tabsByID: [Int: TabActivity] = [:]
    private var visibleTerminalSlots: [Int] = []
    private var terminalPositions: [Int: Int] = [:]
    func tab(slot: Int) -> TabActivity? { tabsBySlot[slot] }
    func tab(id: Int) -> TabActivity? { tabsByID[id] }

    // Stored slots identify sessions; keyboard numbers identify positions in
    // the current page (the whole group in the one-terminal layout). Both
    // dispatch and visible key hints use this mapping.
    func terminal(at position: Int) -> TabActivity? {
        guard visibleTerminalSlots.indices.contains(position) else { return nil }
        return tab(slot: visibleTerminalSlots[position])
    }
    func terminalShortcutIndex(for slot: Int) -> Int? { terminalPositions[slot] }

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

private let sessionAccent = Color.accentColor

enum WorkspaceTabMetrics {
    static let height: CGFloat = 26
}

enum SurfaceRadius {
    static let control: CGFloat = 5
    static let tab: CGFloat = 7
    static let tile: CGFloat = 9
    static let panel: CGFloat = 12
}

private enum TabMotion {
    static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    static var lift: Animation? { reduced ? nil : .easeOut(duration: 0.12) }
    static var hover: Animation? { reduced ? nil : .easeOut(duration: 0.14) }
    static var settle: Animation? { reduced ? nil : .spring(response: 0.28, dampingFraction: 0.90) }
    static var insertion: AnyTransition {
        reduced ? .opacity : .opacity.combined(with: .scale(scale: 0.97))
    }
}

private struct TabInsertionMarker: View {
    var body: some View {
        Capsule().fill(sessionAccent).frame(width: 2, height: 20)
            .shadow(color: sessionAccent.opacity(0.24), radius: 3)
            .allowsHitTesting(false)
    }
}

private struct TabDragSource: ViewModifier {
    let lifted: Bool
    func body(content: Content) -> some View {
        content.opacity(lifted ? 0.38 : 1)
            .overlay(RoundedRectangle(cornerRadius: SurfaceRadius.tab)
                .strokeBorder(Color.primary.opacity(lifted ? 0.15 : 0), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                .allowsHitTesting(false))
            .animation(TabMotion.lift, value: lifted)
    }
}

// Follow the pointer directly; only lift, landing and cancellation animate.
// Retain the panel through landing even if a drop removes its source view.
private final class TabDragPreview {
    private let panel: NSPanel
    private let sourceFrame: NSRect
    private let grabOffset: NSPoint

    init(title: String, icon: String, count: Int, source: NSView, grabPoint: NSPoint) {
        let originalFrame = source.window?.convertToScreen(source.convert(source.bounds, to: nil)) ?? .zero
        let face = HStack(spacing: 7) {
            Image(systemName: icon).font(.system(size: 13, weight: .medium)).foregroundStyle(sessionAccent)
            Text(verbatim: title).font(TabTypography.favoriteLabel).lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: 180, alignment: .leading)
            if count > 1 {
                Text(verbatim: String(count)).font(TabTypography.suite(size: 10, relativeTo: .caption2))
                    .monospacedDigit().padding(.horizontal, 5).padding(.vertical, 2)
                    .background(.white.opacity(0.10), in: Capsule())
            }
        }.foregroundStyle(.white).padding(.horizontal, 11).padding(.vertical, 7)
            .background(Color(white: 0.16), in: RoundedRectangle(cornerRadius: SurfaceRadius.tile))
            .overlay(RoundedRectangle(cornerRadius: SurfaceRadius.tile).strokeBorder(sessionAccent.opacity(0.45)))
        let host = NSHostingView(rootView: face)
        let size = host.fittingSize
        let offset = NSPoint(x: min(max(grabPoint.x - originalFrame.minX, 18), max(18, size.width - 18)), y: size.height / 2)
        grabOffset = offset
        sourceFrame = NSRect(origin: NSPoint(x: grabPoint.x - offset.x, y: grabPoint.y - offset.y), size: size)
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.level = .floating
        panel.contentView = host
        panel.alphaValue = 0
    }

    func follow(_ point: NSPoint) {
        panel.setFrameOrigin(NSPoint(x: point.x - grabOffset.x, y: point.y - grabOffset.y))
        guard !panel.isVisible else { return }
        panel.orderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = TabMotion.reduced ? 0 : 0.10
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    func finish(accepted: Bool, at target: NSRect? = nil) {
        let destination = accepted ? target : sourceFrame
        let panel = self.panel
        NSAnimationContext.runAnimationGroup { context in
            context.duration = TabMotion.reduced ? 0 : (accepted ? 0.16 : 0.20)
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            if !TabMotion.reduced, let destination {
                panel.animator().setFrameOrigin(NSPoint(x: destination.midX - panel.frame.width / 2,
                                                        y: destination.midY - panel.frame.height / 2))
            }
            panel.animator().alphaValue = 0
        } completionHandler: { panel.orderOut(nil) }
    }

    func discard() { panel.orderOut(nil) }
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
    @ObservedObject private var drag = WorkspaceTabDrag.shared
    @ObservedObject private var navigationKeys = NavigationKeys.shared
    @ObservedObject var state: WorkspaceState
    let select: (WorkspaceTab) -> Void
    var detach: (Int, NSPoint) -> Void = { _, _ in }
    var receiveDrop: (WorkspaceDragPayload, Int) -> Bool = { _, _ in false }
    var receiveGroup: (WorkspaceGroupDragPayload) -> Bool = { _ in false }
    var closeGroup: (Int) -> Void = { _ in }
    private let badgeRadius = SurfaceRadius.tile
    @Namespace private var insertionMotion

    private func tabBadge(_ icon: String, title: String?, selected: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
            if let title { Text(verbatim: title).font(TabTypography.favoriteLabel).lineLimit(1) }
        }
        .padding(.horizontal, title == nil ? 0 : 8)
        .frame(minWidth: 30, maxWidth: title == nil ? 30 : 148)
        .frame(height: WorkspaceTabMetrics.height)
        .fixedSize(horizontal: true, vertical: false)
        .contentShape(Rectangle())
        .tabFace(selected: selected, cornerRadius: badgeRadius)
    }
    private func favorite(_ tab: WorkspaceTab, _ icon: String, _ label: String) -> some View {
        Button { select(tab) } label: {
            tabBadge(icon, title: tab == .settings && state.selected == tab ? label : nil, selected: state.selected == tab)
        }.buttonStyle(HoverButtonStyle(cornerRadius: badgeRadius))
         .help(label).accessibilityLabel(label)
         .accessibilityAddTraits(state.selected == tab ? .isSelected : [])
    }
    private var showsAppName: Bool {
        if case .shell = state.selected { return false }
        return true
    }
    @State private var renaming: ActivityBoard?
    @State private var pendingClosure: ActivityBoard?

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
        .alert("Close \(pendingClosure?.title ?? "Group")?",
               isPresented: Binding(get: { pendingClosure != nil }, set: { if !$0 { pendingClosure = nil } }),
               presenting: pendingClosure) { board in
            Button("Cancel", role: .cancel) {}
            Button("Close Group", role: .destructive) { closeGroup(board.id) }
        } message: { board in
            Text("Terminals to close: \(board.slots.count). All pages in this group will close. Running processes in these terminals will stop.")
        }
    }

    private func closeBoard(_ id: Int) {
        guard let board = state.activityBoards.boards.first(where: { $0.id == id }) else { return }
        if board.slots.isEmpty { closeGroup(id) }
        else { pendingClosure = board }
    }

    private var primaryRow: some View {
        HStack(spacing: 5) {
            favorite(.keys, "key", "Keys")
            favorite(.automations, "clock.arrow.circlepath", "Automations").padding(.trailing, 5)
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(Array(state.activityBoards.boards.enumerated()), id: \.element.id) { index, board in
                            let selected = state.selected.showsTerminals && state.activityBoards.selected == board.id
                            let droppingAfter = state.activityBoards.boards.firstIndex(where: { $0.id == drag.groupPayload?.sourceGroup }).map { $0 < index } ?? false
                            HStack(spacing: 0) {
                                Text(verbatim: board.title).font(TabTypography.favoriteLabel).lineLimit(1)
                                    .padding(.leading, 10).padding(.trailing, 4).frame(maxWidth: 200).frame(height: WorkspaceTabMetrics.height)
                                    .fixedSize(horizontal: true, vertical: false)
                                    .contentShape(Rectangle())
                                    .overlay {
                                        GroupTabDragArea(title: board.title, terminalCount: board.slots.count, select: { showBoard(board.id) },
                                                         rename: { renaming = board }, detach: { detach(board.id, $0) },
                                                         payload: WorkspaceGroupDragPayload(sourceWindow: state.id, sourceGroup: board.id),
                                                         receiveGroup: receiveGroup,
                                                         reorderGroup: { payload in
                                                             guard payload.sourceWindow == state.id else { return false }
                                                             return withAnimation(TabMotion.settle) {
                                                                 state.activityBoards.reorderGroup(payload.sourceGroup, to: board.id)
                                                             }
                                                         },
                                                         dropTarget: .group(state.id, board.id), receive: { receiveDrop($0, board.id) })
                                            .accessibilityHidden(true)
                                    }
                                    .help(board.title + GridTabKind.group.hint(at: index) + " · Double-click to rename · Drag to reorder, move to another window, or outside to detach")
                                    .accessibilityAddTraits(.isButton)
                                    .accessibilityAddTraits(selected ? .isSelected : [])
                                    .accessibilityAction { showBoard(board.id) }
                                Button { closeBoard(board.id) } label: {
                                    TabActionIcon()
                                }.buttonStyle(.plain)
                                .help("Close group and all its terminals")
                                .accessibilityLabel("Close group " + board.title)
                            }
                            .tabFace(selected: selected)
                            .modifier(TabDragSource(lifted: drag.groupPayload == WorkspaceGroupDragPayload(sourceWindow: state.id, sourceGroup: board.id)))
                            .modifier(ControlHover(cornerRadius: SurfaceRadius.tab))
                            .overlay(RoundedRectangle(cornerRadius: SurfaceRadius.tab).strokeBorder(
                                drag.target == .group(state.id, board.id) ? sessionAccent : .clear, lineWidth: 2)
                                .allowsHitTesting(false))
                            .background(drag.target == .group(state.id, board.id) ? sessionAccent.opacity(0.14) : .clear,
                                        in: RoundedRectangle(cornerRadius: SurfaceRadius.tab))
                            .overlay(alignment: droppingAfter ? .trailing : .leading) {
                                if drag.groupReorderTarget == .group(state.id, board.id) {
                                    TabInsertionMarker().matchedGeometryEffect(id: "group-insertion", in: insertionMotion)
                                }
                            }
                            .contextMenu {
                                Button("Rename Group…") { renaming = board }
                                Button("Move Group to New Window") { detach(board.id, NSEvent.mouseLocation) }
                                Button("Close Group") { closeBoard(board.id) }
                            }.transition(TabMotion.insertion).id(board.id)
                        }
                    }.animation(TabMotion.settle, value: state.activityBoards.boards.map(\.id))
                }.onChange(of: state.activityBoards.selected) { proxy.scrollTo($0) }
                 .background(drag.groupTarget == state.id ? sessionAccent.opacity(0.14) : .clear,
                             in: RoundedRectangle(cornerRadius: SurfaceRadius.tab))
                 .overlay(RoundedRectangle(cornerRadius: SurfaceRadius.tab).strokeBorder(
                    drag.groupTarget == state.id ? sessionAccent : .clear, lineWidth: 2).allowsHitTesting(false))
            }
            if state.selected == .keys {
                Menu {
                    Button("Generate SSH Key…") { state.generateKey.send() }
                    Button("Import SSH Public Key…") { state.importKey.send() }
                    Divider()
                    Button("Add API Key…") { state.addAPIKey.send() }
                } label: { Image(systemName: "plus").frame(width: 30, height: WorkspaceTabMetrics.height) }
                    .menuIndicator(.hidden).menuStyle(.borderlessButton).fixedSize().modifier(ControlHover())
                    .help("Add SSH or API key").accessibilityLabel("Add key")
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

// A group moves intact to an existing window, or detaches when dropped outside.
// A small preview follows the pointer; Escape cancels without moving any sessions.
private struct GroupTabDragArea: NSViewRepresentable {
    let title: String
    let terminalCount: Int
    let select: () -> Void
    let rename: () -> Void
    let detach: (NSPoint) -> Void
    let payload: WorkspaceGroupDragPayload
    let receiveGroup: (WorkspaceGroupDragPayload) -> Bool
    let reorderGroup: (WorkspaceGroupDragPayload) -> Bool
    let dropTarget: WorkspaceTabDrag.Target
    let receive: (WorkspaceDragPayload) -> Bool

    final class HitArea: WorkspaceDragDestinationView {
        var title = ""
        var terminalCount = 0
        var select: (() -> Void)?
        var rename: (() -> Void)?
        var detach: ((NSPoint) -> Void)?
        var payload: WorkspaceGroupDragPayload?
        private var origin: NSPoint?
        private var preview: TabDragPreview?
        private var keyMonitor: Any?
        private var dragging = false
        private var cancelled = false
        override var mouseDownCanMoveWindow: Bool { false }

        override func mouseDown(with event: NSEvent) {
            guard window?.attachedSheet == nil else { return }
            origin = event.locationInWindow
            cancelled = false
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] key in
                guard let self, key.keyCode == 53 else { return key }
                self.cancelled = true
                self.clearPreview()
                return nil
            }
        }

        override func mouseDragged(with event: NSEvent) {
            guard !cancelled, let origin, let window, let payload else { return }
            let distance = hypot(event.locationInWindow.x - origin.x, event.locationInWindow.y - origin.y)
            guard dragging || distance >= 6 else { return }
            if !dragging {
                dragging = true
                NSCursor.closedHand.push()
                preview = TabDragPreview(title: title, icon: "folder", count: terminalCount,
                                         source: self, grabPoint: window.convertPoint(toScreen: origin))
                WorkspaceTabDrag.shared.groupPayload = payload
            }
            let point = window.convertPoint(toScreen: event.locationInWindow)
            preview?.follow(point)
            let reorder = WorkspaceTabDrag.shared.groupReorderDestination(at: point, payload: payload)?.dropTarget
            let destination = WorkspaceTabDrag.shared.groupDestination(at: point, payload: payload)
            let targetWindow: UUID?
            if case let .group(id, _) = destination?.dropTarget { targetWindow = id }
            else { targetWindow = nil }
            WorkspaceTabDrag.shared.hover(group: targetWindow, reorder: reorder)
        }

        override func mouseUp(with event: NSEvent) {
            guard origin != nil, let window else { clearPreview(); return }
            let wasDragging = dragging
            let point = window.convertPoint(toScreen: event.locationInWindow)
            let payload = self.payload
            let reorder = payload.flatMap { WorkspaceTabDrag.shared.groupReorderDestination(at: point, payload: $0) }
            let destination = payload.flatMap { WorkspaceTabDrag.shared.groupDestination(at: point, payload: $0) }
            let frontWindow = WorkspaceTabDrag.shared.frontWindow(at: point)
            let landing = reorder?.screenFrame
            let preview = self.preview
            self.preview = nil
            clearPreview()
            guard !cancelled else { preview?.finish(accepted: false); return }
            if wasDragging {
                let accepted: Bool
                if let payload, let reorder { accepted = reorder.receiveGroupReorder?(payload) ?? false }
                else if let payload, let destination { accepted = destination.receiveGroup?(payload) ?? false }
                else if frontWindow == nil && !window.frame.insetBy(dx: -8, dy: -8).contains(point) {
                    detach?(point)
                    accepted = true
                } else { accepted = false }
                preview?.finish(accepted: accepted, at: landing)
            } else if event.clickCount == 2 { rename?() }
            else { select?() }
        }

        private func clearPreview() {
            preview?.finish(accepted: false)
            preview = nil
            if dragging { NSCursor.pop() }
            dragging = false
            origin = nil
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
            WorkspaceTabDrag.shared.end()
        }

        deinit {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            preview?.discard()
            if dragging { NSCursor.pop() }
        }
    }

    func makeNSView(context: Context) -> HitArea { HitArea() }
    func updateNSView(_ view: HitArea, context: Context) {
        view.title = title
        view.terminalCount = terminalCount
        view.select = select
        view.rename = rename
        view.detach = detach
        view.payload = payload
        view.receiveGroup = receiveGroup
        view.receiveGroupReorder = reorderGroup
        view.dropTarget = dropTarget
        view.receive = receive
    }
}

private final class WorkspaceTabDrag: ObservableObject {
    static let shared = WorkspaceTabDrag()
    let destinations = NSHashTable<WorkspaceDragDestinationView>.weakObjects()
    @Published var payload: WorkspaceDragPayload?
    @Published var target: Target?
    @Published var groupPayload: WorkspaceGroupDragPayload?
    @Published var groupTarget: UUID?
    @Published var groupReorderTarget: Target?

    enum Target: Equatable {
        case group(UUID, Int)
        case terminal(UUID, Int, Int)
        case page(UUID, Int, Int)
        case list(UUID, Int, Int)

        func accepts(_ payload: WorkspaceDragPayload) -> Bool {
            switch self {
            case let .group(window, group):
                return !payload.slots.isEmpty && (window != payload.sourceWindow || group != payload.sourceGroup)
            case let .terminal(window, _, slot):
                return !payload.isPage && payload.slots.count == 1 &&
                    (payload.sourceWindow != window || payload.slots.first != slot)
            case let .page(window, group, _):
                return payload.isPage ? payload.sourceWindow == window && payload.sourceGroup == group : payload.slots.count == 1
            case .list:
                return !payload.isPage && payload.slots.count == 1
            }
        }
    }

    func frontWindow(at point: NSPoint) -> NSWindow? {
        NSApp.orderedWindows.first(where: {
            $0.isVisible && !$0.ignoresMouseEvents && $0.frame.contains(point)
        })
    }

    func groupDestination(at point: NSPoint, payload: WorkspaceGroupDragPayload) -> WorkspaceDragDestinationView? {
        guard let frontWindow = frontWindow(at: point), frontWindow.attachedSheet == nil else { return nil }
        return destinations.allObjects.first { view in
            guard view.window === frontWindow, view.receiveGroup != nil,
                  case let .group(windowID, _) = view.dropTarget else { return false }
            return windowID != payload.sourceWindow
        }
    }

    func groupReorderDestination(at point: NSPoint, payload: WorkspaceGroupDragPayload) -> WorkspaceDragDestinationView? {
        guard let frontWindow = frontWindow(at: point), frontWindow.attachedSheet == nil else { return nil }
        return destinations.allObjects.first { view in
            guard view.window === frontWindow, view.receiveGroupReorder != nil, !view.isHiddenOrHasHiddenAncestor,
                  case let .group(windowID, group) = view.dropTarget,
                  windowID == payload.sourceWindow, group != payload.sourceGroup else { return false }
            let local = view.convert(frontWindow.convertPoint(fromScreen: point), from: nil)
            return view.bounds.intersection(view.visibleRect).contains(local)
        }
    }

    func destination(at point: NSPoint, payload: WorkspaceDragPayload) -> WorkspaceDragDestinationView? {
        guard let frontWindow = frontWindow(at: point) else { return nil }
        let matches = destinations.allObjects.filter { view in
            guard let window = view.window, window === frontWindow,
                  window.attachedSheet == nil, !view.isHiddenOrHasHiddenAncestor,
                  view.dropTarget?.accepts(payload) == true else { return false }
            let local = view.convert(window.convertPoint(fromScreen: point), from: nil)
            return view.bounds.intersection(view.visibleRect).contains(local)
        }
        return matches.first(where: { if case .list = $0.dropTarget { return false }; return true }) ?? matches.first
    }

    func hover(_ next: Target?) {
        guard target != next else { return }
        withAnimation(TabMotion.hover) { target = next }
    }

    func hover(group window: UUID?, reorder: Target?) {
        guard groupTarget != window || groupReorderTarget != reorder else { return }
        withAnimation(TabMotion.hover) { groupTarget = window; groupReorderTarget = reorder }
    }

    func end() {
        withAnimation(TabMotion.lift) {
            target = nil; payload = nil; groupPayload = nil; groupTarget = nil; groupReorderTarget = nil
        }
    }
}

// App-owned hit regions let a drag cross the toolbar, terminal strip and windows
// without exporting session information to the system pasteboard.
private class WorkspaceDragDestinationView: NSView {
    var dropTarget: WorkspaceTabDrag.Target?
    var receive: ((WorkspaceDragPayload) -> Bool)?
    var receiveGroup: ((WorkspaceGroupDragPayload) -> Bool)?
    var receiveGroupReorder: ((WorkspaceGroupDragPayload) -> Bool)?
    var screenFrame: NSRect? { window?.convertToScreen(convert(bounds, to: nil)) }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        WorkspaceTabDrag.shared.destinations.add(self)
    }
}

private struct WorkspaceItemDragArea: NSViewRepresentable {
    let title: String
    let payload: WorkspaceDragPayload
    var dropTarget: WorkspaceTabDrag.Target? = nil
    var receive: ((WorkspaceDragPayload) -> Bool)? = nil
    var doubleSelect: (() -> Void)? = nil
    let select: () -> Void

    final class HitArea: WorkspaceDragDestinationView {
        var title = ""
        var payload: WorkspaceDragPayload?
        var select: (() -> Void)?
        var doubleSelect: (() -> Void)?
        private var origin: NSPoint?
        private var preview: TabDragPreview?
        private var keyMonitor: Any?
        private var dragging = false
        override var mouseDownCanMoveWindow: Bool { false }

        override func mouseDown(with event: NSEvent) {
            guard window?.attachedSheet == nil else { return }
            origin = event.locationInWindow
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] key in
                guard key.keyCode == 53, let self else { return key }
                self.clear()
                return nil
            }
        }
        override func mouseDragged(with event: NSEvent) {
            guard let origin, let payload, !payload.slots.isEmpty, let window else { return }
            guard dragging || hypot(event.locationInWindow.x - origin.x, event.locationInWindow.y - origin.y) >= 4 else { return }
            if !dragging {
                dragging = true
                NSCursor.closedHand.push()
                preview = TabDragPreview(title: title, icon: payload.isPage ? "square.grid.2x2" : "terminal",
                                         count: payload.slots.count, source: self,
                                         grabPoint: window.convertPoint(toScreen: origin))
                WorkspaceTabDrag.shared.payload = payload
            }
            let point = window.convertPoint(toScreen: event.locationInWindow)
            preview?.follow(point)
            let target = WorkspaceTabDrag.shared.destination(at: point, payload: payload)
            WorkspaceTabDrag.shared.hover(target?.dropTarget)
        }
        override func mouseUp(with event: NSEvent) {
            guard origin != nil, let window else { clear(); return }
            let wasDragging = dragging
            let point = window.convertPoint(toScreen: event.locationInWindow)
            let payload = self.payload
            let destination = payload.flatMap {
                WorkspaceTabDrag.shared.destination(at: point, payload: $0)
            }
            let landing: NSRect?
            if case .list = destination?.dropTarget { landing = nil }
            else { landing = destination?.screenFrame }
            let preview = self.preview
            self.preview = nil
            clear()
            if wasDragging {
                let accepted = payload.map { destination?.receive?($0) ?? false } ?? false
                preview?.finish(accepted: accepted, at: landing)
            } else if event.clickCount == 2, let doubleSelect { doubleSelect() }
            else { select?() }
        }
        private func clear() {
            preview?.finish(accepted: false)
            preview = nil
            if dragging { NSCursor.pop() }
            dragging = false
            origin = nil
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
            WorkspaceTabDrag.shared.end()
        }
        deinit {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            preview?.discard()
            if dragging { NSCursor.pop() }
        }
    }

    func makeNSView(context: Context) -> HitArea { HitArea() }
    func updateNSView(_ view: HitArea, context: Context) {
        view.title = title
        view.payload = payload
        view.dropTarget = dropTarget
        view.receive = receive
        view.select = select
        view.doubleSelect = doubleSelect
    }
}

// A passive region behind the scroll view catches drops in the list's blank
// space without intercepting clicks, terminal selection or scrolling.
private struct WorkspaceListDropArea: NSViewRepresentable {
    let target: WorkspaceTabDrag.Target
    let receive: (WorkspaceDragPayload) -> Bool
    final class HitArea: WorkspaceDragDestinationView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
    func makeNSView(context: Context) -> HitArea { HitArea() }
    func updateNSView(_ view: HitArea, context: Context) {
        view.dropTarget = target
        view.receive = receive
    }
}

private struct GridLayoutIcon: Shape {
    let columns: Int
    let rows: Int

    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let gap: CGFloat = columns == 1 ? 0 : 1.5
        let cellWidth = (side - gap * CGFloat(columns - 1)) / CGFloat(columns)
        let cellHeight = (side - gap * CGFloat(rows - 1)) / CGFloat(rows)
        let origin = CGPoint(x: rect.midX - side / 2, y: rect.midY - side / 2)
        var path = Path()
        for row in 0..<rows {
            for column in 0..<columns {
                let tile = CGRect(x: origin.x + CGFloat(column) * (cellWidth + gap),
                                  y: origin.y + CGFloat(row) * (cellHeight + gap), width: cellWidth, height: cellHeight)
                let cell = min(cellWidth, cellHeight)
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
    let focusTerminal: (Int) -> Void
    let create: () -> Void
    let close: (Int) -> Void
    let move: (Int, Int) -> Void
    var receivePage: (WorkspaceDragPayload, Int, Int) -> Bool = { _, _, _ in false }
    var receiveTerminal: (WorkspaceDragPayload, Int, Int) -> Bool = { _, _, _ in false }

    var body: some View {
        if state.selected.showsTerminals {
            terminalRow.buttonStyle(HoverButtonStyle()).background(Color(nsColor: state.tabColor))
        }
    }

    private var board: ActivityBoard { state.activityBoards.current }

    private var terminalRow: some View {
        HStack(spacing: 6) {
            TerminalTabStrip(state: state, select: select, focusTerminal: focusTerminal, close: close, move: move, receivePage: receivePage, receiveTerminal: receiveTerminal)
            Button(action: create) { Image(systemName: "plus").frame(width: 24, height: 26) }
                .help("New terminal").accessibilityLabel("New terminal")
            if state.selected == .activity {
                HStack(spacing: 2) {
                    ForEach(ActivityGrid.allCases, id: \.self) { grid in
                        let selected = grid == board.grid
                        Button {
                            let slot = state.activityTerminal.flatMap { state.tab(id: $0) }?.shortcutSlot
                            state.activityBoards.setGrid(grid, keeping: slot)
                        } label: {
                            HStack(spacing: 5) {
                                GridLayoutIcon(columns: grid.columns, rows: grid.rows).frame(width: 14, height: 14)
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
                }.padding(2).frame(width: CGFloat(ActivityGrid.allCases.count) * 48 + 4)
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
    @ObservedObject private var drag = WorkspaceTabDrag.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var navigationKeys = NavigationKeys.shared
    private enum Anchor: Hashable { case page(group: Int, slot: Int), terminal(Int) }
    @Namespace private var insertionMotion

    private struct PageItem: Identifiable {
        let index: Int
        let slots: [Int]
        var id: Int { slots.first ?? -1 }
    }

    private func pages(in board: ActivityBoard) -> [PageItem] {
        board.paginatedSlots.enumerated().map { PageItem(index: $0.offset, slots: Array($0.element)) }
    }

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
        if showsPageGroups { return .page(group: board.id, slot: board.visibleSlots.first ?? -1) }
        if board.grid == .single, let slot = board.visibleSlots.first,
           let tab = state.tab(slot: slot) { return .terminal(tab.id) }
        return nil
    }

    @ObservedObject var state: WorkspaceState
    let select: (WorkspaceTab) -> Void
    let focusTerminal: (Int) -> Void
    let close: (Int) -> Void
    let move: (Int, Int) -> Void
    private var draggedSlots: [Int] {
        guard let payload = drag.payload, payload.sourceWindow == state.id else { return [] }
        return payload.slots
    }
    var receivePage: (WorkspaceDragPayload, Int, Int) -> Bool
    var receiveTerminal: (WorkspaceDragPayload, Int, Int) -> Bool
    private struct PageClosure {
        let number: Int
        let sessionIDs: [Int]
    }
    @State private var pendingClosure: PageClosure?

    private func draggedPage(in board: ActivityBoard) -> Int? {
        guard let payload = drag.payload, payload.isPage, payload.sourceWindow == state.id,
              payload.sourceGroup == board.id else { return nil }
        return board.paginatedSlots.firstIndex { $0.elementsEqual(payload.slots) }
    }

    private func receive(_ payload: WorkspaceDragPayload, on page: Int, board: ActivityBoard) -> Bool {
        if payload.isPage {
            guard payload.sourceWindow == state.id, payload.sourceGroup == board.id,
                  let source = board.paginatedSlots.firstIndex(where: { $0.elementsEqual(payload.slots) }) else { return false }
            return withAnimation(TabMotion.settle) {
                state.activityBoards.reorderPage(in: board.id, from: source, to: page)
            }
        }
        return receivePage(payload, board.id, page)
    }

    private func receiveInList(_ payload: WorkspaceDragPayload) -> Bool {
        let board = state.activityBoards.current
        if payload.sourceWindow == state.id, payload.sourceGroup == board.id,
           let slot = payload.slots.first, board.visibleSlots.contains(slot),
           let source = state.tab(slot: slot),
           let last = board.visibleSlots.last.flatMap({ slot in state.tab(slot: slot) }) {
            guard source.id != last.id else { return false }
            move(source.id, last.id)
            return true
        }
        return receivePage(payload, board.id, board.page)
    }

    private func pageTab(_ page: Int, board: ActivityBoard, pageSlots: [Int], totalPages: Int, anchor: Int, sourcePage: Int?, expanded: Bool) -> some View {
        let active = page == board.page
        let terminalCount = pageSlots.count
        let countLabel = "\(terminalCount) " + (terminalCount == 1 ? "terminal" : "terminals")
        let item = Anchor.page(group: board.id, slot: anchor)
        return HStack(spacing: 0) {
            HStack(spacing: 6) {
                    Capsule().fill(active ? sessionAccent : Color.secondary.opacity(0.55))
                        .frame(width: 3, height: active ? 14 : 8)
                    Text("Page \(page + 1)").font(TabTypography.favoriteLabel).monospacedDigit()
                    if !active {
                        Text(verbatim: String(terminalCount))
                            .font(TabTypography.suite(size: 10, relativeTo: .caption2)).monospacedDigit()
                            .padding(.horizontal, 4).frame(minWidth: 16, minHeight: 16)
                            .background(Color.primary.opacity(0.10), in: Capsule())
                    }
                    if let shortcut = GridTabKind.page.shortcut(at: page) {
                        TabShortcutLabel(keys: shortcut)
                    }
                }
                .fixedSize().padding(.leading, 10).padding(.trailing, 4).frame(height: WorkspaceTabMetrics.height)
                .foregroundStyle(active ? sessionAccent : Color.primary.opacity(0.8))
                .contentShape(Rectangle())
            .overlay {
                WorkspaceItemDragArea(title: "Page \(page + 1)", payload: WorkspaceDragPayload(
                    sourceWindow: state.id, sourceGroup: board.id, slots: pageSlots, isPage: true),
                    dropTarget: .page(state.id, board.id, page), receive: { receive($0, on: page, board: board) }) {
                    if state.navigate(.page, to: .index(page)) { select(.activity) }
                }.accessibilityHidden(true)
            }
            .focused($focus, equals: .title(item))
            .accessibilityElement(children: .ignore)
            .help("Page \(page + 1) of \(totalPages) · " + countLabel + GridTabKind.page.hint(at: page))
            .accessibilityLabel("Page \(page + 1) of \(totalPages)")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { if state.navigate(.page, to: .index(page)) { select(.activity) } }
            .accessibilityValue(countLabel)
            .accessibilityAddTraits(active ? .isSelected : [])

            Button {
                let ids = pageSlots.compactMap { state.tab(slot: $0)?.id }
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
        .modifier(TabDragSource(lifted: drag.payload?.isPage == true && sourcePage == page))
        .overlay(alignment: .trailing) {
            if expanded { Rectangle().fill(Color.primary.opacity(0.16)).frame(width: 1, height: 16).allowsHitTesting(false) }
        }
    }

    private func terminalTab(_ tab: TabActivity) -> some View {
        let board = state.activityBoards.current
        let shortcutIndex = state.terminalShortcutIndex(for: tab.shortcutSlot)
        let item = Anchor.terminal(tab.id)
        let visibleSingle = board.grid == .single && board.visibleSlots.first == tab.shortcutSlot
        let selected = state.selected == .shell(tab.id) || (state.selected == .activity && (state.activityTerminal == tab.id || visibleSingle))
        return HStack(spacing: 0) {
            HStack(spacing: 6) {
                    tab.icon(fallback: "terminal.fill", size: 16)
                        .font(.system(size: 12))
                        .foregroundStyle(selected ? sessionAccent : Color.secondary)
                        .accessibilityHidden(true)
                    tab.titleLabel(weight: .medium)
                        .frame(maxWidth: 150, alignment: .leading)
                        .fixedSize(horizontal: true, vertical: false)
                    if let shortcutIndex, ShellTabShortcuts.keys.indices.contains(shortcutIndex) {
                        TabShortcutLabel(keys: navigationKeys.modifier(.terminal).symbol + ShellTabShortcuts.keys[shortcutIndex]).opacity(0.8)
                    }
                }
                .lineLimit(1).padding(.leading, 8).padding(.trailing, 2).frame(height: WorkspaceTabMetrics.height)
                .contentShape(Rectangle())
                .focused($focus, equals: .title(item))
                .overlay {
                    WorkspaceItemDragArea(title: tab.name, payload: WorkspaceDragPayload(
                        sourceWindow: state.id, sourceGroup: board.id, slots: [tab.shortcutSlot], isPage: false),
                        dropTarget: .terminal(state.id, board.id, tab.shortcutSlot), receive: { payload in
                            receiveTerminal(payload, board.id, tab.shortcutSlot)
                        }) {
                        focusTerminal(tab.id)
                    }.accessibilityHidden(true)
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { focusTerminal(tab.id) }
                .help(tab.name + (shortcutIndex.map { ShellTabShortcuts.hint(at: $0) } ?? ""))
             .accessibilityAddTraits(selected ? .isSelected : [])
            Button { close(tab.id) } label: { TabActionIcon(width: 26).opacity(revealsClose(item) ? 1 : 0) }.buttonStyle(.plain)
                .focused($focus, equals: .close(item))
                .allowsHitTesting(revealsClose(item))
                .help("Close tab").accessibilityLabel("Close tab")
        }.tabFace(selected: selected)
         .onHover { track(item, inside: $0) }
         .modifier(ControlHover(cornerRadius: SurfaceRadius.tab))
         .modifier(TabDragSource(lifted: draggedSlots.contains(tab.shortcutSlot)))
         .overlay(RoundedRectangle(cornerRadius: SurfaceRadius.tab).strokeBorder(
            drag.target == .terminal(state.id, board.id, tab.shortcutSlot) ? sessionAccent : .clear, lineWidth: 1.5)
            .allowsHitTesting(false))
         .overlay(alignment: insertsAfter(tab.shortcutSlot, in: board) ? .trailing : .leading) {
             if drag.target == .terminal(state.id, board.id, tab.shortcutSlot) {
                 TabInsertionMarker().matchedGeometryEffect(id: "item-insertion", in: insertionMotion)
             }
         }
         .transition(TabMotion.insertion)
         .id(Anchor.terminal(tab.id))
    }

    private func insertsAfter(_ slot: Int, in board: ActivityBoard) -> Bool {
        guard drag.target == .terminal(state.id, board.id, slot), let payload = drag.payload, !payload.isPage, payload.sourceWindow == state.id,
              payload.sourceGroup == board.id, let source = payload.slots.first,
              board.page(containing: source) == board.page(containing: slot),
              let from = board.slots.firstIndex(of: source), let to = board.slots.firstIndex(of: slot) else { return false }
        return from < to
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: showsPageGroups ? 12 : 4) {
                    let board = state.activityBoards.current
                    let pageItems = pages(in: board)
                    let sourcePage = draggedPage(in: board)
                    let grouped = board.grid != .single && pageItems.count > 1
                    ForEach(pageItems) { item in
                        let page = item.index
                        let group = Anchor.page(group: board.id, slot: item.id)
                        let slots = item.slots
                        let draggingFromPage = draggedSlots.contains(where: slots.contains)
                        let expanded = !grouped || page == board.page || hoveredPageGroup == group || draggingFromPage
                        HStack(spacing: 0) {
                            if grouped {
                                pageTab(page, board: board, pageSlots: slots, totalPages: pageItems.count,
                                        anchor: item.id, sourcePage: sourcePage, expanded: expanded).id(group)
                            }
                            if expanded {
                                HStack(spacing: 4) {
                                    ForEach(slots, id: \.self) { slot in
                                        if let tab = state.tab(slot: slot) { terminalTab(tab) }
                                    }
                                }
                                .padding(.leading, grouped ? 8 : 0)
                                .transition(.offset(x: -6).combined(with: .opacity))
                            }
                        }
                        .background(grouped && hoveredPageGroup == group ? sessionAccent.opacity(0.09) : .clear,
                                    in: RoundedRectangle(cornerRadius: SurfaceRadius.tab))
                        .overlay(RoundedRectangle(cornerRadius: SurfaceRadius.tab).strokeBorder(
                            drag.target == .page(state.id, board.id, page) && drag.payload?.isPage != true ? sessionAccent : .clear, lineWidth: 2)
                            .allowsHitTesting(false))
                        .overlay(alignment: (sourcePage.map { $0 < page } ?? false) ? .trailing : .leading) {
                            if drag.payload?.isPage == true && drag.target == .page(state.id, board.id, page) && sourcePage != page {
                                TabInsertionMarker().matchedGeometryEffect(id: "item-insertion", in: insertionMotion)
                            }
                        }
                        .contentShape(Rectangle())
                        .onHover { inside in
                            guard grouped, inside ? hoveredPageGroup != group : hoveredPageGroup == group else { return }
                            withAnimation(reduceMotion || drag.payload != nil ? nil : .easeOut(duration: inside ? 0.14 : 0.10)) {
                                hoveredPageGroup = inside ? group : nil
                            }
                        }.transition(TabMotion.insertion)
                    }
                }.animation(TabMotion.settle, value: state.activityBoards.current.slots)
                 .animation(TabMotion.settle, value: state.activityBoards.current.pageBreaks)
            }.frame(minWidth: 80)
             .background {
                 let board = state.activityBoards.current
                 WorkspaceListDropArea(target: .list(state.id, board.id, board.page), receive: receiveInList)
             }
             .overlay(RoundedRectangle(cornerRadius: SurfaceRadius.tab).strokeBorder(
                drag.target == .list(state.id, state.activityBoards.current.id, state.activityBoards.current.page) ? sessionAccent : .clear,
                lineWidth: 1.5).allowsHitTesting(false))
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
    @ObservedObject private var drag = WorkspaceTabDrag.shared
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
                        LazyVGrid(columns: Array(repeating: GridItem(.fixed(layout.cardSize.width), spacing: gap), count: board.grid.columns), spacing: gap) {
                            ForEach(Array(board.visibleSlots), id: \.self) { slot in
                                if let tab = state.tab(slot: slot) {
                                    card(tab, layout: layout).frame(width: layout.cardSize.width, height: layout.cardSize.height).clipped()
                                }
                            }
                        }
                    }.padding(ActivityTileLayout.outerInset)
                }
            }
        }
        .onReceive(state.focusActivityTerminal) { id in
            guard state.selected == .activity, let tab = state.tab(id: id) else { return }
            toggleFocus(tab)
        }
    }

    @ViewBuilder
    private func cardTitle(_ tab: TabActivity, width: CGFloat) -> some View {
        let shortcutIndex = state.terminalShortcutIndex(for: tab.shortcutSlot)
        let usage = ClaudeLimits.summary(tab.limits)
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
            if width >= 170 && !usage.isEmpty {
                Text(verbatim: usage)
                    .font(TabTypography.suite(size: NSFont.preferredFont(forTextStyle: .caption1).pointSize, relativeTo: .caption))
                    .foregroundStyle(.secondary).lineLimit(1).layoutPriority(1).help(usage)
            } else if width >= 390 && !tab.status.isEmpty {
                Text(verbatim: tab.status).font(TabTypography.suite(size: NSFont.preferredFont(forTextStyle: .caption1).pointSize, relativeTo: .caption)).foregroundStyle(.secondary).lineLimit(1)
            }
            if width >= 150, let shortcutIndex, ShellTabShortcuts.keys.indices.contains(shortcutIndex) {
                TabShortcutLabel(keys: navigationKeys.modifier(.terminal).symbol + ShellTabShortcuts.keys[shortcutIndex])
            }
        }.frame(height: ActivityTileLayout.header).contentShape(Rectangle())

            label.overlay {
                WorkspaceItemDragArea(title: tab.name, payload: WorkspaceDragPayload(
                    sourceWindow: state.id, sourceGroup: board.id, slots: [tab.shortcutSlot], isPage: false),
                    doubleSelect: board.grid == .single ? nil : { expand(tab.id) }) { toggleFocus(tab) }
                    .accessibilityHidden(true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { toggleFocus(tab) }
            .accessibilityAction(named: Text("Expand terminal")) { expand(tab.id) }
            .help(details + "\nDrag to move terminal · Double-click to expand terminal")
            .modifier(TabDragSource(lifted: drag.payload?.sourceWindow == state.id &&
                drag.payload?.isPage == false && drag.payload?.slots.contains(tab.shortcutSlot) == true))
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

/// Borrow the existing terminal view so input, scrollback and the PTY stay in the same session.
private struct ActivityTerminal: NSViewRepresentable {
    weak var terminal: NSView?
    let size: CGSize
    let isVisible: () -> Bool
    let wantsFocus: () -> Bool

    final class Container: NSView {
        // The session and view hierarchy own this borrowed view. A detached,
        // cached SwiftUI host must not retain a closed terminal's scrollback.
        private weak var terminal: NSView?
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
        if let terminal { container.attach(terminal, size: size, isVisible: isVisible, wantsFocus: wantsFocus) }
        return container
    }
    func updateNSView(_ view: Container, context: Context) {
        if let terminal { view.attach(terminal, size: size, isVisible: isVisible, wantsFocus: wantsFocus) }
        else { view.detach() }
    }
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

// One selection target across the row, with a separate trailing action above it.
struct LibraryRow<Label: View, Action: View>: View {
    let selected: Bool
    let select: () -> Void
    @ViewBuilder let label: () -> Label
    @ViewBuilder let action: () -> Action

    var body: some View {
        Button(action: select) {
            label()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 8).padding(.trailing, 44).padding(.vertical, 8)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .overlay(alignment: .trailing) { action().padding(.trailing, 8) }
        .modifier(LibraryRowSurface(selected: selected))
    }
}

struct LibraryRowSurface: ViewModifier {
    let selected: Bool
    @State private var hovered = false

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: SurfaceRadius.tile, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(hovered ? 0.25 : 0.18)
                                   : Color.primary.opacity(hovered ? 0.075 : 0))
            }
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
    }
}

struct PanelActionButton: View {
    let symbol: String
    let title: String
    var highlighted = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(highlighted ? Color.accentColor : .secondary)
                .frame(width: 28, height: 28)
                .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: SurfaceRadius.control))
        }
        .buttonStyle(HoverButtonStyle())
        .accessibilityLabel(title)
        .help(title)
    }
}
