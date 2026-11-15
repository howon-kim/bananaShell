// Link with SwiftTerm.o and Sources/TerminalComposition.swift.
import AppKit
import SwiftTerm

@main
struct TerminalCompositionChecks {
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        for terminal in [ComposingTerminalView(frame: NSRect(x: 0, y: 0, width: 480, height: 160)),
                         ComposingProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 480, height: 160))] as [TerminalView] {
            terminal.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
            terminal.lineSpacing = 1.15
            terminal.nativeBackgroundColor = .black
            terminal.nativeForegroundColor = .white
            var images = Set<Data>()
            for text in ["ㅎ", "하", "한", "하"] {
                terminal.setMarkedText(text, selectedRange: NSRange(location: 1, length: 0),
                                       replacementRange: NSRange(location: NSNotFound, length: 0))
                precondition(terminal.hasMarkedText())
                let overlay = terminal.subviews.compactMap { $0 as? NSTextView }.first!
                precondition(overlay.string == text && overlay.frame.height > 0)
                // Capture immediately: no run-loop delay or terminal output.
                let bitmap = overlay.bitmapImageRepForCachingDisplay(in: overlay.bounds)!
                overlay.cacheDisplay(in: overlay.bounds, to: bitmap)
                images.insert(bitmap.representation(using: .png, properties: [:])!)
            }
            precondition(images.count == 3, "Each Korean composition stage must render immediately")
            // Reproduce the real ordering: commit a syllable, begin the next,
            // then receive the PTY echo that advances the rendered cursor.
            terminal.insertText("한글", replacementRange: NSRange(location: NSNotFound, length: 0))
            terminal.setMarkedText("ㅇ", selectedRange: NSRange(location: 1, length: 0),
                                   replacementRange: NSRange(location: NSNotFound, length: 0))
            let caret = terminal.subviews.first { String(describing: type(of: $0)) == "CaretView" }!
            let oldPosition = caret.frame.origin
            caret.setFrameOrigin(NSPoint(x: oldPosition.x + 40, y: oldPosition.y))
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.06))
            let movedOverlay = terminal.subviews.compactMap { $0 as? NSTextView }.first!
            let excludedWidth = movedOverlay.textContainer!.exclusionPaths.first?.bounds.width ?? 0
            precondition(abs(excludedWidth - max(0, caret.frame.minX - movedOverlay.frame.minX)) < 0.5,
                         "New composition must follow PTY echo instead of covering the committed syllable")
            precondition(movedOverlay.string == "ㅇ")
            terminal.insertText("하", replacementRange: NSRange(location: NSNotFound, length: 0))
            precondition(!terminal.hasMarkedText())
            precondition(!terminal.subviews.contains { $0 is NSTextView })
            terminal.setMarkedText("ㄱ", selectedRange: NSRange(location: 1, length: 0),
                                   replacementRange: NSRange(location: NSNotFound, length: 0))
            terminal.unmarkText()
            precondition(!terminal.hasMarkedText())
            precondition(!terminal.subviews.contains { $0 is NSTextView })
        }
        print("Korean composition checks passed: immediate glyph updates, backspace, commit and cancellation in both terminal views.")
    }
}
