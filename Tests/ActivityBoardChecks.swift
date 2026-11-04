// Run with: swiftc -disable-sandbox -parse-as-library Sources/ActivityBoards.swift Sources/TabTypography.swift Sources/Sidebars.swift Tests/ActivityBoardChecks.swift -o /tmp/banana-activity-board-checks && /tmp/banana-activity-board-checks
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
struct ActivityBoardChecks {
    @MainActor static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let state = WorkspaceState()
        state.selected = .activity
        // The 2×2 grid splits seven sessions into four and three. Navigation
        // changes the visible slice without changing slot assignments.
        let navigation = WorkspaceState()
        navigation.selected = .activity
        navigation.activityBoards.reconcile(with: Array(0..<7))
        navigation.activityBoards.add()
        navigation.activityBoards.rename(1, to: "Build")
        precondition(navigation.navigate(.group, to: .index(0)))
        navigation.activityTerminal = 1
        precondition(navigation.navigate(.page, to: .index(1)))
        precondition(Array(navigation.activityBoards.current.visibleSlots) == [4, 5, 6] && navigation.activityTerminal == nil)
        precondition(!navigation.navigate(.page, to: .index(2)) && navigation.activityBoards.current.page == 1)
        precondition(navigation.navigate(.group, to: .step(1)))
        precondition(!navigation.navigate(.page, to: .index(0)))
        precondition(navigation.navigate(.group, to: .step(1)) && navigation.activityBoards.current.title == "Build")
        precondition(navigation.activityBoards.current.page == 1 && navigation.navigate(.page, to: .step(1)))
        precondition(Array(navigation.activityBoards.current.visibleSlots) == [0, 1, 2, 3])
        var closing = navigation.activityBoards
        closing.setPage(1)
        let closedSlots = Array(closing.current.slots(on: 0))
        for slot in closedSlots { closing.remove(slot) }
        precondition(closing.current.slots == [4, 5, 6] && closing.current.page == 0 && closing.current.pageCount == 1)
        closing.close(closing.selected)
        precondition(closing.boards.count == 1 && closing.current.slots == [4, 5, 6])
        navigation.selected = .settings
        precondition(!navigation.navigate(.page, to: .index(1)))

        let ids = Array(1...17)
        state.tabs = ids.map { TabActivity(id: $0, shortcutSlot: $0 - 1, programIcon: nil, name: "Terminal \($0)",
                                          status: "Shell active", directory: "~/work", busy: false, limits: []) }
        let terminals = Dictionary(uniqueKeysWithValues: ids.map { ($0, ProbeTerminal()) })
        state.activityBoards.reconcile(with: ids.map { $0 - 1 })
        weak var focusWindow: NSWindow?
        let panel = ActivityPanel(state: state, terminalView: { terminals[$0] }, close: { _ in }, create: {},
                                  releaseFocus: { focusWindow?.makeFirstResponder(nil) }, expand: { state.selected = .shell($0) })
        let host = NSHostingView(rootView: panel)
        let window = NSWindow(contentRect: NSRect(x: -3000, y: 0, width: 1000, height: 700),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        focusWindow = window
        window.contentView = host
        func settle() {
            for _ in 0..<15 {
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.015))
                host.layoutSubtreeIfNeeded()
            }
        }
        func checkGrid(_ n: Int) {
            settle()
            for i in 0..<(n*n) {
                let t = terminals[i + 1]!
                precondition(t.window === window)
                let rect = t.convert(t.bounds, to: host)
                precondition(rect.width > 100 && rect.height > 30)
                let first = terminals[1]!.convert(terminals[1]!.bounds, to: host)
                precondition(abs(rect.width - first.width) < 2 && abs(rect.height - first.height) < 2)
                precondition(abs(rect.minX - first.minX - CGFloat(i % n) * (rect.width + 14)) < 3)
                precondition(abs(abs(rect.minY - first.minY) - CGFloat(i / n) * (rect.height + 38)) < 3)
            }
            precondition(terminals[n*n + 1]!.window == nil)
        }
        for layout in ActivityGrid.allCases {
            state.activityBoards.setGrid(layout, keeping: 0)
            checkGrid(layout.rawValue)
        }
        state.focusActivityTerminal.send(17)
        settle()
        precondition(state.activityBoards.current.page == 1 && window.firstResponder === terminals[17])
        state.focusActivityTerminal.send(17)
        settle()
        precondition(state.activityTerminal == nil && terminals[17]!.window === window && window.firstResponder !== terminals[17])

        state.activityBoards.add()
        state.activityBoards.move(0, to: 2)
        state.activityBoards.insert(99)
        state.activityBoards.setGrid(.single, keeping: 0)
        settle()
        precondition(terminals[1]!.window === window && terminals[17]!.window == nil)
        precondition(state.activityBoards.current.slots == [0, 99])
        state.focusActivityTerminal.send(2)
        settle()
        precondition(state.activityBoards.selected == 1 && state.activityBoards.current.grid == .sixteen)
        precondition(window.firstResponder === terminals[2] && terminals[1]!.window == nil)

        state.activityBoards.rename(1, to: "  Build & Deploy  ")
        state.activityBoards.rename(1, to: "   ")
        precondition(state.activityBoards.current.title == "Build & Deploy")
        state.activityBoards.reorder(2, to: 1)
        precondition(Array(state.activityBoards.current.slots.prefix(2)) == [2, 1])
        precondition(state.activityBoards.boards[1].slots == [0, 99])
        let legacy = Data(#"{"boards":[{"id":1,"grid":2,"slots":[3],"page":0}],"selected":1}"#.utf8)
        let legacyBoards = try JSONDecoder().decode(ActivityBoards.self, from: legacy)
        precondition(legacyBoards.current.title == "Tab 1" && legacyBoards.current.slots == [3])

        let data = try JSONEncoder().encode(state.activityBoards)
        var restored = try JSONDecoder().decode(ActivityBoards.self, from: data)
        precondition(restored == state.activityBoards)
        restored.reconcile(with: Array(0..<18))
        precondition(restored.boards[1].slots == [0] && restored.current.slots.last == 17)
        restored.close(1)
        precondition(restored.selected == 2 && restored.boards.count == 1 && Set(restored.current.slots) == Set(0..<18))
        restored.reveal(17)
        restored.remove(17)
        precondition(restored.current.page == restored.current.pageCount - 1)
        print("Activity grid, overflow, focus, tab membership and restoration checks passed.")
        window.contentView = nil
    }
}
