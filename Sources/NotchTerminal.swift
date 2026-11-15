import AppKit
import Carbon.HIToolbox
import SwiftTerm
import SwiftUI

/// A terminal the notch can show: an existing persistent session from a window.
struct NotchTerminalTarget: Equatable, Identifiable {
    let id: UUID
    let title: String
    let background: NSColor
}

struct NotchTerminalGroup: Equatable, Identifiable {
    let id: Int
    let title: String
    let terminals: [NotchTerminalTarget]
}

/// Drops a terminal down from the notch. It attaches a second tmux client to an
/// existing session, so the same terminal stays live in its window at the same time.
/// The terminal and group navigation modifiers switch terminals while it is open.
@MainActor final class NotchTerminal: NSObject, LocalProcessTerminalViewDelegate {
    /// Groups and terminals of the window the notch follows, in shortcut order.
    var groups: () -> [NotchTerminalGroup] = { [] }
    /// The terminal to show first: the one the user was last looking at.
    var preferredTerminal: () -> UUID? = { nil }
    var server: () -> PersistentTerminal? = { nil }
    /// Creates a terminal in a group, next to the given one; returns its session ID.
    var createTerminal: (_ group: Int, _ near: UUID?) -> UUID? = { _, _ in nil }

    private var refreshTimer: Timer?
    /// The terminal last shown per group, so switching groups returns to it.
    private var lastInGroup: [Int: UUID] = [:]

    private var panel: NotchTerminalPanel?
    private var terminal: ComposingProcessTerminalView?
    private let model = NotchTerminalModel()
    private var keyMonitor: Any?
    private var hotKey: EventHotKeyRef?
    private var hotKeyHandler: EventHandlerRef?
    private static weak var shared: NotchTerminal?

    var isVisible: Bool { panel?.isVisible == true }

    // MARK: Global shortcut (⌃` by default), no Accessibility permission needed.

