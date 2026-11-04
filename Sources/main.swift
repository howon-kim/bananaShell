import AppKit
import SwiftTerm
import SwiftUI
import Carbon
import CoreText

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
    let base = NSFont(name: promptFontName, size: size) ?? NSFont(name: "JetBrainsMono-Regular", size: size) ?? .monospacedSystemFont(ofSize: size, weight: .regular)
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

private final class ShellWindow: NSWindow {
    var selectTabAtIndex: ((Int) -> Void)?
    var navigateGridTabs: ((GridTabKind, GridTabTarget) -> Bool)?
    var canBrowsePages: (() -> Bool)?
    var deactivateActivityTerminal: (() -> Bool)?
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
            if event.keyCode == UInt16(kVK_Escape), deactivateActivityTerminal?() == true { return }
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
    var title: String
    var directory = FileManager.default.currentDirectoryPath
    var hasReportedDirectory = false
    init(_ id: Int, _ view: LocalProcessTerminalView, _ title: String, shortcutSlot: Int) {
        self.id = id; self.view = view; self.title = title; self.shortcutSlot = shortcutSlot
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation, NSToolbarDelegate, LocalProcessTerminalViewDelegate {
    private var sessions: [Session] = []
    private let workspace = WorkspaceState()
    private let body = WorkspaceContentView()
    private var tabBarHeight: NSLayoutConstraint!
    private let navigationItem = NSToolbarItem.Identifier("bananaShell.navigation")
    private var window: ShellWindow!
    private lazy var keys = NSHostingView(rootView: PublicKeyPanel(generateRequest: workspace.generateKey, importRequest: workspace.importKey))
    private lazy var automations = NSHostingView(rootView: AutomationPanel(addRequest: workspace.addAutomation))
    private lazy var activity: NSHostingView<ActivityPanel> = NSHostingView(rootView: ActivityPanel(state: workspace, terminalView: { [weak self] id in
        self?.sessions.first(where: { $0.id == id })?.view
    }, close: { [weak self] in self?.removeShell($0) }, create: { [weak self] in self?.createTerminalTab(selecting: false) },
       releaseFocus: { [weak self] in self?.releaseActivityFocus() },
       expand: { [weak self] id in self?.select(.shell(id)) }))
    private func releaseActivityFocus() { window.makeFirstResponder(activity) }

    private let themeDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("banana-theme-" + UUID().uuidString)
    private var serial = 0
    private var lastShell: Int?
    private var openedWorkspace = false

    private struct WindowSnapshot: Codable {
        let frame: String
        let directories: [String]
        let shortcutSlots: [Int]?
        let activityBoards: ActivityBoards?
        let activityFocusedSlot: Int?
        let lastShellIndex: Int
        let panel: String?
    }

    private func saveWindow() {
        guard openedWorkspace, !sessions.isEmpty, UserDefaults.standard.bool(forKey: "restoreLastWindow") else { return }
        let panel: String?
        switch workspace.selected {
        case .keys: panel = "keys"
        case .settings: panel = "settings"
        case .activity: panel = "activity"
        case .automations: panel = "automations"
        case .shell: panel = nil
        }
        let directories = sessions.map { session -> String in
            var info = proc_vnodepathinfo()
            let size = Int32(MemoryLayout.size(ofValue: info))
            if let pid = session.view.process?.shellPid, pid > 0,
               proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size {
                let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) {
                    String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self)
                }
                if !path.isEmpty { return path }
            }
            return session.directory
        }
        let state = WindowSnapshot(frame: NSStringFromRect(window.frame), directories: directories,
                                   shortcutSlots: sessions.map(\.shortcutSlot), activityBoards: workspace.activityBoards,
                                   activityFocusedSlot: sessions.first { $0.id == workspace.activityTerminal }?.shortcutSlot, lastShellIndex: sessions.firstIndex { $0.id == lastShell } ?? 0, panel: panel)
        if let data = try? JSONEncoder().encode(state) { UserDefaults.standard.set(data, forKey: "lastWindowSnapshot") }
    }

