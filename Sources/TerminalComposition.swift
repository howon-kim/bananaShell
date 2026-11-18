import AppKit
import SwiftTerm

@MainActor
private final class TerminalComposition {
    private var timer: Timer?
    private weak var terminal: TerminalView?
    private var caretFrame = CGRect.zero
    private var selectedRange = NSRange(location: 0, length: 0)

    func refresh(in terminal: TerminalView, selectedRange: NSRange) {
        self.terminal = terminal
        self.selectedRange = selectedRange
        caretFrame = terminal.caretFrame
        guard terminal.hasMarkedText() else { stop(); return }
        if timer == nil {
            // PTY echo moves the cursor after insertText returns. SwiftTerm
            // positions its marked-text overlay only during setMarkedText,
            // otherwise the next syllable can cover the just-committed one.
            // Watch only during composition; redraw only if the caret moved.
            let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    guard let terminal = self.terminal, terminal.hasMarkedText() else { self.stop(); return }
                    guard self.caretFrame != terminal.caretFrame else { return }
                    let range = terminal.markedRange()
                    guard let text = terminal.attributedSubstring(forProposedRange: range, actualRange: nil) else { return }
                    terminal.setMarkedText(text, selectedRange: self.selectedRange,
                                           replacementRange: NSRange(location: NSNotFound, length: 0))
                }
            }
            self.timer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
        Self.draw(in: terminal)
    }

    func stop() { timer?.invalidate(); timer = nil }
    deinit { timer?.invalidate() }

    private static func draw(in terminal: TerminalView) {
        guard terminal.hasMarkedText() else { return }
        // SwiftTerm's marked text is an NSTextView above the terminal surface.
        // Give it an independent backing layer and invalidate it on every IME
        // update, including same-sized replacements (e.g. ㅎ -> 하 -> 한).
        // Composition must not wait for the next PTY output/frame to appear.
        for overlay in terminal.subviews.compactMap({ $0 as? NSTextView }) {
            overlay.wantsLayer = true
            terminal.addSubview(overlay, positioned: .above, relativeTo: nil)
            if let container = overlay.textContainer { overlay.layoutManager?.ensureLayout(for: container) }
            overlay.needsDisplay = true
            overlay.layer?.setNeedsDisplay()
            overlay.displayIfNeeded()
        }
    }
}

class ComposingTerminalView: TerminalView {
    private let composition = TerminalComposition()
    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        composition.refresh(in: self, selectedRange: selectedRange)
    }

    override func unmarkText() {
        composition.stop()
        super.unmarkText()
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        composition.stop()
        super.insertText(string, replacementRange: replacementRange)
    }
}

final class ComposingProcessTerminalView: LocalProcessTerminalView {
    private let composition = TerminalComposition()
    /// Called before typed input that follows mouse activity (scrolling or
    /// selecting), so the session can leave tmux copy mode and take the input.
    var leaveScrollback: (() -> Void)?
    private var mouseActive = false

    /// Session actions for the native context menu. tmux's own menus are
    /// disabled; programs that track the mouse still receive right-clicks.
    var contextActions: TerminalContextActions?
    private var showingMenu = false

    override func rightMouseDown(with event: NSEvent) {
        guard showContextMenu(for: event) else { return super.rightMouseDown(with: event) }
    }
    override func rightMouseUp(with event: NSEvent) {
        if showingMenu { showingMenu = false } else { super.rightMouseUp(with: event) }
    }
    // Control-click is the macOS secondary click.
    override func mouseDown(with event: NSEvent) {
        let control = event.modifierFlags.intersection([.control, .command, .option, .shift]) == .control
        guard control, showContextMenu(for: event) else { return super.mouseDown(with: event) }
        showingMenu = false
    }