    func registerHotKey() {
        Self.shared = self
        if hotKeyHandler == nil {
            var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { NotchTerminal.shared?.toggle() } }
                return noErr
            }, 1, &type, nil, &hotKeyHandler)
        }
        NotchTerminalKey.shared.register = { [weak self] key in self?.register(key) ?? OSStatus(paramErr) }
        _ = register(NotchTerminalKey.shared.current)
    }

    /// Replaces the global shortcut. On failure the previous one stays unregistered;
    /// the caller restores it.
    private func register(_ key: NotchTerminalKey.Shortcut) -> OSStatus {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        let id = EventHotKeyID(signature: OSType(0x626E_6E74), id: 1) // "bnnt"
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(key.keyCode), key.carbonModifiers, id, GetApplicationEventTarget(), 0, &reference)
        if status == noErr { hotKey = reference }
        return status
    }

    // MARK: Showing and hiding

    func toggle() { isVisible ? hide() : show() }

    func show() {
        let groups = groups()
        let all = groups.flatMap(\.terminals)
        guard let target = preferredTerminal().flatMap({ id in all.first { $0.id == id } }) ?? all.first else {
            NSSound.beep(); return
        }
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        guard let screen else { return }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        layout(panel, on: screen)
        model.groups = groups
        attach(target)
        panel.orderFrontRegardless()
        panel.makeKey()
        if let terminal { panel.makeFirstResponder(terminal) }
        installKeyMonitor()
        // Follow tabs opened, closed, moved or renamed in the windows while open.
        refreshTimer?.invalidate()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    private func refresh() {
        let next = groups()
        guard next != model.groups else { return }
        model.groups = next
        // The shown terminal was moved to another group or renamed: nothing to do;
        // currentGroup follows it. If it is gone, the client exit hides the notch.
    }

    func hide() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        detach()
        panel?.orderOut(nil)
    }

    private func makePanel() -> NotchTerminalPanel {
        let panel = NotchTerminalPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        return panel
    }

    static let terminalCornerRadius: CGFloat = 14

    private func layout(_ panel: NotchTerminalPanel, on screen: NSScreen) {
        let notch = screen.safeAreaInsets.top
        let top = notch > 0 ? notch : max(0, screen.frame.maxY - screen.visibleFrame.maxY)
        let width = min(900, screen.frame.width - 32)
        let height = min(520, (screen.frame.height - top) * 0.6) + top
        panel.setFrame(NSRect(x: screen.frame.midX - width / 2, y: screen.frame.maxY - height, width: width, height: height), display: false)

        let root = NSView(frame: NSRect(origin: .zero, size: panel.frame.size))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.black.cgColor
        root.layer?.cornerRadius = 22
        root.layer?.cornerCurve = .continuous
        root.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        root.layer?.masksToBounds = true

        let headerHeight: CGFloat = 34
        let header = NSHostingView(rootView: NotchTerminalHeader(model: model, select: { [weak self] in self?.select($0) },
                                                                 selectGroup: { [weak self] in self?.selectGroup($0) },
                                                                 create: { [weak self] in self?.newTerminal() },
                                                                 close: { [weak self] in self?.hide() }))
        header.frame = NSRect(x: 0, y: root.bounds.height - top - headerHeight, width: root.bounds.width, height: headerHeight)
        header.autoresizingMask = [.width, .minYMargin]
        root.addSubview(header)
        panel.terminalFrame = NSRect(x: 14, y: 12, width: root.bounds.width - 28, height: root.bounds.height - top - headerHeight - 18)
        panel.contentView = root
    }

    // MARK: Terminal client

    private func attach(_ target: NotchTerminalTarget) {
        guard let server = server(), let panel, let root = panel.contentView else { return }
        // Keep one client and move it between sessions; tmux keeps both views live.
        if let terminal, terminal.process.running {
            let fd = terminal.process.childfd
            if fd >= 0, let tty = ptsname(fd).map({ String(cString: $0) }),
               (try? server.run(["switch-client", "-c", tty, "-t", PersistentTerminal.name(target.id)])) != nil {
                terminal.nativeBackgroundColor = target.background
                terminal.superview?.layer?.backgroundColor = target.background.cgColor
                model.current = target.id
                return
            }
        }
        detach()
        // Rounded surface in the terminal's own background; the inset keeps
        // text clear of the corners.
        let surface = NSView(frame: panel.terminalFrame)
        surface.autoresizingMask = [.width, .height]
        surface.wantsLayer = true
        surface.layer?.cornerRadius = Self.terminalCornerRadius
        surface.layer?.cornerCurve = .continuous
        surface.layer?.masksToBounds = true
        surface.layer?.backgroundColor = target.background.cgColor
        root.addSubview(surface)
        let terminal = ComposingProcessTerminalView(frame: surface.bounds.insetBy(dx: 8, dy: 6))
        terminal.autoresizingMask = [.width, .height]
        terminal.font = terminalFont(size: 13)
        terminal.lineSpacing = 1.15
        terminal.nativeBackgroundColor = target.background
        terminal.nativeForegroundColor = NSColor(white: 0.93, alpha: 1)
        terminal.processDelegate = self
        surface.addSubview(terminal)
        self.terminal = terminal
        model.current = target.id
        terminal.startProcess(executable: server.executable.path, args: server.sharedAttachment(target.id),
                              environment: Terminal.getEnvironmentVariables(),
                              currentDirectory: FileManager.default.homeDirectoryForCurrentUser.path)
        panel.makeFirstResponder(terminal)
    }

    /// Ends only the notch's tmux client; the session keeps running in its window.
    private func detach() {
        guard let terminal else { return }
        self.terminal = nil
        terminal.processDelegate = nil
        if terminal.process.running { terminal.terminate() }
        let surface = terminal.superview
        terminal.removeFromSuperview()
        surface?.removeFromSuperview()
    }

    private func select(_ id: UUID) {
        guard let target = model.groups.flatMap(\.terminals).first(where: { $0.id == id }) else { return }
        attach(target)
        if let group = model.currentGroup { lastInGroup[group.id] = id }
        if let terminal { panel?.makeFirstResponder(terminal) }
    }

    /// Shows the terminal last used in that group, or its first terminal.
    private func selectGroup(_ id: Int) {
        guard let group = model.groups.first(where: { $0.id == id }) else { return }
        guard let target = group.terminals.first(where: { $0.id == lastInGroup[id] }) ?? group.terminals.first else {
            NSSound.beep(); return
        }
        select(target.id)
    }

    /// A new terminal in the notch's current group, shown in the notch right away.
    private func newTerminal() {
        guard let group = model.currentGroup ?? model.groups.first,
              let id = createTerminal(group.id, model.current) else { NSSound.beep(); return }
        model.groups = groups()
        select(id)
    }

    // MARK: Shortcuts while the notch terminal has keyboard focus

    private static let digitKeys: [UInt16] = [UInt16(kVK_ANSI_1), UInt16(kVK_ANSI_2), UInt16(kVK_ANSI_3), UInt16(kVK_ANSI_4), UInt16(kVK_ANSI_5),
                                              UInt16(kVK_ANSI_6), UInt16(kVK_ANSI_7), UInt16(kVK_ANSI_8), UInt16(kVK_ANSI_9), UInt16(kVK_ANSI_0)]

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel, panel.isKeyWindow, event.window === panel else { return event }
                return self.handleShortcut(event) ? nil : event
            }
        }
    }

    /// Physical digit keys, so shortcuts also work with a Korean input source.
    private func handleShortcut(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let creation = CreationKeys.shared
        // Physical key name, so the shortcut also works with a Korean input source.
        if flags == creation.modifier("Terminal").flags,
           NotchTerminalKey.keyName(event.keyCode)?.lowercased() == creation.key("Terminal") {
            newTerminal()
            return true
        }
        guard let index = Self.digitKeys.firstIndex(of: event.keyCode) else { return false }
        let keys = NavigationKeys.shared
        model.groups = groups()
        let group = model.currentGroup
        if flags == keys.modifier(.terminal).flags {
            guard let group, group.terminals.indices.contains(index) else { NSSound.beep(); return true }
            select(group.terminals[index].id)
            return true
        }
        if flags == keys.modifier(.group).flags {
            guard model.groups.indices.contains(index) else { NSSound.beep(); return true }
            selectGroup(model.groups[index].id)
            return true
        }
        return false
    }

    // MARK: LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func processTerminated(source: TerminalView, exitCode: Int32?) {
        // The session ended (e.g. `exit`) or the client was detached elsewhere.
        guard source === terminal else { return }
        hide()
    }
}