    private func openWorkspace() {
        guard !openedWorkspace else { return }
        openedWorkspace = true
        let prefs = UserDefaults.standard
        guard prefs.bool(forKey: "restoreLastWindow"), let data = prefs.data(forKey: "lastWindowSnapshot"),
              let state = try? JSONDecoder().decode(WindowSnapshot.self, from: data), !state.directories.isEmpty
        else { newTab(nil); return }
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
        for (index, path) in state.directories.enumerated() {
            var directory: ObjCBool = false
            let valid = FileManager.default.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue && FileManager.default.isExecutableFile(atPath: path)
            createTerminalTab(selecting: false, directory: valid ? path : FileManager.default.homeDirectoryForCurrentUser.path,
                              restoredSlot: state.shortcutSlots.flatMap { $0.indices.contains(index) ? $0[index] : nil })
        }
        var boards = state.activityBoards ?? ActivityBoards()
        boards.reconcile(with: sessions.map(\.shortcutSlot))
        workspace.activityBoards = boards
        if let slot = state.activityFocusedSlot, boards.current.visibleSlots.contains(slot) {
            workspace.activityTerminal = sessions.first { $0.shortcutSlot == slot }?.id
        }
        lastShell = sessions[sessions.indices.contains(state.lastShellIndex) ? state.lastShellIndex : 0].id
        if let panel = state.panel, let tab = ["keys": WorkspaceTab.keys, "activity": .activity, "settings": .settings, "automations": .automations][panel] {
            select(tab)
        } else if let lastShell { select(.shell(lastShell)) }
    }

