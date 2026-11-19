import AppKit
import Combine
import SwiftTerm
import SwiftUI
import Carbon
import CoreText
import UserNotifications

// A launchd-owned instance hosts persistent terminals without creating UI.
PersistentTerminal.runServiceIfRequested()

let shellSurface = NSColor(srgbRed: 0.075, green: 0.082, blue: 0.10, alpha: 1)

private let promptFontName: String = {
    #if SWIFT_PACKAGE
    let bundle = Bundle.module
    #else
    let bundle = Bundle.main
    #endif
    if let url = bundle.url(forResource: "JetBrainsMonoNLNerdFontMono-Regular", withExtension: "ttf") {
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }
    return "JetBrainsMonoNLNFM-Regular"
}()

func terminalFont(size: CGFloat) -> NSFont {
    // A theme's font applies only when it is installed.
    let themed = UserDefaults.standard.string(forKey: ThemeKey.font).flatMap { NSFont(name: $0, size: size) }
    let base = themed ?? NSFont(name: promptFontName, size: size) ?? NSFont(name: "JetBrainsMono-Regular", size: size) ?? .monospacedSystemFont(ofSize: size, weight: .regular)
    // Starship mixes Nerd Font icons with Unicode symbols and color emoji.
    let cascade = ["AppleSymbols", "AppleColorEmoji"].map { NSFontDescriptor(name: $0, size: size) }
    return NSFont(descriptor: base.fontDescriptor.addingAttributes([.cascadeList: cascade]), size: size) ?? base
}

enum ShellTabShortcuts {
    static let keys = Array("1234567890-=").map(String.init)
    // Use the physical number row so the same keys work with Korean input too.
    static let keyCodes = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6,
                           kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9, kVK_ANSI_0, kVK_ANSI_Minus, kVK_ANSI_Equal].map(UInt16.init)

    static func hint(at index: Int) -> String {
        keys.indices.contains(index) ? " (\(NavigationKeys.shared.modifier(.terminal).symbol)\(keys[index]))" : ""
    }
}

private func themedHost<Content: View>(rootView: Content) -> NSHostingView<ThemedRoot<Content>> {
    NSHostingView(rootView: ThemedRoot(content: rootView))
}

private final class ShellWindow: NSWindow {
    var selectTabAtIndex: ((Int) -> Void)?
    var navigateGridTabs: ((GridTabKind, GridTabTarget) -> Bool)?
    var canBrowsePages: (() -> Bool)?
    var responderChanged: ((NSResponder?) -> Void)?

    @discardableResult
    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        let accepted = super.makeFirstResponder(responder)
        if accepted {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.responderChanged?(self.firstResponder)
            }
        }
        return accepted
    }


    override func sendEvent(_ event: NSEvent) {
        // Option and Control key presses can go straight to the first responder
        // without AppKit looking for a menu key equivalent.
        if event.type == .keyDown, isKeyWindow, attachedSheet == nil {
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if flags == .option || flags == .control,
               let letter = event.characters(byApplyingModifiers: [])?.lowercased(),
               let action = CreationKeys.actions.first(where: {
                   CreationKeys.shared.modifier($0).flags == flags && CreationKeys.shared.key($0) == letter
               }), let menu = NSApp.mainMenu?.item(withTitle: "Shell")?.submenu,
               let item = menu.item(withTitle: "New " + action) {
                if !event.isARepeat { menu.performActionForItem(at: menu.index(of: item)) }
                return
            }
        }
        if handleNavigationShortcut(event) { return }
        if event.type == .keyDown, attachedSheet == nil,
           event.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty {
            if isKeyWindow, let step = bracketStep(event), canBrowsePages?() == true,
               navigateGridTabs?(.page, .step(step)) == true { return }
        }
        super.sendEvent(event)
    }


    private func bracketStep(_ event: NSEvent) -> Int? {
        switch event.keyCode {
        case UInt16(kVK_ANSI_LeftBracket): return -1
        case UInt16(kVK_ANSI_RightBracket): return 1
        default: return nil
        }
    }

    private func handleNavigationShortcut(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, isKeyWindow, attachedSheet == nil else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let keys = NavigationKeys.shared
        if modifiers == keys.modifier(.terminal).flags,
           let index = ShellTabShortcuts.keyCodes.firstIndex(of: event.keyCode), let selectTabAtIndex {
            selectTabAtIndex(index)
            return true
        }
        let kind: GridTabKind
        if modifiers == keys.modifier(.group).flags { kind = .group }
        else if modifiers == keys.modifier(.page).flags { kind = .page }
        else { return false }
        let target: GridTabTarget
        if let step = bracketStep(event) { target = .step(step) }
        else if let index = ShellTabShortcuts.keyCodes.prefix(10).firstIndex(of: event.keyCode) { target = .index(index) }
        else { return false }
        return navigateGridTabs?(kind, target) == true
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if handleNavigationShortcut(event) { return true }
        return super.performKeyEquivalent(with: event)
    }
}

private final class WorkspaceContentView: NSView {
    static let terminalInset: CGFloat = 10
    static let terminalTopInset: CGFloat = 12
    private var contentInset: CGFloat = 0

    // Ignore transient empty bounds until the window has a real layout.
    func contentFrame(inset: CGFloat) -> CGRect? {
        // AppKit coordinates grow upward, so subtract the top margin from
        // the height while keeping utility panels flush with their container.
        let topInset = inset > 0 ? Self.terminalTopInset : 0
        let rect = CGRect(x: bounds.minX + inset, y: bounds.minY + inset,
                          width: bounds.size.width - 2 * inset, height: bounds.size.height - inset - topInset)
        guard rect.size.width > 0, rect.size.height > 0, !rect.isInfinite, rect.origin.x.isFinite, rect.origin.y.isFinite,
              rect.width.isFinite, rect.height.isFinite else { return nil }
        return rect
    }

    func show(_ view: NSView, inset: CGFloat) {
        contentInset = inset
        if subviews.first !== view {
            subviews.first?.removeFromSuperview()
            view.removeFromSuperview()
            view.autoresizingMask = []
            addSubview(view)
        }
        fitContent()
    }

    override func layout() {
        super.layout()
        fitContent()
    }

    private func fitContent() {
        guard let view = subviews.first, let rect = contentFrame(inset: contentInset),
              view.frame != rect else { return }
        view.frame = rect
    }
}

private final class Session {
    let id: Int
    let view: LocalProcessTerminalView
    let shortcutSlot: Int
    let persistentID: UUID
    var pane: PersistentTerminal.Pane?
    var title: String
    var directory = FileManager.default.currentDirectoryPath
    var hasReportedDirectory = false
    init(_ id: Int, _ view: LocalProcessTerminalView, _ title: String, shortcutSlot: Int, persistentID: UUID) {
        self.persistentID = persistentID
        self.id = id; self.view = view; self.title = title; self.shortcutSlot = shortcutSlot
    }
}

private struct TerminalStatus: Sendable {
    let pane: PersistentTerminal.Pane
    let busy: Bool
    let status: String
    let icon: String?
    let limits: [String]

    static func capture(_ panes: [PersistentTerminal.Pane], directory: URL, server: PersistentTerminal? = nil) -> [UUID: TerminalStatus] {
        Dictionary(panes.map { pane in
            let group = pane.foregroundProcessGroup
            let busy = group > 0 && group != pane.pid
            var buffer = [CChar](repeating: 0, count: 1024)
            let name = busy && proc_name(group, &buffer, UInt32(buffer.count)) > 0 ? String(cString: buffer) : nil
            let status = busy ? (name ?? "Foreground task") + " running" : (group > 0 ? "" : "Checking status")
            let icon = busy ? ForegroundProgram.icon(pid: group, name: name, title: pane.title) : nil
            let holdsScroll = ["claude", "openai", "gemini", "githubcopilot", "qwen", "amp", "opencode", "openclaw"].contains(icon ?? "")
            if pane.holdsScroll != holdsScroll {
                try? server?.setScrollHold(holdsScroll, for: pane.id)
            }
            let limits = icon == "claude" ? ClaudeLimits.rows(at: directory.appendingPathComponent("limits-\(pane.id.uuidString)-\(group)")) : []
            return (pane.id, TerminalStatus(pane: pane, busy: busy, status: status, icon: icon, limits: limits))
        }, uniquingKeysWith: { first, _ in first })
    }
}