private final class NotchTerminalPanel: NSPanel {
    var terminalFrame: NSRect = .zero
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class NotchTerminalModel: ObservableObject {
    @Published var groups: [NotchTerminalGroup] = []
    @Published var current: UUID?
    var currentGroup: NotchTerminalGroup? {
        groups.first { group in group.terminals.contains { $0.id == current } }
    }
}

private struct NotchTerminalHeader: View {
    @ObservedObject var model: NotchTerminalModel
    @ObservedObject private var keys = NavigationKeys.shared
    @ObservedObject private var creation = CreationKeys.shared
    let select: (UUID) -> Void
    let selectGroup: (Int) -> Void
    let create: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    let current = model.currentGroup
                    if model.groups.count > 1 {
                        // Group tabs; the selected group expands into its terminals.
                        ForEach(Array(model.groups.enumerated()), id: \.element.id) { index, group in
                            let selected = group.id == current?.id
                            chip(group.title, shortcut: index < 10 ? keys.modifier(.group).symbol + String((index + 1) % 10) : nil,
                                 selected: selected, bold: true, dimmed: group.terminals.isEmpty) { selectGroup(group.id) }
                                .help(group.terminals.isEmpty ? "This group has no terminals" : "Show " + group.title)
                            if selected, let current { terminals(current); divider }
                        }
                    } else if let current {
                        Text(verbatim: current.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.55))
                            .lineLimit(1).fixedSize().padding(.trailing, 2)
                        terminals(current)
                    }
                    Button(action: create) {
                        Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
                            .frame(width: 24, height: 24)
                    }.buttonStyle(NotchHoverButtonStyle())
                     .help("New terminal in this group (" + creation.modifier("Terminal").symbol + creation.key("Terminal").uppercased() + ")")
                     .accessibilityLabel("New terminal")
                }
            }
            Spacer(minLength: 0)
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
                    .frame(width: 24, height: 24)
            }.buttonStyle(NotchHoverButtonStyle()).help("Close notch terminal (" + NotchTerminalKey.shared.current.display + ")")
             .accessibilityLabel("Close notch terminal")
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var divider: some View {
        Rectangle().fill(.white.opacity(0.16)).frame(width: 1, height: 16).padding(.horizontal, 4)
    }

    @ViewBuilder private func terminals(_ group: NotchTerminalGroup) -> some View {
        ForEach(Array(group.terminals.enumerated()), id: \.element.id) { index, terminal in
            chip(terminal.title, shortcut: index < 10 ? keys.modifier(.terminal).symbol + String((index + 1) % 10) : nil,
                 selected: terminal.id == model.current, bold: false, dimmed: false) { select(terminal.id) }
        }
    }

    private func chip(_ title: String, shortcut: String?, selected: Bool, bold: Bool, dimmed: Bool,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if bold { Image(systemName: "folder").font(.system(size: 10)) }
                Text(verbatim: title).font(.system(size: 12, weight: selected || bold ? .semibold : .regular)).lineLimit(1)
                if let shortcut {
                    Text(verbatim: shortcut).font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
                }
            }
            .foregroundStyle(.white.opacity(dimmed ? 0.35 : selected ? 1 : 0.7))
            .padding(.horizontal, 9).frame(height: 24)
        }.buttonStyle(NotchHoverButtonStyle(selected: selected))
         .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Selected, hovered and pressed fills for notch header buttons. Hover uses an
/// always-active tracking area: SwiftUI's onHover stays silent while the app is inactive.
private struct NotchHoverButtonStyle: ButtonStyle {
    var selected = false
    func makeBody(configuration: Configuration) -> some View {
        NotchHoverButton(configuration: configuration, selected: selected)
    }
}