    private let confirmations = AutomationNotifications()
    private var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Leave desktop space around a new window; restored windows keep their saved frame.
        let visibleWidth = NSScreen.main?.visibleFrame.width ?? 0
        let width: CGFloat = visibleWidth > 0 ? min(1600, floor(visibleWidth * 0.90)) : 1140
        let initialRect = NSRect(x: 0, y: 0, width: width, height: 560)
        window = ShellWindow(contentRect: initialRect,
                          styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.delegate = self
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
        window.deactivateActivityTerminal = { [weak self] in
            guard let self, self.workspace.selected == .activity, self.workspace.activityTerminal != nil else { return false }
            self.workspace.activityTerminal = nil
            self.window.makeFirstResponder(self.activity)
            return true
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
        let bar = NSHostingView(rootView: TerminalToolbar(state: workspace, select: { [weak self] in self?.select($0) },
            create: { [weak self] in
                guard let self else { return }
                self.createTerminalTab(selecting: self.workspace.selected != .activity)
            }, close: { [weak self] in self?.removeShell($0) },
            move: { [weak self] in self?.moveShell($0, to: $1) }))
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
        confirmations.start()
        window.center()
        let backgroundLaunch = CommandLine.arguments.contains("--automation-notification")
        if !backgroundLaunch { openWorkspace(); window.makeKeyAndOrderFront(nil) }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.refresh(); self?.confirmations.poll() } }
        if !backgroundLaunch { NSApp.activate(ignoringOtherApps: true) }
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [navigationItem] }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [navigationItem] }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard identifier == navigationItem else { return nil }
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = "Workspace tabs"
        let host = NSHostingView(rootView: FavoriteTabs(state: workspace, select: { [weak self] in self?.select($0) }))
        host.sizingOptions = []
        host.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        host.heightAnchor.constraint(equalToConstant: WorkspaceTabMetrics.height).isActive = true
        item.view = host
        item.autovalidates = false
        if #available(macOS 26, *) { item.isBordered = false; item.isNavigational = true }
        return item
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows && sender.isActive { openWorkspace(); window.makeKeyAndOrderFront(nil) }
        return true
    }

    private lazy var settings = NSHostingView(rootView: PromptSettings { [weak self] in self?.applyTheme() })
    @objc func showPromptSettings(_ sender: Any?) { select(.settings) }

    private func writeTheme() throws {
        try FileManager.default.createDirectory(at: themeDirectory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try PromptSetup.liveConfiguration().write(to: themeDirectory.appendingPathComponent("state"), atomically: true, encoding: .utf8)
    }
    private func refreshPrompt(_ sessionID: Int) {
        let fd = open(themeDirectory.appendingPathComponent(String(sessionID)).path, O_RDWR | O_NONBLOCK)
        if fd >= 0 { var byte: UInt8 = 10; _ = write(fd, &byte, 1); Darwin.close(fd) }
    }
    private func applyTheme() {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let color = PromptSetup.background(forShell: shell)
        do { try writeTheme() } catch { NSLog("Could not update prompt: %@", error.localizedDescription); return }
        for session in sessions {
            session.view.nativeBackgroundColor = color
            refreshPrompt(session.id)
        }
        workspace.tabColor = color
        window.backgroundColor = color
    }
    func applicationWillTerminate(_ notification: Notification) { saveWindow(); try? FileManager.default.removeItem(at: themeDirectory) }

    @objc func newGroup(_ sender: Any?) {
        workspace.activityBoards.add()
        workspace.activityTerminal = nil
        select(.activity)
    }

    @objc func newPage(_ sender: Any?) {
        select(.activity)
        createTerminalTab(selecting: false, startingPage: true)
    }

    @objc func newTab(_ sender: Any?) { createTerminalTab(selecting: workspace.selected != .activity) }

    private func createTerminalTab(selecting: Bool, directory: String? = nil, restoredSlot: Int? = nil, startingPage: Bool = false) {
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
        let terminal = LocalProcessTerminalView(frame: initialFrame)
        terminal.font = terminalFont(size: 14)
        terminal.lineSpacing = 1.15
        terminal.nativeBackgroundColor = PromptSetup.background(forShell: shell)
        terminal.nativeForegroundColor = NSColor(white: 0.93, alpha: 1)
        serial += 1
        let slot = TerminalSlots.assign(occupied: sessions.map(\.shortcutSlot), preferred: restoredSlot)
        let session = Session(serial, terminal, "\(URL(fileURLWithPath: shell).lastPathComponent) · \(serial)", shortcutSlot: slot)
        session.directory = initialDirectory
        let insertion = restoredSlot == nil ? sessions.firstIndex(where: { $0.shortcutSlot > slot }) ?? sessions.count : sessions.count
        sessions.insert(session, at: insertion)
        workspace.activityBoards.insert(slot, startingPage: startingPage)
        if workspace.selected == .activity { workspace.activityTerminal = serial }
        terminal.processDelegate = self
        if selecting { select(.shell(serial)) }
        var environment: [String]?
        if URL(fileURLWithPath: shell).lastPathComponent == "zsh", let folder = PromptSetup.folder {
            do {
                try writeTheme()
                let fifo = themeDirectory.appendingPathComponent(String(serial)).path
                if mkfifo(fifo, 0o600) == 0 {
                    environment = Terminal.getEnvironmentVariables() + ["ZDOTDIR=" + folder.path, "BANANA_STARTUP_DIR=" + folder.path,
                        "BANANA_LIMITS_BASE=" + themeDirectory.appendingPathComponent("limits-\(serial)").path,
                        "BANANA_THEME_STATE=" + themeDirectory.appendingPathComponent("state").path, "BANANA_THEME_FIFO=" + fifo]
                }
            } catch { NSLog("Could not initialize live themes: %@", error.localizedDescription) }
        }
        terminal.startProcess(executable: shell, args: ["-l"], environment: environment, currentDirectory: initialDirectory)
        refresh()
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

    private func removeShell(_ id: Int) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        if sessions.count == 1 { saveWindow() }
        let session = sessions.remove(at: index)
        workspace.activityBoards.remove(session.shortcutSlot)
        let wasActive = workspace.activityTerminal == id
        if wasActive { workspace.activityTerminal = nil }
        if wasActive && workspace.selected == .activity { window.makeFirstResponder(activity) }
        try? FileManager.default.removeItem(at: themeDirectory.appendingPathComponent(String(id)))
        session.view.processDelegate = nil
        session.view.removeFromSuperview()
        session.view.terminate()
        if sessions.isEmpty { window.close(); return }
        let neighbor = sessions[min(index, sessions.count - 1)].id
        if lastShell == id { lastShell = neighbor }
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
    }

    @objc func selectTab(_ sender: NSMenuItem) {
        selectShellTab(at: sender.tag)
    }

    private func selectShellTab(at index: Int) {
        guard window?.isKeyWindow == true, window.attachedSheet == nil,
              let id = sessions.first(where: { $0.shortcutSlot == index })?.id else { return }
        if workspace.selected == .activity { workspace.focusActivityTerminal.send(id) }
        else { select(.shell(id)) }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(selectTab(_:)) {
            return window?.isKeyWindow == true && sessions.contains { $0.shortcutSlot == menuItem.tag }
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
        let tabs: [(WorkspaceTab, Int?)] = [(.keys, nil), (.automations, nil)] +
            workspace.activityBoards.boards.map { (.activity, $0.id) } + [(.settings, nil)]
        let i = tabs.firstIndex { $0.0 == workspace.selected && ($0.1 == nil || $0.1 == workspace.activityBoards.selected) } ?? 0
        let next = tabs[(i + step + tabs.count) % tabs.count]
        if let id = next.1 { workspace.activityTerminal = nil; workspace.activityBoards.select(id) }
        select(next.0)
    }
    @objc func nextTab(_ sender: Any?) { cycle(1) }
    @objc func previousTab(_ sender: Any?) { cycle(-1) }
    func windowWillClose(_ notification: Notification) {
        saveWindow()
        timer?.invalidate()
        for session in sessions { session.view.processDelegate = nil; session.view.terminate() }
        sessions.removeAll()
    }
    private func refresh() {
        let rows = sessions.map { session in
            let process = session.view.process
            let group = process.map { tcgetpgrp($0.childfd) } ?? -1
            let busy = group > 0 && group != process?.shellPid
            var buffer = [CChar](repeating: 0, count: 1024)
            let name = busy && proc_name(group, &buffer, UInt32(buffer.count)) > 0 ? String(cString: buffer) : nil
            let status = busy ? (name ?? "Foreground task") + " running" : (group > 0 ? "" : "Checking status")
            let icon = busy ? ForegroundProgram.icon(pid: group, name: name, title: session.title) : nil
            let limits = icon == "claude" ? ClaudeLimits.rows(at: themeDirectory.appendingPathComponent("limits-\(session.id)-\(group)")) : []
            return TabActivity(id: session.id, shortcutSlot: session.shortcutSlot, programIcon: icon, name: session.title, status: status,
                               directory: (session.hasReportedDirectory ? "" : "Started in: ") + (session.directory as NSString).abbreviatingWithTildeInPath,
                               busy: busy, limits: limits)
        }
        if workspace.tabs != rows { workspace.tabs = rows }
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        if let session = sessions.first(where: { $0.view === source }) { removeShell(session.id) }
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
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    let menu = NSMenu()
    for (name, items) in [
        ("bananaShell", [("Prompt Settings…", "showPromptSettings:", ","), ("Quit bananaShell", "terminate:", "q")]),
        ("Shell", [("New Group", "newGroup:", CreationKeys.shared.key("Group")), ("New Page", "newPage:", CreationKeys.shared.key("Page")), ("New Terminal", "newTab:", CreationKeys.shared.key("Terminal")), ("Close Tab", "closeTab:", "w"),
                   ("Next Tab", "nextTab:", "}"), ("Previous Tab", "previousTab:", "{")]),
        ("Edit", [("Copy", "copy:", "c"), ("Paste", "paste:", "v")])
    ] {
        let submenu = NSMenu(title: name)
        menu.addItem(withTitle: name, action: nil, keyEquivalent: "").submenu = submenu
        for (title, action, key) in items {
            let item = submenu.addItem(withTitle: title, action: NSSelectorFromString(action), keyEquivalent: key)
            if name == "Shell" || action == "showPromptSettings:" { item.target = delegate }
        }
        if name == "Shell" {
            submenu.addItem(.separator())
            for (index, key) in ShellTabShortcuts.keys.enumerated() {
                let item = submenu.addItem(withTitle: "Go to Tab \(index + 1)",
                                           action: #selector(AppDelegate.selectTab(_:)), keyEquivalent: key)
                item.keyEquivalentModifierMask = NavigationKeys.shared.modifier(.terminal).flags
                item.tag = index
                item.target = delegate
            }
        }
    }
    for name in CreationKeys.actions {
        menu.item(withTitle: "Shell")?.submenu?.item(withTitle: "New " + name)?.keyEquivalentModifierMask = CreationKeys.shared.modifier(name).flags
    }
    app.mainMenu = menu
    app.run()
}