private struct WindowSnapshot: Codable, Equatable {
    let frame: String
    let directories: [String]
    let persistentIDs: [UUID]?
    let shortcutSlots: [Int]?
    let activityBoards: ActivityBoards?
    let activityFocusedSlot: Int?
    let lastShellIndex: Int
    let panel: String?
}

private final class WorkspaceWindowController: NSObject, NSWindowDelegate, NSMenuItemValidation, NSToolbarDelegate, LocalProcessTerminalViewDelegate {
    weak var owner: AppDelegate?
    private(set) var savedSnapshot: WindowSnapshot?
    var isOpen: Bool { openedWorkspace }
    var nsWindow: NSWindow { window }
    var workspaceID: UUID { workspace.id }

    init(owner: AppDelegate) {
        self.owner = owner
        super.init()
        buildWindow()
        // Terminals take their group's colors when groups change or terminals move.
        schemeWatch = workspace.$activityBoards
            .map { $0.boards.map { [String($0.id), $0.colorScheme ?? ""] + $0.slots.map(String.init) } }
            .removeDuplicates()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.applySchemes() } }
    }
    private var schemeWatch: AnyCancellable?
    private var sessions: [Session] = []
    private let workspace = WorkspaceState()
    private let body = WorkspaceContentView()
    private var tabBarHeight: NSLayoutConstraint!
    private let navigationItem = NSToolbarItem.Identifier("bananaShell.navigation")
    private var window: ShellWindow!
    private lazy var keys = themedHost(rootView: PublicKeyPanel())
    private lazy var automations = themedHost(rootView: AutomationPanel(openRequest: workspace.openAutomation))
    private lazy var activity: NSHostingView<ThemedRoot<ActivityPanel>> = themedHost(rootView: ActivityPanel(state: workspace, terminalView: { [weak self] id in
        self?.sessions.first(where: { $0.id == id })?.view
    }, close: { [weak self] in self?.removeShell($0) }, create: { [weak self] in self?.createTerminalTab(selecting: false) },
       releaseFocus: { [weak self] in self?.releaseActivityFocus() },
       expand: { [weak self] id in self?.select(.shell(id)) }))
    private func releaseActivityFocus() { window.makeFirstResponder(activity) }

    private let themeDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/bananaShell/TerminalSessions" + PersistentTerminal.profileSuffix)
    private var terminalServer: PersistentTerminal?
    private var restoringWorkspace = false
    private var serial = 0
    private var lastShell: Int?
    private var openedWorkspace = false

    fileprivate func saveWindow() {
        guard openedWorkspace, !restoringWorkspace else { return }
        let panel: String?
        switch workspace.selected {
        case .keys: panel = "keys"
        case .settings: panel = "settings"
        case .activity: panel = "activity"
        case .automations: panel = "automations"
        case .themes: panel = "themes"
        case .extensions: panel = "extensions"
        case .shell: panel = nil
        }
        let directories = sessions.map(\.directory)
        let state = WindowSnapshot(frame: NSStringFromRect(window.frame), directories: directories, persistentIDs: sessions.map(\.persistentID),
                                   shortcutSlots: sessions.map(\.shortcutSlot), activityBoards: workspace.activityBoards,
                                   activityFocusedSlot: sessions.first { $0.id == workspace.activityTerminal }?.shortcutSlot, lastShellIndex: sessions.firstIndex { $0.id == lastShell } ?? 0, panel: panel)
        guard savedSnapshot != state else { return }
        savedSnapshot = state
        owner?.saveWindows()
    }

    func openWorkspace(snapshot: WindowSnapshot?, live: [PersistentTerminal.Pane], serverLost: Bool = false) {
        guard !openedWorkspace else { return }
        do { terminalServer = try owner?.terminalServer ?? PersistentTerminal() }
        catch { showTerminalError(error); return }
        openedWorkspace = true
        let prefs = UserDefaults.standard
        restoringWorkspace = true
        defer { restoringWorkspace = false; saveWindow() }
        if let state = snapshot, prefs.object(forKey: "restoreLastWindow") as? Bool ?? true {
            let frame = NSRectFromString(state.frame)
            if let screen = NSScreen.screens.max(by: {
                let a = $0.visibleFrame.intersection(frame), b = $1.visibleFrame.intersection(frame)
                return a.width * a.height < b.width * b.height
            }), screen.visibleFrame.intersects(frame) {
                var rect = frame
                let bounds = screen.visibleFrame
                rect.size.width = min(max(rect.width, window.minSize.width), bounds.width)
                rect.size.height = min(max(rect.height, window.minSize.height), bounds.height)
                rect.origin.x = min(max(rect.minX, bounds.minX), bounds.maxX - rect.width)
                rect.origin.y = min(max(rect.minY, bounds.minY), bounds.maxY - rect.height)
                window.setFrame(rect, display: false)
            }
        }
        var remaining = live
        if let snapshot {
            for (index, path) in snapshot.directories.enumerated() {
                let id = snapshot.persistentIDs.flatMap { $0.indices.contains(index) ? $0[index] : nil }
                let pane = id.flatMap { id in remaining.first { $0.id == id } }
                // With the server still running, a missing session exited or was closed.
                // When the whole server is gone (reboot, logout, crash), start fresh
                // shells in the saved folders under the same IDs and shortcut slots.
                // Legacy snapshots always recreate fresh shells from folders.
                guard pane != nil || snapshot.persistentIDs == nil || serverLost else { continue }
                createTerminalTab(selecting: false, directory: pane?.directory ?? path,
                                  restoredSlot: snapshot.shortcutSlots.flatMap { $0.indices.contains(index) ? $0[index] : nil },
                                  persistentID: pane?.id ?? id, recreating: pane == nil && id != nil)
                if let pane { remaining.removeAll { $0.id == pane.id } }
            }
        } else {
            // Lay out the group before starting its first PTY at the tile's size.
            select(.activity)
        }
        for pane in remaining {
            createTerminalTab(selecting: false, directory: pane.directory, restoredSlot: pane.slot, persistentID: pane.id)
        }
        if sessions.isEmpty && snapshot?.directories.isEmpty != true { createTerminalTab(selecting: false) }
        guard let snapshot else {
            if let first = sessions.first { focusTerminalInGrid(first.id) }
            return
        }
        var boards = snapshot.activityBoards ?? ActivityBoards()
        boards.reconcile(with: sessions.map(\.shortcutSlot))
        workspace.activityBoards = boards
        guard !sessions.isEmpty else { select(.activity); return }
        if let slot = snapshot.activityFocusedSlot, boards.current.visibleSlots.contains(slot) {
            workspace.activityTerminal = sessions.first { $0.shortcutSlot == slot }?.id
        }
        let lastIndex = snapshot.lastShellIndex
        let lastPersistentID = snapshot.persistentIDs.flatMap { $0.indices.contains(lastIndex) ? $0[lastIndex] : nil }
        lastShell = sessions.first { $0.persistentID == lastPersistentID }?.id ??
            sessions[sessions.indices.contains(lastIndex) ? lastIndex : 0].id
        if let panel = snapshot.panel, let tab = ["keys": WorkspaceTab.keys, "activity": .activity, "settings": .settings, "automations": .automations, "themes": .themes, "extensions": .extensions][panel] {
            select(tab)
        } else if let lastShell { select(.shell(lastShell)) }
    }

    private func buildWindow() {
        // Leave desktop space around a new window; restored windows keep their saved frame.
        let visibleWidth = NSScreen.main?.visibleFrame.width ?? 0
        let width: CGFloat = visibleWidth > 0 ? min(1600, floor(visibleWidth * 0.90)) : 1140
        let initialRect = NSRect(x: 0, y: 0, width: width, height: 560)
        window = ShellWindow(contentRect: initialRect,
                          styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.selectTabAtIndex = { [weak self] in self?.selectShellTab(at: $0) }
        window.navigateGridTabs = { [weak self] kind, target in
            guard let self, self.workspace.navigate(kind, to: target) else { return false }
            self.select(.activity)
            return true
        }
        window.canBrowsePages = { [weak self] in
            guard let self, self.workspace.selected == .activity, self.workspace.activityTerminal == nil,
                  !(self.window.firstResponder is NSText) else { return false }
            // A mouse click can focus a terminal before its published selection updates.
            guard let responder = self.window.firstResponder as? NSView else { return true }
            return !self.sessions.contains { responder === $0.view || responder.isDescendant(of: $0.view) }
        }
        window.responderChanged = { [weak self] responder in
            guard let self, self.workspace.selected == .activity, let view = responder as? NSView,
                  let session = self.sessions.first(where: { view === $0.view || view.isDescendant(of: $0.view) }),
                  self.workspace.activityBoards.current.visibleSlots.contains(session.shortcutSlot) else { return }
            if self.workspace.activityTerminal != session.id { self.workspace.activityTerminal = session.id }
        }
        window.tabbingMode = .disallowed
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = shellSurface
        window.title = "bananaShell"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unifiedCompact
        let toolbar = NSToolbar(identifier: "bananaShell.titlebar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.contentMinSize = NSSize(width: 440, height: 200)
        let bar = themedHost(rootView: TerminalToolbar(state: workspace, select: { [weak self] in self?.select($0) },
            focusTerminal: { [weak self] in self?.focusTerminalInGrid($0) },
            create: { [weak self] in
                guard let self else { return }
                self.createTerminalTab(selecting: self.workspace.selected != .activity)
            }, close: { [weak self] in self?.removeShell($0) },
            move: { [weak self] in self?.moveShell($0, to: $1) },
            receivePage: { [weak self] payload, group, page in
                guard let self else { return false }
                return self.owner?.moveItems(payload, to: self, group: group, page: page) ?? false
            }, receiveTerminal: { [weak self] payload, group, terminal in
                guard let self else { return false }
                return self.owner?.moveItems(payload, to: self, group: group, relativeTo: terminal) ?? false
            }))
        let root = NSView(frame: window.contentView?.bounds ?? initialRect)
        // AppKit owns this frame. An empty bar otherwise publishes a maximum
        // width of zero and collapses the window when a utility tab hides it.
        bar.sizingOptions = []
        window.contentView = root
        let contentGuide = window.contentLayoutGuide as! NSLayoutGuide
        for view in [bar as NSView, body] {
            root.addSubview(view)
            view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                                         view.trailingAnchor.constraint(equalTo: root.trailingAnchor)])
        }
        tabBarHeight = bar.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([bar.topAnchor.constraint(equalTo: contentGuide.topAnchor), tabBarHeight,
                                     body.topAnchor.constraint(equalTo: bar.bottomAnchor), body.bottomAnchor.constraint(equalTo: root.bottomAnchor)])
        window.center()
    }

    func show() {
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    var terminalIDs: [UUID] { sessions.map(\.persistentID) }

    /// The terminal the user is looking at in this window, if it is the key window.
    var visibleTerminal: UUID? {
        guard window.isKeyWindow, window.isVisible, !window.isMiniaturized else { return nil }
        let id: Int?
        switch workspace.selected {
        case .shell(let shell): id = shell
        case .activity: id = workspace.activityTerminal
        default: id = nil
        }
        return id.flatMap { id in sessions.first { $0.id == id }?.persistentID }
    }

    func notifyClaudeCompletion(_ event: ClaudeCompletion, using notch: ClaudeCompletionNotch,
                                notifications: AutomationNotifications) -> Bool {
        let id = event.pane
        guard let session = sessions.first(where: { $0.persistentID == id }) else { return false }
        let name = URL(fileURLWithPath: session.directory).lastPathComponent
        let title = name.isEmpty ? session.title : name
        switch AlertDestination.current {
        case .notch:
            notch.show(title: title, summary: event.summary, source: event.sender, screen: window.screen) { [weak self] in
                _ = self?.openTerminal(id)
            }
        case .notificationCenter:
            notifications.postCompletion(title: title, summary: event.summary, source: event.sender, pane: id)
        }
        return true
    }

    /// Reveals the terminal with this persistent ID, if this window owns it.
    func openTerminal(_ id: UUID) -> Bool {
        guard let session = sessions.first(where: { $0.persistentID == id }) else { return false }
        focusTerminalInGrid(session.id)
        show()
        return true
    }

    /// Groups and their terminals in shortcut order, for the notch terminal.
    var notchGroups: [NotchTerminalGroup] {
        workspace.activityBoards.boards.map { board in
            NotchTerminalGroup(id: board.id, title: board.title, terminals: board.slots.compactMap { slot in
                sessions.first { $0.shortcutSlot == slot }.map { session in
                    let name = URL(fileURLWithPath: session.directory).lastPathComponent
                    return NotchTerminalTarget(id: session.persistentID, title: name.isEmpty ? session.title : name,
                                               background: session.view.nativeBackgroundColor, scheme: scheme(of: session))
                }
            })
        }
    }

    /// A terminal created from the notch: in that group, in the folder of the one beside it.
    func createNotchTerminal(inGroup group: Int, near: UUID?) -> UUID? {
        guard workspace.activityBoards.boards.contains(where: { $0.id == group }) else { return nil }
        if workspace.activityBoards.selected != group { workspace.activityBoards.select(group) }
        let before = Set(sessions.map(\.persistentID))
        let directory = near.flatMap { id in sessions.first { $0.persistentID == id }?.directory }
        createTerminalTab(selecting: false, directory: directory)
        return sessions.first { !before.contains($0.persistentID) }?.persistentID
    }

    /// The terminal the user last looked at in this window.
    /// Prefers the terminal with keyboard focus, then the shown tab, the focused grid
    /// tile, the first terminal on the visible page, and finally the last shell.
    var lastTerminal: UUID? {
        if let responder = window.firstResponder as? NSView,
           let session = sessions.first(where: { responder === $0.view || responder.isDescendant(of: $0.view) }) {
            return session.persistentID
        }
        let board = workspace.activityBoards.current
        let visible = board.visibleSlots.first.flatMap { slot in sessions.first { $0.shortcutSlot == slot }?.id }
        let id: Int?
        switch workspace.selected {
        case .shell(let shell): id = shell
        case .activity: id = workspace.activityTerminal ?? visible
        default: id = lastShell ?? visible
        }
        return (id.flatMap { id in sessions.first { $0.id == id } }
            ?? board.slots.lazy.compactMap { slot in self.sessions.first { $0.shortcutSlot == slot } }.first
            ?? sessions.first)?.persistentID
    }

    func openAutomation(_ id: UUID) {
        workspace.openAutomation.send(id)
        select(.automations)
        show()
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [navigationItem] }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [navigationItem] }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard identifier == navigationItem else { return nil }
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = "Workspace tabs"
        let host = themedHost(rootView: FavoriteTabs(state: workspace, select: { [weak self] in self?.select($0) },
            detach: { [weak self] id, point in self?.detachGroup(id, at: point) },
            receiveDrop: { [weak self] payload, group in
                guard let self else { return false }
                return self.owner?.moveItems(payload, to: self, group: group) ?? false
            }, receiveGroup: { [weak self] payload in
                guard let self else { return false }
                return self.owner?.moveGroup(payload, to: self) ?? false
            }, closeGroup: { [weak self] id in self?.closeGroup(id) }))
        host.sizingOptions = []
        host.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        host.heightAnchor.constraint(equalToConstant: WorkspaceTabMetrics.height).isActive = true
        item.view = host
        item.autovalidates = false
        if #available(macOS 26, *) { item.isBordered = false; item.isNavigational = true }
        return item
    }

    private lazy var settings = themedHost(rootView: PromptSettings { [weak self] in self?.owner?.applyTheme() })
    private lazy var themes = themedHost(rootView: ThemeMarketplaceView())
    private lazy var extensions = themedHost(rootView: ExtensionMarketplaceView())
    @objc func showPromptSettings(_ sender: Any?) { select(.settings) }
    func showMarketplace(_ tab: WorkspaceTab) { select(tab); show() }

    private func writeTheme() throws {
        try FileManager.default.createDirectory(at: themeDirectory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try PromptSetup.liveConfiguration().write(to: themeDirectory.appendingPathComponent("state"), atomically: true, encoding: .utf8)
    }
    private func refreshPrompt(_ sessionID: Int) {
        guard let session = sessions.first(where: { $0.id == sessionID }) else { return }
        let fd = open(themeDirectory.appendingPathComponent(session.persistentID.uuidString).path, O_RDWR | O_NONBLOCK)
        if fd >= 0 { var byte: UInt8 = 10; _ = write(fd, &byte, 1); Darwin.close(fd) }
    }
    func applyTheme() {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let color = PromptSetup.background(forShell: shell)
        do { try writeTheme() } catch { NSLog("Could not update prompt: %@", error.localizedDescription); return }
        let font = terminalFont(size: 14)
        for session in sessions {
            if session.view.font.fontName != font.fontName { session.view.font = font }
            refreshPrompt(session.id)
        }
        applySchemes()
        let surface = ThemeStore.shared.scheme(for: nil)?.backgroundColor ?? color
        workspace.tabColor = surface
        window.backgroundColor = surface
    }

    /// Terminal colors only: each group's own scheme, else the theme's.
    func applySchemes() {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let fallback = PromptSetup.background(forShell: shell)
        let boards = workspace.activityBoards.boards
        for session in sessions {
            let choice = boards.first { $0.slots.contains(session.shortcutSlot) }?.colorScheme
            TerminalTheme.apply(ThemeStore.shared.scheme(for: choice), to: session.view, defaultBackground: fallback)
        }
    }

    private func scheme(of session: Session) -> ThemeScheme? {
        ThemeStore.shared.scheme(for: workspace.activityBoards.boards.first { $0.slots.contains(session.shortcutSlot) }?.colorScheme)
    }

    func detachTerminals() {
        guard openedWorkspace else { return }
        saveWindow()
        // These are tmux clients, not the shells owned by the server.
        window.makeFirstResponder(nil)
        for session in sessions {
            session.view.processDelegate = nil
            session.view.removeFromSuperview()
            session.view.terminate()
        }
        sessions.removeAll()
        openedWorkspace = false
        // A closed window retains only its saved layout, not a terminal view's
        // potentially large screen/scrollback buffer through its content host.
        body.show(NSView(), inset: 0)
        if !workspace.tabs.isEmpty { workspace.tabs = [] }
    }

    private func showTerminalError(_ error: Error) {
        NSLog("Persistent terminal error: %@", error.localizedDescription)
        let alert = NSAlert()
        alert.messageText = "Could not connect to persistent terminals"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc func newGroup(_ sender: Any?) {
        workspace.activityBoards.add()
        workspace.activityTerminal = nil
        select(.activity)
    }

    private func closeGroup(_ id: Int) {
        guard openedWorkspace, let board = workspace.activityBoards.boards.first(where: { $0.id == id }) else { return }
        let wasActive = workspace.activityBoards.selected == id
        let closing = sessions.filter { board.slots.contains($0.shortcutSlot) }
        do { try terminalServer?.kill(closing.map(\.persistentID)) }
        catch { showTerminalError(error); return }
        for session in closing {
            removeClosedShell(session.id, closingWindowWhenEmpty: false, refreshing: false)
        }
        if workspace.activityBoards.boards.count == 1 {
            owner?.discard(self)
            window.close()
            owner?.saveWindows()
            return
        }
        workspace.activityBoards.close(id)
        if wasActive && workspace.selected.showsTerminals { select(.activity) }
        else { refresh() }
    }

    private func detachGroup(_ id: Int, at point: NSPoint) {
        guard let owner, window.attachedSheet == nil,
              let board = workspace.activityBoards.boards.first(where: { $0.id == id }) else { return }
        owner.moveGroup { destination in
            let closesSource = workspace.activityBoards.boards.count == 1
            let moved = sessions.filter { board.slots.contains($0.shortcutSlot) }
            let movedIDs = Set(moved.map(\.id))
            let focused = workspace.activityTerminal.flatMap { movedIDs.contains($0) ? $0 : nil }
            window.makeFirstResponder(nil)
            sessions.removeAll { movedIDs.contains($0.id) }
            _ = workspace.activityBoards.detach(id)
            if focused != nil { workspace.activityTerminal = nil }
            if let lastShell, movedIDs.contains(lastShell) { self.lastShell = sessions.first?.id }
            for session in moved { session.view.removeFromSuperview() }
            if case let .shell(selected) = workspace.selected, movedIDs.contains(selected) { select(.activity) }
            refresh()

            // Move the existing SwiftTerm views and clients. No shell is restarted or reattached.
            destination.sessions = moved
            destination.serial = moved.map(\.id).max() ?? 0
            destination.terminalServer = terminalServer
            destination.workspace.tabColor = workspace.tabColor
            destination.workspace.activityBoards = ActivityBoards(board: board)
            destination.workspace.activityTerminal = focused
            destination.lastShell = focused ?? moved.first?.id
            destination.openedWorkspace = true
            for session in moved { session.view.processDelegate = destination }
            destination.position(at: point, size: window.frame.size)
            destination.select(.activity)
            destination.refresh()
            destination.show()
            if closesSource {
                owner.discard(self)
                window.close()
            }
        }
    }

    private func position(at point: NSPoint, size: NSSize) {
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? window.screen ?? NSScreen.main
        let bounds = screen?.visibleFrame ?? NSRect(origin: .zero, size: size)
        let width = min(size.width, bounds.width), height = min(size.height, bounds.height)
        let origin = NSPoint(x: min(max(point.x - 100, bounds.minX), bounds.maxX - width),
                             y: min(max(point.y - height + 20, bounds.minY), bounds.maxY - height))
        window.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: false)
    }

    func moveGroup(_ payload: WorkspaceGroupDragPayload, to destination: WorkspaceWindowController) -> Bool {
        guard self !== destination, payload.sourceWindow == workspace.id,
              window.attachedSheet == nil, destination.window.attachedSheet == nil,
              let board = workspace.activityBoards.boards.first(where: { $0.id == payload.sourceGroup }) else { return false }
        let moved = board.slots.compactMap { slot in sessions.first { $0.shortcutSlot == slot } }
        guard moved.count == board.slots.count else { return false }
        let closesSource = workspace.activityBoards.boards.count == 1
        let movedIDs = Set(moved.map(\.id))
        let focusedIndex = moved.firstIndex { $0.id == workspace.activityTerminal }
        window.makeFirstResponder(nil)
        sessions.removeAll { movedIDs.contains($0.id) }
        _ = workspace.activityBoards.detach(board.id)
        if focusedIndex != nil { workspace.activityTerminal = nil }
        if let lastShell, movedIDs.contains(lastShell) { self.lastShell = sessions.first?.id }
        for session in moved { session.view.removeFromSuperview() }
        if case let .shell(id) = workspace.selected, movedIDs.contains(id) { select(.activity) }
        refresh()

        let received = destination.adopt(moved, server: terminalServer)
        destination.workspace.activityBoards.receiveGroup(board, slots: received.map(\.shortcutSlot))
        destination.workspace.activityTerminal = focusedIndex.map { received[$0].id }
        destination.lastShell = destination.workspace.activityTerminal ?? received.first?.id
        destination.select(.activity)
        destination.saveWindow()
        destination.show()
        if closesSource {
            owner?.discard(self)
            window.close()
        }
        return true
    }

    // Transfer ownership of live views, preserving their clients and persistent IDs.
    // The returned sessions stay in the caller's page order, not shortcut order.
    private func adopt(_ moved: [Session], server: PersistentTerminal?) -> [Session] {
        if terminalServer == nil { terminalServer = server }
        var received: [Session] = []
        for session in moved {
            let slot = TerminalSlots.assign(occupied: (sessions + received).map(\.shortcutSlot), preferred: session.shortcutSlot)
            serial += 1
            let replacement = Session(serial, session.view, session.title, shortcutSlot: slot, persistentID: session.persistentID)
            replacement.directory = session.directory
            replacement.hasReportedDirectory = session.hasReportedDirectory
            replacement.pane = session.pane
            replacement.view.processDelegate = self
            received.append(replacement)
            if slot != session.shortcutSlot {
                do { try terminalServer?.setShortcutSlot(slot, for: session.persistentID) }
                catch { NSLog("Could not update terminal shortcut metadata: %@", error.localizedDescription) }
            }
        }
        sessions += received
        sessions.sort { $0.shortcutSlot < $1.shortcutSlot }
        return received
    }

    func moveItems(_ payload: WorkspaceDragPayload, to destination: WorkspaceWindowController, group: Int, page: Int? = nil, relativeTo terminal: Int? = nil) -> Bool {
        guard payload.sourceWindow == workspace.id, !payload.slots.isEmpty,
              Set(payload.slots).count == payload.slots.count,
              window.attachedSheet == nil, destination.window.attachedSheet == nil,
              let sourceBoard = workspace.activityBoards.boards.first(where: { $0.id == payload.sourceGroup }),
              payload.slots.allSatisfy(sourceBoard.slots.contains),
              let target = destination.workspace.activityBoards.boards.first(where: { $0.id == group }) else { return false }
        if let page {
            guard !payload.isPage, payload.slots.count == 1, (0..<target.pageCount).contains(page) else { return false }
        }
        if let terminal {
            guard !payload.isPage, payload.slots.count == 1, target.slots.contains(terminal) else { return false }
        }
        let moved = payload.slots.compactMap { slot in sessions.first { $0.shortcutSlot == slot } }
        guard moved.count == payload.slots.count else { return false }
        if self === destination {
            guard workspace.activityBoards.transfer(payload.slots, from: payload.sourceGroup, to: group, asPage: payload.isPage, on: page, relativeTo: terminal) else { return false }
            workspace.activityTerminal = payload.isPage ? nil : moved.first?.id
            lastShell = moved.first?.id
            select(.activity)
            saveWindow()
            return true
        }

        // Keep the live terminal view/client, assigning only window-local IDs and
        // available storage slots. Persistent session IDs and processes do not change.
        let movedIDs = Set(moved.map(\.id))
        window.makeFirstResponder(nil)
        sessions.removeAll { movedIDs.contains($0.id) }
        for slot in payload.slots { workspace.activityBoards.remove(slot) }
        if let focused = workspace.activityTerminal, movedIDs.contains(focused) { workspace.activityTerminal = nil }
        if let lastShell, movedIDs.contains(lastShell) { self.lastShell = sessions.first?.id }
        for session in moved { session.view.removeFromSuperview() }
        if case let .shell(id) = workspace.selected, movedIDs.contains(id) { select(.activity) }
        refresh()

        let received = destination.adopt(moved, server: terminalServer)
        destination.workspace.activityBoards.receive(received.map(\.shortcutSlot), in: group, asPage: payload.isPage, on: page, relativeTo: terminal)
        destination.workspace.activityTerminal = payload.isPage ? nil : received.first?.id
        destination.lastShell = received.first?.id
        destination.select(.activity)
        destination.saveWindow()
        destination.show()
        return true
    }

    @objc func newPage(_ sender: Any?) {
        select(.activity)
        createTerminalTab(selecting: false, startingPage: true)
    }

    @objc func newTab(_ sender: Any?) { createTerminalTab(selecting: workspace.selected != .activity) }

    private func createTerminalTab(selecting: Bool, directory: String? = nil, restoredSlot: Int? = nil, startingPage: Bool = false, persistentID: UUID? = nil, recreating: Bool = false) {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        window.contentView?.layoutSubtreeIfNeeded()
        let initialDirectory = directory ?? FileManager.default.homeDirectoryForCurrentUser.path
        let initialFrame: CGRect
        if workspace.selected == .activity, body.bounds.width > 0, body.bounds.height > 0 {
            let layout = ActivityTileLayout(viewport: body.bounds.size, grid: workspace.activityBoards.current.grid)
            initialFrame = CGRect(origin: .zero, size: layout.terminalSize)
        } else {
            initialFrame = body.contentFrame(inset: WorkspaceContentView.terminalInset) ?? .zero
        }
        let terminal = ComposingProcessTerminalView(frame: initialFrame)
        terminal.font = terminalFont(size: 14)
        terminal.lineSpacing = 1.15
        terminal.nativeBackgroundColor = PromptSetup.background(forShell: shell)
        terminal.nativeForegroundColor = NSColor(white: 0.93, alpha: 1)
        serial += 1
        let slot = TerminalSlots.assign(occupied: sessions.map(\.shortcutSlot), preferred: restoredSlot)
        let session = Session(serial, terminal, "\(URL(fileURLWithPath: shell).lastPathComponent) · \(serial)", shortcutSlot: slot, persistentID: persistentID ?? UUID())
        session.directory = initialDirectory
        do {
            if terminalServer == nil { terminalServer = try PersistentTerminal() }
            let server = terminalServer!
            var environment = Terminal.getEnvironmentVariables() + ShellPluginStartup.environment
            if persistentID == nil || recreating {
                if URL(fileURLWithPath: shell).lastPathComponent == "zsh", let folder = PromptSetup.shellFolder {
                    try writeTheme()
                    let token = session.persistentID.uuidString
                    let fifo = themeDirectory.appendingPathComponent(token).path
                    guard mkfifo(fifo, 0o600) == 0 || errno == EEXIST else {
                        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                    }
                    environment += ["ZDOTDIR=" + folder.path, "BANANA_STARTUP_DIR=" + folder.path,
                        "BANANA_LIMITS_BASE=" + themeDirectory.appendingPathComponent("limits-" + token).path,
                        "BANANA_THEME_STATE=" + themeDirectory.appendingPathComponent("state").path, "BANANA_THEME_FIFO=" + fifo]
                }
                let env = Dictionary(environment.compactMap { entry -> (String, String)? in
                    guard let i = entry.firstIndex(of: "=") else { return nil }
                    return (String(entry[..<i]), String(entry[entry.index(after: i)...]))
                }, uniquingKeysWith: { _, new in new })
                var isDirectory: ObjCBool = false
                let valid = FileManager.default.fileExists(atPath: initialDirectory, isDirectory: &isDirectory) && isDirectory.boolValue
                let dimensions = terminal.terminalDimensions
                try server.create(id: session.persistentID, slot: slot, shell: shell,
                                  workingDirectory: valid ? initialDirectory : FileManager.default.homeDirectoryForCurrentUser.path,
                                  columns: dimensions.cols, rows: dimensions.rows, environment: env)
            }
            let insertion = restoredSlot == nil ? sessions.firstIndex(where: { $0.shortcutSlot > slot }) ?? sessions.count : sessions.count
            sessions.insert(session, at: insertion)
            workspace.activityBoards.insert(slot, startingPage: startingPage)
            if workspace.selected == .activity { workspace.activityTerminal = serial }
            terminal.processDelegate = self
            let persistentID = session.persistentID
            terminal.leaveScrollback = { server.leaveCopyMode(persistentID) }
            terminal.contextActions = TerminalContextActions(
                wantsMouse: { server.wantsMouse(persistentID) },
                directory: { [weak session] in session?.directory },
                clearScrollback: { server.clearScrollback(persistentID) },
                inCopyMode: { server.inCopyMode(persistentID) },
                diagnostics: { server.diagnostics(persistentID) })
            if selecting { select(.shell(serial)) }
            terminal.startProcess(executable: server.executable.path, args: server.attachment(session.persistentID),
                                  environment: Terminal.getEnvironmentVariables(), currentDirectory: FileManager.default.homeDirectoryForCurrentUser.path)
        } catch { showTerminalError(error); return }
        refresh()
        if !restoringWorkspace { owner?.requestTerminalStatus() }
    }

    private func focusTerminalInGrid(_ id: Int) {
        guard let session = sessions.first(where: { $0.id == id }) else { return }
        workspace.activityBoards.reveal(session.shortcutSlot)
        workspace.activityTerminal = id
        lastShell = id
        if workspace.selected != .activity { select(.activity) }
        // Existing tiles can focus immediately, including a repeated tab click.
        // A tile on another page takes focus when ActivityTerminal mounts it.
        if session.view.window === window { window.makeFirstResponder(session.view) }
        saveWindow()
    }

    private func select(_ tab: WorkspaceTab) {
        let view: NSView
        var inset: CGFloat = 0
        workspace.titleDirectory = ""
        switch tab {
        case .settings: view = settings
        case .keys: view = keys
        case .activity: view = activity
        case .automations: view = automations
        case .themes: view = themes
        case .extensions: view = extensions
        case .shell(let id):
            guard let session = sessions.first(where: { $0.id == id }) else { return }
            workspace.activityBoards.reveal(session.shortcutSlot)
            lastShell = id
            view = session.view
            inset = WorkspaceContentView.terminalInset
            if session.hasReportedDirectory { workspace.titleDirectory = session.directory }
        }
        workspace.tabColor = (view as? LocalProcessTerminalView)?.nativeBackgroundColor ?? workspace.tabColor
        window.backgroundColor = workspace.tabColor
        tabBarHeight.constant = tab.showsTerminals ? 36 : 0
        workspace.selected = tab
        if tab == .activity { refresh() }
        window.contentView?.layoutSubtreeIfNeeded()
        body.show(view, inset: inset)
        window.makeFirstResponder(view)
    }

    private func removeShell(_ id: Int, closingWindowWhenEmpty: Bool = true) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        do { try terminalServer?.kill(sessions[index].persistentID) }
        catch { showTerminalError(error); return }
        removeClosedShell(id, closingWindowWhenEmpty: closingWindowWhenEmpty)
    }

    private func removeClosedShell(_ id: Int, closingWindowWhenEmpty: Bool, refreshing: Bool = true) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        let session = sessions.remove(at: index)
        workspace.activityBoards.remove(session.shortcutSlot)
        let wasActive = workspace.activityTerminal == id
        if wasActive { workspace.activityTerminal = nil }
        if wasActive && workspace.selected == .activity { window.makeFirstResponder(activity) }
        try? FileManager.default.removeItem(at: themeDirectory.appendingPathComponent(session.persistentID.uuidString))
        session.view.processDelegate = nil
        session.view.removeFromSuperview()
        session.view.terminate()
        if sessions.isEmpty {
            lastShell = nil
            if closingWindowWhenEmpty {
                saveWindow()
                owner?.discard(self)
                window.close()
                owner?.saveWindows()
            } else if refreshing {
                if case .shell = workspace.selected { select(.activity) }
                refresh()
            }
            return
        }
        let neighbor = sessions[min(index, sessions.count - 1)].id
        if lastShell == id { lastShell = neighbor }
        guard refreshing else { return }
        if workspace.selected == .shell(id) {
            if let slot = workspace.activityBoards.current.visibleSlots.first,
               let next = sessions.first(where: { $0.shortcutSlot == slot }) { select(.shell(next.id)) }
            else { select(.activity) }
        }
        refresh()
    }

    @objc func closeTab(_ sender: Any?) {
        if case let .shell(id) = workspace.selected { removeShell(id) }
        else if let lastShell { select(.shell(lastShell)) }
    }

    private func moveShell(_ sourceID: Int, to targetID: Int) {
        guard let source = sessions.first(where: { $0.id == sourceID }), let target = sessions.first(where: { $0.id == targetID }) else { return }
        workspace.activityBoards.reorder(source.shortcutSlot, to: target.shortcutSlot)
        if let focused = workspace.tabs.first(where: { $0.id == workspace.activityTerminal }), workspace.selected == .activity {
            workspace.activityBoards.reveal(focused.shortcutSlot)
        }
        saveWindow()
    }

    @objc func selectTab(_ sender: NSMenuItem) {
        selectShellTab(at: sender.tag)
    }

    private func selectShellTab(at index: Int) {
        guard window?.isKeyWindow == true, window.attachedSheet == nil,
              let id = workspace.terminal(at: index)?.id else { return }
        if workspace.selected == .activity { workspace.focusActivityTerminal.send(id) }
        else { select(.shell(id)) }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(selectTab(_:)) {
            return window?.isKeyWindow == true && workspace.terminal(at: menuItem.tag) != nil
        }
        return true
    }

    private func cycle(_ step: Int) {
        if case .shell = workspace.selected {
            let tabs: [WorkspaceTab] = workspace.activityBoards.current.slots.compactMap { slot in
                sessions.first { $0.shortcutSlot == slot }.map { .shell($0.id) }
            }
            if let i = tabs.firstIndex(of: workspace.selected) { select(tabs[(i + step + tabs.count) % tabs.count]) }
            return
        }
        // A nil board ID denotes a utility tab; each grid has its own stop.
        // Same order as the bar: group tabs, then the utility tabs on the right.
        let tabs: [(WorkspaceTab, Int?)] = workspace.activityBoards.boards.map { (.activity, $0.id) }
            + [(.keys, nil), (.automations, nil), (.themes, nil), (.extensions, nil), (.settings, nil)]
        let i = tabs.firstIndex { $0.0 == workspace.selected && ($0.1 == nil || $0.1 == workspace.activityBoards.selected) } ?? 0
        let next = tabs[(i + step + tabs.count) % tabs.count]
        if let id = next.1 { workspace.activityTerminal = nil; workspace.activityBoards.select(id) }
        select(next.0)
    }
    @objc func nextTab(_ sender: Any?) { cycle(1) }
    @objc func previousTab(_ sender: Any?) { cycle(-1) }
    // Closing a window by hand ends its terminals, so it is not restored on the
    // next launch. Quitting the app keeps every window and terminal for later.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard openedWorkspace, !sessions.isEmpty else {
            owner?.discard(self)
            owner?.saveWindows()
            return true
        }
        guard window.attachedSheet == nil else { return false }
        let alert = NSAlert()
        alert.messageText = "Close this window?"
        let count = sessions.count
        alert.informativeText = "\(count) terminal\(count == 1 ? "" : "s") in this window will be terminated, and the window won't reopen next time."
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.closeWindowAndTerminals()
        }
        return false
    }

    private func closeWindowAndTerminals() {
        guard openedWorkspace else { return }
        let closing = sessions
        do { try terminalServer?.kill(closing.map(\.persistentID)) }
        catch { showTerminalError(error); return }
        // Removing the last terminal discards this window and closes it.
        for session in closing {
            removeClosedShell(session.id, closingWindowWhenEmpty: true, refreshing: false)
        }
    }

    func windowWillClose(_ notification: Notification) {
        detachTerminals()
    }
    fileprivate func refresh() {
        guard openedWorkspace else { return }
        let statuses = owner?.terminalStatuses ?? [:]
        let hostName = ProcessInfo.processInfo.hostName
        for session in sessions {
            if let pane = statuses[session.persistentID]?.pane, session.pane != pane {
                session.pane = pane
                session.directory = pane.directory
                session.hasReportedDirectory = true
                session.title = pane.title.isEmpty || pane.title == hostName ? pane.directory : pane.title
            }
        }
        let rows = sessions.map { session in
            let status = statuses[session.persistentID]
            return TabActivity(id: session.id, shortcutSlot: session.shortcutSlot, programIcon: status?.icon, name: session.title, status: status?.status ?? "Checking status",
                               directory: (session.hasReportedDirectory ? "" : "Started in: ") + (session.directory as NSString).abbreviatingWithTildeInPath,
                               busy: status?.busy ?? false, limits: status?.limits ?? [])
        }
        if workspace.tabs != rows { workspace.tabs = rows }
        if case .shell(let id) = workspace.selected, let session = sessions.first(where: { $0.id == id }) {
            if workspace.titleDirectory != session.directory { workspace.titleDirectory = session.directory }
        }
        saveWindow()
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        guard let session = sessions.first(where: { $0.view === source }), let server = terminalServer else { return }
        do {
            if try server.panes().contains(where: { $0.id == session.persistentID }) {
                // A detached or failed client must never kill a still-running session.
                session.view.feed(text: "\r\n[Session is still running. Reopen bananaShell to reconnect.]\r\n")
            } else { removeShell(session.id) }
        } catch { showTerminalError(error) }
    }
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        guard let directory, !directory.isEmpty, let session = sessions.first(where: { $0.view === source }) else { return }
        session.directory = URL(string: directory)?.path ?? directory
        session.hasReportedDirectory = true
        if workspace.selected == .shell(session.id) { workspace.titleDirectory = session.directory }
    }
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {
        // SwiftTerm already updated the PTY. Only theme changes should trigger a prompt refresh.
    }
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        if !title.isEmpty { sessions.first(where: { $0.view === source })?.title = title }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var windows: [WorkspaceWindowController] = []
    private var updatingWindows = false
    private var restored = false
    private let completions = ClaudeCompletionNotch()
    private let confirmations = AutomationNotifications()
    private let notchTerminal = NotchTerminal()
    private var notchWindow: WorkspaceWindowController? {
        windows.first { $0.isOpen && $0.nsWindow === NSApp.mainWindow } ?? windows.last { $0.isOpen }
    }
    private var notificationTimer: Timer?
    fileprivate private(set) var terminalServer: PersistentTerminal?
    fileprivate private(set) var terminalStatuses: [UUID: TerminalStatus] = [:]
    private var terminalPoller: TerminalStatusPoller<[UUID: TerminalStatus]>?
    private var lastSavedSnapshots: [WindowSnapshot]?
    /// Completed Claude responses per terminal that the user has not looked at yet.
    private var unseenCompletions: [UUID: Int] = [:] {
        didSet {
            guard unseenCompletions != oldValue else { return }
            let total = unseenCompletions.values.reduce(0, +)
            NSApp.dockTile.badgeLabel = total > 0 ? String(total) : nil
            // Recent macOS hides dock badges unless notification badges are allowed.
            UNUserNotificationCenter.current().setBadgeCount(total) { _ in }
        }
    }

    // Viewing a terminal reads its completions; closed terminals drop theirs.
    private func clearSeenCompletions() {
        guard !unseenCompletions.isEmpty, !updatingWindows else { return }
        let open = windows.filter(\.isOpen)
        let live = Set(open.flatMap(\.terminalIDs))
        var unseen = unseenCompletions.filter { live.contains($0.key) }
        if NSApp.isActive {
            for controller in open { if let id = controller.visibleTerminal { unseen[id] = nil } }
        }
        unseenCompletions = unseen
    }

    func applicationDidBecomeActive(_ notification: Notification) { clearSeenCompletions() }

    private var activeWindow: WorkspaceWindowController? {
        windows.first { $0.isOpen && $0.nsWindow === NSApp.keyWindow } ??
        windows.first { $0.isOpen && $0.nsWindow === NSApp.mainWindow } ?? windows.last { $0.isOpen }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        ThemeStore.shared.changed = { [weak self] in self?.applyTheme() }
        ThemeStore.shared.followAppearance()
        confirmations.openAutomation = { [weak self] id in
            guard let self else { return }
            self.ensureWorkspace().openAutomation(id)
        }
        confirmations.openTerminal = { [weak self] id in
            guard let self else { return }
            for controller in self.windows where controller.isOpen {
                if controller.openTerminal(id) { break }
            }
        }
        confirmations.presentQuestion = { [weak self] question in
            guard let self else { return }
            self.completions.showQuestion(id: question.id, automation: question.name, question: question.question,
                options: question.options, screen: self.activeWindow?.nsWindow.screen,
                open: { [weak self] in self?.confirmations.open(jobLabel: question.jobLabel) },
                answer: { [weak self] index in
                    self?.confirmations.respond(jobLabel: question.jobLabel, nonce: question.nonce, index: index)
                })
        }
        confirmations.retractQuestion = { [weak self] id in self?.completions.retract(id: id) }
        // A separate profile must not answer or display the real automations.
        if PersistentTerminal.profile == nil { confirmations.start() }
        notchTerminal.groups = { [weak self] in self?.notchWindow?.notchGroups ?? [] }
        notchTerminal.preferredTerminal = { [weak self] in self?.notchWindow?.lastTerminal }
        notchTerminal.server = { [weak self] in self?.terminalServer }
        notchTerminal.createTerminal = { [weak self] group, near in
            self?.notchWindow?.createNotchTerminal(inGroup: group, near: near)
        }
        notchTerminal.registerHotKey()
        notificationTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                // Save layout changes even if a slow metadata read is still in flight.
                if let self, !self.updatingWindows {
                    for controller in self.windows where controller.isOpen { controller.saveWindow() }
                }
                self?.requestTerminalStatus()
                if PersistentTerminal.profile == nil { self?.confirmations.poll() }
                if let self, let directory = self.terminalServer?.directory {
                    for event in ClaudeCompletion.drain(directory.appendingPathComponent("completions")) {
                        for controller in self.windows where controller.isOpen {
                            guard controller.notifyClaudeCompletion(event, using: self.completions, notifications: self.confirmations) else { continue }
                            // A response finished in the terminal being watched needs no badge.
                            if !(NSApp.isActive && controller.visibleTerminal == event.pane) {
                                self.unseenCompletions[event.pane, default: 0] += 1
                            }
                            break
                        }
                    }
                }
                self?.clearSeenCompletions()
            }
        }
        notificationTimer?.tolerance = 0.2
        if !CommandLine.arguments.contains("--automation-notification") {
            restoreWindows()
            AppUpdates.shared.start()
            #if DEBUG
            if CommandLine.arguments.contains("--show-notch-terminal") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.notchTerminal.toggle() }
            }
            #endif
        }
    }

    private func makeWindow() -> WorkspaceWindowController {
        let controller = WorkspaceWindowController(owner: self)
        windows.append(controller)
        return controller
    }

    private func restoreWindows() {
        guard !restored else { return }
        let live: [PersistentTerminal.Pane]
        let serverLost: Bool
        do {
            let server = try PersistentTerminal()
            serverLost = try !server.isRunning()
            live = try server.panes()
            terminalServer = server
            let directory = server.directory
            terminalStatuses = TerminalStatus.capture(live, directory: directory, server: server)
            terminalPoller = TerminalStatusPoller(read: {
                TerminalStatus.capture(try server.panes(), directory: directory, server: server)
            }, completion: { [weak self] result in
                guard let self else { return }
                if case .success(let statuses) = result { self.terminalStatuses = statuses }
                guard !self.updatingWindows else { return }
                for controller in self.windows where controller.isOpen { controller.refresh() }
            })
        }
        catch {
            let alert = NSAlert()
            alert.messageText = "Could not connect to persistent terminals"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            return
        }
        restored = true
        updatingWindows = true
        defer { updatingWindows = false; saveWindows(); requestTerminalStatus() }
        let prefs = UserDefaults.standard
        let decoder = JSONDecoder()
        let snapshots: [WindowSnapshot]
        if let data = prefs.data(forKey: "persistentWindowSnapshots"),
           let saved = try? decoder.decode([WindowSnapshot].self, from: data) {
            snapshots = saved
        } else if let data = prefs.data(forKey: "persistentWindowSnapshot") ??
            (prefs.bool(forKey: "restoreLastWindow") ? prefs.data(forKey: "lastWindowSnapshot") : nil),
                  let saved = try? decoder.decode(WindowSnapshot.self, from: data) {
            snapshots = [saved]
        } else { snapshots = [] }
        if snapshots.isEmpty {
            let controller = makeWindow()
            controller.openWorkspace(snapshot: nil, live: live)
            controller.show()
            return
        }
        let knownIDs = Set(snapshots.flatMap { $0.persistentIDs ?? [] })
        var remaining = live
        for (index, snapshot) in snapshots.enumerated() {
            let ids = Set(snapshot.persistentIDs ?? [])
            // Recover unassigned sessions once, without stealing another window's terminals.
            let panes = remaining.filter { ids.contains($0.id) || (index == 0 && !knownIDs.contains($0.id)) }
            let assigned = Set(panes.map(\.id))
            remaining.removeAll { assigned.contains($0.id) }
            let controller = makeWindow()
            controller.openWorkspace(snapshot: snapshot, live: panes, serverLost: serverLost)
            controller.show()
        }
    }

    fileprivate func saveWindows() {
        guard restored, !updatingWindows else { return }
        let snapshots = windows.compactMap(\.savedSnapshot)
        guard lastSavedSnapshots != snapshots else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        if let data = try? encoder.encode(snapshots) {
            if data != UserDefaults.standard.data(forKey: "persistentWindowSnapshots") {
                UserDefaults.standard.set(data, forKey: "persistentWindowSnapshots")
            }
            lastSavedSnapshots = snapshots
        }
    }

    fileprivate func requestTerminalStatus() {
        guard restored, !updatingWindows, windows.contains(where: \.isOpen) else { return }
        terminalPoller?.request()
    }

    private func ensureWorkspace() -> WorkspaceWindowController {
        if !restored { restoreWindows() }
        if let activeWindow { return activeWindow }
        let controller = makeWindow()
        controller.openWorkspace(snapshot: nil, live: [])
        controller.show()
        return controller
    }

    @objc func newWindow(_ sender: Any?) {
        if !restored { restoreWindows(); return }
        let source = activeWindow?.nsWindow
        let controller = makeWindow()
        controller.openWorkspace(snapshot: nil, live: [])
        if let source {
            let origin = NSPoint(x: source.frame.minX + 24, y: source.frame.maxY - 24)
            controller.nsWindow.cascadeTopLeft(from: origin)
        }
        controller.show()
    }

    fileprivate func moveGroup(_ transfer: (WorkspaceWindowController) -> Void) {
        updatingWindows = true
        let destination = makeWindow()
        transfer(destination)
        updatingWindows = false
        saveWindows()
    }

    fileprivate func moveGroup(_ payload: WorkspaceGroupDragPayload, to destination: WorkspaceWindowController) -> Bool {
        guard let source = windows.first(where: { $0.isOpen && $0.workspaceID == payload.sourceWindow }) else { return false }
        updatingWindows = true
        defer { updatingWindows = false; saveWindows() }
        return source.moveGroup(payload, to: destination)
    }

    fileprivate func moveItems(_ payload: WorkspaceDragPayload, to destination: WorkspaceWindowController, group: Int, page: Int? = nil, relativeTo terminal: Int? = nil) -> Bool {
        guard let source = windows.first(where: { $0.isOpen && $0.workspaceID == payload.sourceWindow }) else { return false }
        updatingWindows = true
        defer { updatingWindows = false; saveWindows() }
        return source.moveItems(payload, to: destination, group: group, page: page, relativeTo: terminal)
    }

    fileprivate func discard(_ controller: WorkspaceWindowController) {
        windows.removeAll { $0 === controller }
    }

    fileprivate func applyTheme() {
        for controller in windows where controller.isOpen { controller.applyTheme() }
    }

    @objc func showPromptSettings(_ sender: Any?) { ensureWorkspace().showPromptSettings(sender) }

    @objc func showThemeMarketplace(_ sender: Any?) { openMarketplace(.themes) }
    @objc func showExtensionMarketplace(_ sender: Any?) { openMarketplace(.extensions) }

    /// The marketplace is a sidebar tab of the active window.
    private func openMarketplace(_ tab: WorkspaceTab) {
        (activeWindow ?? ensureWorkspace()).showMarketplace(tab)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// `.bananatheme` files and `bananashell://theme?id=…` or `?url=https://…` links.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if url.isFileURL {
                do { ThemeStore.shared.pending = try ThemeStore.importTheme(from: url); openMarketplace(.themes) }
                catch { presentThemeError(error) }
            } else if url.scheme?.lowercased() == "bananashell", url.host?.lowercased() == "theme" {
                Task { @MainActor in
                    do { ThemeStore.shared.pending = try await ThemeStore.shared.resolve(link: url); openMarketplace(.themes) }
                    catch { presentThemeError(error) }
                }
            }
        }
    }

    private func presentThemeError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "The theme could not be opened."
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }

    @objc func toggleNotchTerminal(_ sender: Any?) { notchTerminal.toggle() }
    @objc func newGroup(_ sender: Any?) { ensureWorkspace().newGroup(sender) }
    @objc func newPage(_ sender: Any?) { ensureWorkspace().newPage(sender) }
    @objc func newTab(_ sender: Any?) { ensureWorkspace().newTab(sender) }
    @objc func closeTab(_ sender: Any?) { activeWindow?.closeTab(sender) }
    @objc func nextTab(_ sender: Any?) { activeWindow?.nextTab(sender) }
    @objc func previousTab(_ sender: Any?) { activeWindow?.previousTab(sender) }
    @objc func selectTab(_ sender: NSMenuItem) { activeWindow?.selectTab(sender) }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(newWindow(_:)) || menuItem.action == #selector(showPromptSettings(_:))
            || menuItem.action == #selector(showThemeMarketplace(_:))
            || menuItem.action == #selector(showExtensionMarketplace(_:)) { return true }
        if menuItem.action == #selector(toggleNotchTerminal(_:)) { return terminalServer != nil }
        return activeWindow?.validateMenuItem(menuItem) ?? false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows && sender.isActive { ensureWorkspace().show() }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        terminalPoller?.invalidate()
        completions.stop()
        for controller in windows { controller.detachTerminals() }
        notificationTimer?.invalidate()
        saveWindows()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