private struct NotchHoverButton: View {
    let configuration: ButtonStyle.Configuration
    let selected: Bool
    @State private var hovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        configuration.label
            .brightness(hovered && !selected ? 0.15 : 0)
            .background(.white.opacity(configuration.isPressed ? 0.2 : selected ? 0.14 : hovered ? 0.08 : 0), in: shape)
            .contentShape(shape)
            .animation(.easeOut(duration: 0.12), value: hovered)
            .background { IslandButtonHoverTracker { hovered = $0 } }
    }
}

/// The user's global shortcut for the notch terminal, stored in UserDefaults.
@MainActor final class NotchTerminalKey: ObservableObject {
    struct Shortcut: Equatable {
        let keyCode: UInt16
        let flags: NSEvent.ModifierFlags

        var label: String { NotchTerminalKey.keyName(keyCode) ?? "Key \(keyCode)" }
        var display: String {
            (flags.contains(.control) ? "⌃" : "") + (flags.contains(.option) ? "⌥" : "")
                + (flags.contains(.shift) ? "⇧" : "") + (flags.contains(.command) ? "⌘" : "") + label
        }
        var carbonModifiers: UInt32 {
            (flags.contains(.command) ? UInt32(cmdKey) : 0) | (flags.contains(.option) ? UInt32(optionKey) : 0)
                | (flags.contains(.control) ? UInt32(controlKey) : 0) | (flags.contains(.shift) ? UInt32(shiftKey) : 0)
        }
        /// The menu shows the shortcut when it is a printable key.
        var menuKey: String {
            if keyCode == UInt16(kVK_Space) { return " " }
            return label.count == 1 ? label.lowercased() : ""
        }
    }

    static let shared = NotchTerminalKey()
    static let defaultShortcut = Shortcut(keyCode: UInt16(kVK_ANSI_Grave), flags: .control)
    private static let storageKey = "notchTerminalShortcut"

    @Published private(set) var current: Shortcut
    /// Installed by the notch terminal; registers a shortcut system-wide.
    var register: ((Shortcut) -> OSStatus)?

    private init() {
        let saved = UserDefaults.standard.dictionary(forKey: Self.storageKey)
        if let code = saved?["keyCode"] as? Int, let raw = saved?["flags"] as? UInt {
            current = Shortcut(keyCode: UInt16(code), flags: NSEvent.ModifierFlags(rawValue: raw))
        } else { current = Self.defaultShortcut }
    }

    var isDefault: Bool { current == Self.defaultShortcut }

    /// Returns an error message, or nil once the new shortcut is active.
    func set(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> String? {
        let flags = flags.intersection([.command, .option, .control, .shift])
        guard !flags.intersection([.command, .option, .control]).isEmpty else {
            return "Include ⌘, ⌥ or ⌃ so the shortcut doesn't block typing."
        }
        guard Self.keyName(keyCode) != nil else { return "That key can't be used. Try a letter, number, symbol or F-key." }
        let next = Shortcut(keyCode: keyCode, flags: flags)
        if flags == .command, let name = Self.keyName(keyCode), "ACVWXZQHM,".contains(name) {
            return "That shortcut is reserved for editing or window controls."
        }
        return apply(next)
    }

    func reset() { _ = apply(Self.defaultShortcut) }

    private func apply(_ next: Shortcut) -> String? {
        let previous = current
        if let register, register(next) != noErr {
            _ = register(previous)
            return "Another app already uses " + next.display + ". Choose a different shortcut."
        }
        current = next
        UserDefaults.standard.set(["keyCode": Int(next.keyCode), "flags": next.flags.rawValue], forKey: Self.storageKey)
        let item = NSApp?.mainMenu?.item(withTitle: "Shell")?.submenu?.item(withTitle: "Notch Terminal")
        item?.keyEquivalent = next.menuKey
        item?.keyEquivalentModifierMask = next.flags
        return nil
    }

    /// Names from physical key positions, so recording works with any input source.
    nonisolated static func keyName(_ code: UInt16) -> String? {
        let names: [Int: String] = [
            kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E", kVK_ANSI_F: "F", kVK_ANSI_G: "G",
            kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L", kVK_ANSI_M: "M", kVK_ANSI_N: "N",
            kVK_ANSI_O: "O", kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T", kVK_ANSI_U: "U",
            kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X", kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",
            kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3", kVK_ANSI_4: "4",
            kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9",
            kVK_ANSI_Grave: "`", kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=", kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]",
            kVK_ANSI_Backslash: "\\", kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'", kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".",
            kVK_ANSI_Slash: "/", kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
            kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        ]
        return names[Int(code)]
    }
}
