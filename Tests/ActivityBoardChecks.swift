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
        try checkPositionalShortcuts()
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
        precondition(closing.boards.count == 1 && closing.current.slots.isEmpty)
        navigation.selected = .settings
        precondition(!navigation.navigate(.page, to: .index(1)))

        let ids = Array(1...17)
        state.tabs = ids.map { TabActivity(id: $0, shortcutSlot: $0 - 1, programIcon: nil, name: "Terminal \($0)",
                                          status: "Shell active", directory: "~/work", busy: false, limits: []) }
        let removedTab = state.tabs.removeLast()
        precondition(state.tab(id: removedTab.id) == nil && state.tab(slot: removedTab.shortcutSlot) == nil)
        state.tabs.append(removedTab)
        precondition(state.tab(id: removedTab.id) == removedTab && state.tab(slot: removedTab.shortcutSlot) == removedTab)
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
        func checkGrid(_ grid: ActivityGrid) {
            let n = grid.columns
            settle()
            for i in 0..<grid.capacity {
                let t = terminals[i + 1]!
                precondition(t.window === window)
                let rect = t.convert(t.bounds, to: host)
                precondition(rect.width > 100 && rect.height > 30)
                let first = terminals[1]!.convert(terminals[1]!.bounds, to: host)
                precondition(abs(rect.width - first.width) < 2 && abs(rect.height - first.height) < 2)
                precondition(abs(rect.minX - first.minX - CGFloat(i % n) * (rect.width + 14)) < 3)
                precondition(abs(abs(rect.minY - first.minY) - CGFloat(i / n) * (rect.height + 38)) < 3)
            }
            precondition(terminals[grid.capacity + 1]!.window == nil)
        }
        for layout in ActivityGrid.allCases {
            state.activityBoards.setGrid(layout, keeping: 0)
            checkGrid(layout)
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
        precondition(legacyBoards.current.title == "Group 1" && legacyBoards.current.slots == [3])

        let data = try JSONEncoder().encode(state.activityBoards)
        var restored = try JSONDecoder().decode(ActivityBoards.self, from: data)
        precondition(restored == state.activityBoards)
        restored.reconcile(with: Array(0..<18))
        precondition(restored.boards[1].slots == [0] && restored.current.slots.last == 17)
        let surviving = restored.boards[1]
        restored.close(1)
        precondition(restored.selected == 2 && restored.boards == [surviving])
        restored.reveal(0)
        restored.remove(0)
        precondition(restored.current.page == restored.current.pageCount - 1)
        window.contentView = nil
        weak var released: ProbeTerminal?
        var retainedHost: NSHostingView<ActivityPanel>?
        autoreleasepool {
            let transientState = WorkspaceState()
            transientState.selected = .activity
            transientState.tabs = [TabActivity(id: 1, shortcutSlot: 0, programIcon: nil, name: "Temporary",
                                              status: "", directory: "~", busy: false, limits: [])]
            transientState.activityBoards.insert(0)
            var transient: ProbeTerminal? = ProbeTerminal()
            released = transient
            retainedHost = NSHostingView(rootView: ActivityPanel(state: transientState, terminalView: { _ in transient },
                close: { _ in }, create: {}, releaseFocus: {}, expand: { _ in }))
            window.contentView = retainedHost
            for _ in 0..<10 {
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
                retainedHost?.layoutSubtreeIfNeeded()
            }
            precondition(transient?.window === window)
            transient?.removeFromSuperview()
            transient = nil
        }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        precondition(released == nil, "A cached host retained a terminal after its session released it")
        window.contentView = nil
        withExtendedLifetime(retainedHost) {}
        print("Positional shortcuts, activity grid, focus, lookup invalidation, restoration and detached terminal release checks passed.")
    }

    @MainActor private static func checkPositionalShortcuts() throws {
        let state = WorkspaceState()
        state.selected = .activity
        let slots = [8, 3, 15, 1, 40]
        state.tabs = slots.enumerated().map { offset, slot in
            TabActivity(id: 101 + offset, shortcutSlot: slot, programIcon: nil,
                        name: "Terminal \(slot)", status: "", directory: "~", busy: false, limits: [])
        }
        state.activityBoards.reconcile(with: [8, 3, 15])
        state.activityBoards.insert(1, startingPage: true)
        state.activityBoards.add()
        state.activityBoards.insert(40)
        precondition(state.navigate(.group, to: .index(0)))
        precondition(state.navigate(.page, to: .index(0)))
        func check(_ expected: [Int]) {
            precondition(expected.indices.compactMap { state.terminal(at: $0)?.shortcutSlot } == expected)
            precondition(state.terminal(at: -1) == nil && state.terminal(at: expected.count) == nil)
            for slot in slots {
                precondition(state.terminalShortcutIndex(for: slot) == expected.firstIndex(of: slot))
            }
        }
        check([8, 3, 15])
        precondition(state.terminal(at: 0)?.id == 101)

        state.activityBoards.reorder(15, to: 8)
        check([15, 8, 3])
        precondition(state.terminal(at: 0)?.id == 103)
        state.activityBoards.remove(8)
        state.tabs.removeAll { $0.shortcutSlot == 8 }
        check([15, 3])

        // Moving to another page resets positions there without renumbering
        // the saved session identities, even when the slice starts above zero.
        precondition(state.activityBoards.transfer([3], from: 1, to: 1, asPage: false, on: 1))
        check([1, 3])
        precondition(state.activityBoards.current.visibleSlots.startIndex > 0)
        precondition(state.activityBoards.reorderPage(in: 1, from: 1, to: 0))
        precondition(state.activityBoards.current.page == 0)
        check([1, 3])
        precondition(state.activityBoards.reorderGroup(2, to: 1))
        precondition(state.activityBoards.selected == 1)
        check([1, 3])
        precondition(state.navigate(.group, to: .index(0)))
        check([40])
        state.activityBoards.close(2)
        check([1, 3])

        // Receiving sessions from another window may remap storage slots;
        // selection still starts at the first position in the destination page.
        state.tabs.append(TabActivity(id: 201, shortcutSlot: 99, programIcon: nil,
                                     name: "Transferred", status: "", directory: "~", busy: false, limits: []))
        state.activityBoards.receive([99], in: 1, asPage: false, on: 0)
        check([1, 3, 99])
        precondition(state.terminalShortcutIndex(for: 99) == 2)

        let data = try JSONEncoder().encode(state.activityBoards)
        let restored = WorkspaceState()
        restored.tabs = state.tabs
        restored.activityBoards = try JSONDecoder().decode(ActivityBoards.self, from: data)
        precondition((0..<3).compactMap { restored.terminal(at: $0)?.id } == [104, 102, 201])
        precondition(restored.tabs.map(\.shortcutSlot) == [3, 15, 1, 40, 99])
        // One terminal per page: numbers cover every terminal in the group, so
        // each gets its own key instead of all of them showing the first one.
        state.activityBoards.setGrid(.single, keeping: 3)
        let groupSlots = state.activityBoards.current.slots
        precondition(groupSlots.count > 1 && state.activityBoards.current.visibleSlots.count == 1)
        check(groupSlots)
        state.activityBoards.add()
        check([])
        precondition(state.terminalShortcutIndex(for: 99) == nil)
    }
}