    private func showContextMenu(for event: NSEvent) -> Bool {
        guard let actions = contextActions, !actions.wantsMouse() else { return false }
        window?.makeFirstResponder(self)
        let menu = NSMenu()
        menu.autoenablesItems = false
        func add(_ title: String, _ symbol: String, enabled: Bool = true, _ action: @escaping () -> Void) {
            let item = NSMenuItem(title: title, action: #selector(TerminalMenuAction.run), keyEquivalent: "")
            let target = TerminalMenuAction(action)
            item.target = target
            item.representedObject = target
            item.isEnabled = enabled
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            menu.addItem(item)
        }
        add("Copy", "doc.on.doc", enabled: selectionActive) { [weak self] in self?.copy(self as Any) }
        add("Paste", "doc.on.clipboard", enabled: NSPasteboard.general.string(forType: .string) != nil) { [weak self] in
            guard let self else { return }
            self.paste(self)
        }
        menu.addItem(.separator())
        let directory = actions.directory()
        add("Copy Folder Path", "link", enabled: directory != nil) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(directory ?? "", forType: .string)
        }
        add("Show Folder in Finder", "folder", enabled: directory != nil) {
            if let directory { NSWorkspace.shared.open(URL(fileURLWithPath: directory, isDirectory: true)) }
        }
        menu.addItem(.separator())
        add("Clear Scrollback", "eraser") { [weak self] in
            actions.clearScrollback()
            self?.clearScrollback()
        }
        showingMenu = true
        NSMenu.popUpContextMenu(menu, with: event, for: self)
        return true
    }

    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        // SGR (ESC [ <) and X10 (ESC [ M) mouse reports go to tmux for scrolling.
        if data.starts(with: [0x1b, 0x5b, 0x3c]) || data.starts(with: [0x1b, 0x5b, 0x4d]) {
            mouseActive = true
            scheduleScrollbackCheck()
        } else if mouseActive {
            mouseActive = false
            leaveScrollback?()
            inScrollback = false
        }
        super.send(source: source, data: data)
    }

    // MARK: Caret visibility
    //
    // SwiftTerm draws an unfocused caret as a hollow box, and in tmux copy mode
    // (scrollback, mouse selection) the caret follows tmux's copy cursor into
    // the middle of the text. Show the caret only on the live, focused screen.

    private weak var caretView: NSView?
    private var inScrollback = false { didSet { if inScrollback != oldValue { updateCaretVisibility() } } }
    private var scrollbackCheckPending = false
    private var keyObservers: [NSObjectProtocol] = []

    override var hasFocus: Bool {
        get { super.hasFocus }
        set { super.hasFocus = newValue; updateCaretVisibility() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        keyObservers.forEach(NotificationCenter.default.removeObserver)
        keyObservers = []
        if let window {
            keyObservers = [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification].map {
                NotificationCenter.default.addObserver(forName: $0, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.updateCaretVisibility() }
                }
            }
        }
        updateCaretVisibility()
    }

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        // SwiftTerm re-adds its caret whenever the cursor becomes visible again.
        if String(describing: type(of: subview)) == "CaretView" {
            caretView = subview
            updateCaretVisibility()
        }
    }

    private func updateCaretVisibility() {
        guard let caretView else { return }
        let hidden = !hasFocus || inScrollback
        if caretView.isHidden != hidden { caretView.isHidden = hidden }
    }

    /// Mouse reports arrive continuously while dragging or scrolling; ask tmux
    /// about copy mode at most every 80 ms, and once more after the last report.
    private func scheduleScrollbackCheck() {
        guard !scrollbackCheckPending, contextActions?.inCopyMode != nil else { return }
        scrollbackCheckPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self else { return }
            self.scrollbackCheckPending = false
            self.inScrollback = self.contextActions?.inCopyMode() ?? false
        }
    }
    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        composition.refresh(in: self, selectedRange: selectedRange)
    }

    override func unmarkText() {
        composition.stop()
        super.unmarkText()
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        composition.stop()
        super.insertText(string, replacementRange: replacementRange)
    }
}

struct TerminalContextActions {
    /// True while the program in the session tracks the mouse (it gets the click).
    var wantsMouse: () -> Bool
    var directory: () -> String?
    var clearScrollback: () -> Void
    /// True while tmux shows scrollback or a mouse selection (copy mode).
    var inCopyMode: () -> Bool
}

private final class TerminalMenuAction: NSObject {
    private let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func run() { action() }
}
