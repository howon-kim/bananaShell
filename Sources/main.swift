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
        keys.indices.contains(index) ? " (⌘\(keys[index]))" : ""
    }
}

private final class ShellWindow: NSWindow {
    var selectTabAtIndex: ((Int) -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if event.type == .keyDown, isKeyWindow, attachedSheet == nil, modifiers == .command,
           let index = ShellTabShortcuts.keyCodes.firstIndex(of: event.keyCode), let selectTabAtIndex {
            selectTabAtIndex(index)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

private final class Session {
    let id: Int
    let view: LocalProcessTerminalView
    var title: String
    var directory = FileManager.default.currentDirectoryPath
    var hasReportedDirectory = false
    init(_ id: Int, _ view: LocalProcessTerminalView, _ title: String) {
        self.id = id; self.view = view; self.title = title
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation, LocalProcessTerminalViewDelegate {
    private var sessions: [Session] = []
    private let workspace = WorkspaceState()
    private let body = NSView()
    private let directoryLabel = NSTextField(labelWithString: "")
    private var window: ShellWindow!
    private lazy var keys = NSHostingView(rootView: PublicKeyPanel(generateRequest: workspace.generateKey, importRequest: workspace.importKey))
    private lazy var automations = NSHostingView(rootView: AutomationPanel(addRequest: workspace.addAutomation))
    private lazy var activity = NSHostingView(rootView: ActivityPanel(state: workspace, current: -1) { [weak self] in self?.select(.shell($0)) })
    private let themeDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("banana-theme-" + UUID().uuidString)
    private var serial = 0
    private var lastShell: Int?
    private let confirmations = AutomationNotifications()
    private var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = ShellWindow(contentRect: NSRect(x: 0, y: 0, width: 1140, height: 560),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.delegate = self
        window.selectTabAtIndex = { [weak self] in self?.selectShellTab(at: $0) }
        window.tabbingMode = .disallowed
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = shellSurface
        window.title = "bananaShell"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        let titleLabel = NSTextField(labelWithString: window.title)
        titleLabel.font = terminalFont(size: NSFont.systemFontSize)
        directoryLabel.textColor = .secondaryLabelColor
        directoryLabel.lineBreakMode = .byTruncatingMiddle
        directoryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let titleRow = NSStackView(views: [titleLabel, directoryLabel])
        titleRow.spacing = 8
        titleRow.alignment = .centerY
        window.contentMinSize = NSSize(width: 440, height: 200)
        let bar = NSHostingView(rootView: FavoriteTabs(state: workspace, select: { [weak self] in self?.select($0) },
            create: { [weak self] in self?.newTab(nil) }, close: { [weak self] in self?.removeShell($0) },
            move: { [weak self] in self?.moveShell($0, to: $1) }))
        let root = NSView()
        window.contentView = root
        let contentGuide = window.contentLayoutGuide as! NSLayoutGuide
        root.addSubview(titleRow)
        titleRow.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            titleRow.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 86),
            titleRow.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -44),
            titleRow.topAnchor.constraint(equalTo: root.topAnchor),
            titleRow.bottomAnchor.constraint(equalTo: contentGuide.topAnchor)
        ])
        for view in [bar as NSView, body] {
            root.addSubview(view)
            view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                                         view.trailingAnchor.constraint(equalTo: root.trailingAnchor)])
        }
        NSLayoutConstraint.activate([bar.topAnchor.constraint(equalTo: contentGuide.topAnchor), bar.heightAnchor.constraint(equalToConstant: 42),
                                     body.topAnchor.constraint(equalTo: bar.bottomAnchor), body.bottomAnchor.constraint(equalTo: root.bottomAnchor)])
        confirmations.start()
        window.center()
        let backgroundLaunch = CommandLine.arguments.contains("--automation-notification")
        if !backgroundLaunch { window.makeKeyAndOrderFront(nil) }
        newTab(nil)
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.refresh(); self?.confirmations.poll() } }
        if !backgroundLaunch { NSApp.activate(ignoringOtherApps: true) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows && sender.isActive { window.makeKeyAndOrderFront(nil) }
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
    func applicationWillTerminate(_ notification: Notification) { try? FileManager.default.removeItem(at: themeDirectory) }

    @objc func newTab(_ sender: Any?) {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        window.contentView?.layoutSubtreeIfNeeded()
        let initialDirectory = sessions.isEmpty ? FileManager.default.homeDirectoryForCurrentUser.path : nil
        let terminal = LocalProcessTerminalView(frame: body.bounds.insetBy(dx: 10, dy: 10))
        terminal.font = terminalFont(size: 14)
        terminal.lineSpacing = 1.15
        terminal.nativeBackgroundColor = PromptSetup.background(forShell: shell)
        terminal.nativeForegroundColor = NSColor(white: 0.93, alpha: 1)
        serial += 1
        sessions.append(Session(serial, terminal, "\(URL(fileURLWithPath: shell).lastPathComponent) · \(serial)"))
        if let initialDirectory { sessions.last?.directory = initialDirectory }
        terminal.processDelegate = self
        select(.shell(serial))
        var environment: [String]?
        if URL(fileURLWithPath: shell).lastPathComponent == "zsh", let folder = PromptSetup.folder {
            do {
                try writeTheme()
                let fifo = themeDirectory.appendingPathComponent(String(serial)).path
                if mkfifo(fifo, 0o600) == 0 {
                    environment = Terminal.getEnvironmentVariables() + ["ZDOTDIR=" + folder.path, "BANANA_STARTUP_DIR=" + folder.path,
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
        directoryLabel.stringValue = ""
        switch tab {
        case .settings: view = settings
        case .keys: view = keys
        case .activity: view = activity
        case .automations: view = automations
        case .shell(let id):
            guard let session = sessions.first(where: { $0.id == id }) else { return }
            lastShell = id
            view = session.view
            inset = 10
            if session.hasReportedDirectory { directoryLabel.stringValue = session.directory }
        }
        workspace.tabColor = (view as? LocalProcessTerminalView)?.nativeBackgroundColor ?? workspace.tabColor
        window.backgroundColor = workspace.tabColor
        workspace.selected = tab
        if body.subviews.first !== view {
            body.subviews.first?.removeFromSuperview()
            view.frame = body.bounds.insetBy(dx: inset, dy: inset)
            view.autoresizingMask = [.width, .height]
            body.addSubview(view)
        }
        window.makeFirstResponder(view)
    }

    private func removeShell(_ id: Int) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        let session = sessions.remove(at: index)
        try? FileManager.default.removeItem(at: themeDirectory.appendingPathComponent(String(id)))
        session.view.processDelegate = nil
        session.view.terminate()
        if sessions.isEmpty { window.close(); return }
        let neighbor = sessions[min(index, sessions.count - 1)].id
        if lastShell == id { lastShell = neighbor }
        if workspace.selected == .shell(id) { select(.shell(neighbor)) }
        refresh()
    }

    @objc func closeTab(_ sender: Any?) {
        if case let .shell(id) = workspace.selected { removeShell(id) }
        else if let lastShell { select(.shell(lastShell)) }
    }

    private func moveShell(_ sourceID: Int, to targetID: Int) {
        guard let source = sessions.firstIndex(where: { $0.id == sourceID }),
              let target = sessions.firstIndex(where: { $0.id == targetID }), source != target else { return }
        let session = sessions.remove(at: source)
        sessions.insert(session, at: target)
        refresh()
    }

    @objc func selectTab(_ sender: NSMenuItem) {
        selectShellTab(at: sender.tag)
    }

    private func selectShellTab(at index: Int) {
        guard window?.isKeyWindow == true, sessions.indices.contains(index) else { return }
        select(.shell(sessions[index].id))
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(selectTab(_:)) {
            return window?.isKeyWindow == true && sessions.indices.contains(menuItem.tag)
        }
        return true
    }

    private func cycle(_ step: Int) {
        let tabs: [WorkspaceTab] = [.keys, .activity, .automations] + sessions.map { .shell($0.id) } + [.settings]
        let i = tabs.firstIndex(of: workspace.selected) ?? 0
        select(tabs[(i + step + tabs.count) % tabs.count])
    }
    @objc func nextTab(_ sender: Any?) { cycle(1) }
    @objc func previousTab(_ sender: Any?) { cycle(-1) }
    func windowWillClose(_ notification: Notification) {
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
            let status = busy ? (name ?? "Foreground task") + " running" : (group > 0 ? "Shell active" : "Checking status")
            return TabActivity(id: session.id, name: session.title, status: status,
                               directory: (session.hasReportedDirectory ? "" : "Started in: ") + (session.directory as NSString).abbreviatingWithTildeInPath, busy: busy)
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
        if workspace.selected == .shell(session.id) { directoryLabel.stringValue = session.directory }
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
        ("Shell", [("New Tab", "newTab:", "t"), ("Close Tab", "closeTab:", "w"),
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
                item.keyEquivalentModifierMask = .command
                item.tag = index
                item.target = delegate
            }
        }
    }
    app.mainMenu = menu
    app.run()
}
