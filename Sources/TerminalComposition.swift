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

    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        // SGR (ESC [ <) and X10 (ESC [ M) mouse reports go to tmux for scrolling.
        if data.starts(with: [0x1b, 0x5b, 0x3c]) || data.starts(with: [0x1b, 0x5b, 0x4d]) {
            mouseActive = true
        } else if mouseActive {
            mouseActive = false
            leaveScrollback?()
        }
        super.send(source: source, data: data)
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