// After every top-level global above is initialized (fonts, colors).
#if DEBUG
MainActor.assumeIsolated { DebugSnapshots.renderIfRequested() }
#endif

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    let menu = NSMenu()
    for (name, items) in [
        ("bananaShell", [("About bananaShell", "orderFrontStandardAboutPanel:", ""), ("Check for Updates…", "checkForUpdates:", ""), ("Prompt Settings…", "showPromptSettings:", ","), ("Theme Marketplace…", "showThemeMarketplace:", ""), ("Extension Marketplace…", "showExtensionMarketplace:", ""), ("Quit bananaShell", "terminate:", "q")]),
        ("Shell", [("New Window", "newWindow:", CreationKeys.shared.windowKey), ("New Group", "newGroup:", CreationKeys.shared.key("Group")), ("New Page", "newPage:", CreationKeys.shared.key("Page")), ("New Terminal", "newTab:", CreationKeys.shared.key("Terminal")), ("Close Tab", "closeTab:", "w"), ("Notch Terminal", "toggleNotchTerminal:", "`"),
                   ("Next Tab", "nextTab:", "}"), ("Previous Tab", "previousTab:", "{")]),
        ("Edit", [("Copy", "copy:", "c"), ("Paste", "paste:", "v")])
    ] {
        let submenu = NSMenu(title: name)
        menu.addItem(withTitle: name, action: nil, keyEquivalent: "").submenu = submenu
        for (title, action, key) in items {
            let item = submenu.addItem(withTitle: title, action: NSSelectorFromString(action), keyEquivalent: key)
            if name == "Shell" || action == "showPromptSettings:" { item.target = delegate }
            if action == "checkForUpdates:" { item.target = AppUpdates.shared }
        }
        if name == "Shell" {
            submenu.addItem(.separator())
            for (index, key) in ShellTabShortcuts.keys.enumerated() {
                let item = submenu.addItem(withTitle: "Go to Terminal \(index + 1)",
                                           action: #selector(AppDelegate.selectTab(_:)), keyEquivalent: key)
                item.keyEquivalentModifierMask = NavigationKeys.shared.modifier(.terminal).flags
                item.tag = index
                item.target = delegate
            }
        }
    }
    if let item = menu.item(withTitle: "Shell")?.submenu?.item(withTitle: "Notch Terminal") {
        let shortcut = NotchTerminalKey.shared.current
        item.keyEquivalent = shortcut.menuKey
        item.keyEquivalentModifierMask = shortcut.flags
    }
    for name in CreationKeys.actions {
        menu.item(withTitle: "Shell")?.submenu?.item(withTitle: "New " + name)?.keyEquivalentModifierMask = CreationKeys.shared.modifier(name).flags
    }
    app.mainMenu = menu
    app.run()
}
