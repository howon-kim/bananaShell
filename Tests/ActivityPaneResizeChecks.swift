// Run with: swiftc -disable-sandbox -parse-as-library Sources/ActivityPaneSize.swift Sources/TabTypography.swift Sources/Sidebars.swift Tests/ActivityPaneResizeChecks.swift -o /tmp/banana-activity-resize-checks && /tmp/banana-activity-resize-checks
// Standalone Activity UI harness; these stubs replace the app entry point.
import AppKit
import SwiftUI

let shellSurface = NSColor(white: 0.08, alpha: 1)
func terminalFont(size: CGFloat) -> NSFont { .monospacedSystemFont(ofSize: size, weight: .regular) }
enum ShellTabShortcuts {
    static let keys = Array("1234567890-=").map(String.init)
    static func hint(at index: Int) -> String { keys.indices.contains(index) ? keys[index] : "" }
}

private final class ProbeTerminal: NSView {
    override var acceptsFirstResponder: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        shellSurface.setFill()
        dirtyRect.fill()
        ("user@mac ~/work % " as NSString).draw(at: NSPoint(x: 8, y: bounds.height - 24),
                                             withAttributes: [.font: terminalFont(size: 13), .foregroundColor: NSColor.white])
    }
}

@main
struct ActivityResizeChecks {
    @MainActor static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let state = WorkspaceState()
        state.selected = .activity
        state.tabs = (1...3).map { TabActivity(id: $0, shortcutSlot: $0 - 1, programIcon: nil, name: "Terminal \($0)",
                                             status: "Shell active", directory: "~/work", busy: false, limits: [], preview: "user@mac ~/work %") }
        let terminals = [1: ProbeTerminal(), 2: ProbeTerminal(), 3: ProbeTerminal()]
        state.expandedActivityTerminals = [1, 2]
        state.activityTerminal = 1
        state.activityPaneSizes = [1: ActivityPaneSize(width: 420, height: 280),
                                   2: ActivityPaneSize(width: 420, height: 320)]
        let panel = ActivityPanel(state: state, terminalView: { terminals[$0] }, close: { _ in })
        let host = NSHostingView(rootView: panel)
        let window = NSWindow(contentRect: NSRect(x: -3000, y: 0, width: 1000, height: 700),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        func settle() {
            for _ in 0..<15 {
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.015))
                host.layoutSubtreeIfNeeded()
            }
        }
        func check(_ id: Int, width: CGFloat, height: CGFloat) {
            let actual = terminals[id]!.frame.size
            precondition(terminals[id]!.window === window, "Terminal \(id) detached")
            precondition(abs(actual.width - width) < 2 && abs(actual.height - height) < 2,
                         "Terminal \(id) expected \(width)x\(height), got \(actual)")
        }
        func rect(_ id: Int) -> CGRect { terminals[id]!.convert(terminals[id]!.bounds, to: host) }
        settle()
        check(1, width: 400, height: 280)
        check(2, width: 400, height: 320)
        precondition(window.firstResponder === terminals[1], "Other mounts stole focus")
        precondition(abs(rect(1).minX - rect(2).minX) > 400 && !rect(1).intersects(rect(2)), "Panes do not fit side by side")
        let containers = [1: terminals[1]!.superview, 2: terminals[2]!.superview]
        state.activityPaneSizes[1] = ActivityPaneSize(width: 500, height: 360)
        settle()
        check(1, width: 480, height: 360)
        check(2, width: 400, height: 320)
        for id in [1, 2] { precondition(terminals[id]!.superview === containers[id]!, "Resize remounted terminal \(id)") }
        window.setContentSize(NSSize(width: 400, height: 700))
        settle()
        check(1, width: 340, height: 360)
        check(2, width: 340, height: 320)
        precondition(abs(rect(1).minY - rect(2).minY) > 300 && !rect(1).intersects(rect(2)), "Narrow panes overlap")
        window.setContentSize(NSSize(width: 1000, height: 700))
        settle()
        check(1, width: 480, height: 360)
        check(2, width: 400, height: 320)
        state.focusActivityTerminal.send(2)
        settle()
        precondition(state.expandedActivityTerminals == [1, 2] && window.firstResponder === terminals[2], "Shortcut collapsed another terminal or missed focus")
        state.focusActivityTerminal.send(2)
        settle()
        precondition(state.expandedActivityTerminals == [1] && state.activityTerminal == nil)
        precondition(terminals[2]!.window == nil && window.firstResponder !== terminals[2])
        precondition(terminals[1]!.superview === containers[1]!, "Collapsing another pane remounted terminal")
        state.expandActivityTerminal(3)
        settle()
        precondition(state.expandedActivityTerminals == [1, 3] && window.firstResponder === terminals[3])
        state.collapseActivityTerminal(3)
        settle()
        precondition(state.expandedActivityTerminals == [1] && state.activityTerminal == nil)
        state.expandActivityTerminal(2)
        state.activityPaneSizes.removeValue(forKey: 1)
        settle()
        check(1, width: 454, height: 420)
        check(2, width: 400, height: 320)
        if let path = ProcessInfo.processInfo.environment["ACTIVITY_CHECK_SCREENSHOT"],
           let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
        state.tabs.removeAll { $0.id == 2 }
        settle()
        precondition(!state.expandedActivityTerminals.contains(2) && state.activityTerminal == nil)
        check(1, width: 454, height: 420)
        let saved = try JSONEncoder().encode(state.activityPaneSizes)
        let decoded = try JSONDecoder().decode([Int: ActivityPaneSize].self, from: saved)
        precondition(decoded == state.activityPaneSizes)
        print("Activity UI checks passed: simultaneous panes, independent resize, view identity, wrapping, focus, per-pane collapse, close, reset and persistence.")
        window.contentView = nil
    }
}
