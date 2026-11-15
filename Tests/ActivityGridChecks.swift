// swiftc -parse-as-library Sources/ActivityBoards.swift Tests/ActivityGridChecks.swift -o /tmp/banana-grid-checks
import Foundation

@main
struct ActivityGridChecks {
    static func main() throws {
        precondition(ActivityGrid.allCases.map(\.capacity) == [1, 2, 4, 6, 16])
        for (saved, expected) in [(1, ActivityGrid.single), (2, .quad), (4, .sixteen)] {
            let grid = try JSONDecoder().decode(ActivityGrid.self, from: Data(String(saved).utf8))
            precondition(grid == expected)
        }
        let viewport = CGSize(width: 1000, height: 700)
        let dual = ActivityTileLayout(viewport: viewport, grid: .dual)
        precondition(dual.cardSize.width == 487 && dual.cardSize.height == 680)
        let six = ActivityTileLayout(viewport: viewport, grid: .six)
        precondition(abs(six.cardSize.width - 968.0 / 3) < 0.001 && six.cardSize.height == 337)
        precondition(dual.terminalSize.width == 479 && dual.terminalSize.height == 648)
        for grid in ActivityGrid.allCases {
            let layout = ActivityTileLayout(viewport: viewport, grid: grid)
            precondition(abs(layout.cardSize.width * CGFloat(grid.columns) + 6 * CGFloat(grid.columns - 1) + 20 - 1000) < 0.001)
            precondition(abs(layout.cardSize.height * CGFloat(grid.rows) + 6 * CGFloat(grid.rows - 1) + 20 - 700) < 0.001)
            var boards = ActivityBoards()
            boards.reconcile(with: Array(0..<17))
            boards.setGrid(grid, keeping: 16)
            precondition(boards.current.visibleSlots.contains(16))
            precondition(boards.current.pageCount == (17 + grid.capacity - 1) / grid.capacity)
            let snapshot = try JSONEncoder().encode(boards)
            let restored = try JSONDecoder().decode(ActivityBoards.self, from: snapshot)
            precondition(restored == boards)
            boards.setPage(0)
            precondition(boards.current.paginatedSlots.map(Array.init) ==
                (0..<boards.current.pageCount).map { Array(boards.current.slots(on: $0)) })
            precondition(Array(boards.current.visibleSlots) == Array(0..<grid.capacity))
            // Explicit pages must remain separate when switching between rectangular layouts.
            boards.insert(17, startingPage: true)
            boards.setGrid(.dual, keeping: 17)
            precondition(Array(boards.current.visibleSlots) == [17])
            boards.setGrid(.six, keeping: 17)
            precondition(Array(boards.current.visibleSlots) == [17])
        }
        // A detached group preserves page breaks, selection, name and layout,
        // while its terminals stop belonging to the source window.
        var source = ActivityBoards()
        source.reconcile(with: [0, 1, 2])
        source.add()
        source.rename(2, to: "Build")
        source.move(1, to: 2)
        source.insert(3, startingPage: true)
        source.setGrid(.dual, keeping: 3)
        let original = source.current
        let detached = source.detach(2)!
        precondition(detached == original)
        precondition(source.current.slots == [0, 2] && source.selected == 1)
        let destination = ActivityBoards(board: detached)
        precondition(destination.current == original && destination.selected == 2)
        let windows = [source, destination]
        let roundTrip = try JSONDecoder().decode([ActivityBoards].self, from: JSONEncoder().encode(windows))
        precondition(roundTrip == windows)
        precondition(source.detach(999) == nil)
        _ = source.detach(1)
        precondition(source.boards.count == 1 && source.current.slots.isEmpty)

        // Receiving a whole group keeps its pages and name even when group IDs
        // and terminal shortcut slots collide with an existing window.
        var receiving = ActivityBoards()
        receiving.reconcile(with: [0, 1])
        receiving.add()
        receiving.insert(2)
        let existing = receiving.boards
        receiving.receiveGroup(detached, slots: [3, 4])
        precondition(Array(receiving.boards.dropLast()) == existing)
        precondition(receiving.current.id == 3 && receiving.current.title == "Build")
        precondition(receiving.current.slots == [3, 4])
        precondition(receiving.current.grid == detached.grid && receiving.current.page == detached.page)
        precondition(receiving.current.pageBreaks == detached.pageBreaks)
        precondition(Array(receiving.current.visibleSlots) == [4])
        receiving.receiveGroup(ActivityBoard(id: 1), slots: [])
        precondition(receiving.current.id == 4 && receiving.current.title == "Group 1")
        precondition(receiving.current.slots.isEmpty)
        let groupRoundTrip = try JSONDecoder().decode(ActivityBoards.self, from: JSONEncoder().encode(receiving))
        precondition(groupRoundTrip == receiving)

        // Moving a page preserves its order and creates a page boundary at the
        // destination instead of filling the destination's partially empty page.
        var moving = ActivityBoards()
        moving.reconcile(with: [0, 1, 2, 3, 4])
        moving.add()
        moving.insert(5)
        moving.insert(6, startingPage: true)
        let beforeInvalidMove = moving
        precondition(!moving.transfer([0], from: 1, to: 1, asPage: false))
        precondition(!moving.transfer([0, 99], from: 1, to: 2, asPage: true))
        precondition(!moving.transfer([0, 0], from: 1, to: 2, asPage: true))
        precondition(moving == beforeInvalidMove)
        precondition(moving.transfer([0, 1, 2, 3], from: 1, to: 2, asPage: true))
        precondition(moving.boards[0].slots == [4])
        precondition(moving.current.slots == [5, 6, 0, 1, 2, 3])
        precondition(moving.current.pageBreaks == [1, 2])
        precondition(Array(moving.current.visibleSlots) == [0, 1, 2, 3])
        moving.setGrid(.dual, keeping: 0)
        precondition(Array(moving.current.visibleSlots) == [0, 1])
        precondition(Array(moving.current.slots(on: moving.current.page + 1)) == [2, 3])
        precondition(moving.transfer([6], from: 2, to: 1, asPage: false))
        precondition(moving.current.slots == [4, 6])
        precondition(Set(moving.boards.flatMap(\.slots)) == Set(0...6))
        let movedRoundTrip = try JSONDecoder().decode(ActivityBoards.self, from: JSONEncoder().encode(moving))
        precondition(movedRoundTrip == moving)

        var ordered = receiving
        let selectedGroup = ordered.selected
        let savedGroups = Dictionary(uniqueKeysWithValues: ordered.boards.map { ($0.id, $0) })
        precondition(ordered.reorderGroup(1, to: 4))
        precondition(ordered.boards.map(\.id) == [2, 3, 4, 1])
        precondition(ordered.reorderGroup(4, to: 2))
        precondition(ordered.boards.map(\.id) == [4, 2, 3, 1])
        precondition(ordered.selected == selectedGroup)
        precondition(Dictionary(uniqueKeysWithValues: ordered.boards.map { ($0.id, $0) }) == savedGroups)
        precondition(!ordered.reorderGroup(4, to: 4) && !ordered.reorderGroup(99, to: 1))

        // Removing the only terminal on an earlier page must not shift the drop
        // into a later page. Existing page membership stays intact.
        var paged = ActivityBoards()
        paged.reconcile(with: [0])
        paged.insert(1, startingPage: true)
        paged.insert(2)
        paged.insert(3, startingPage: true)
        precondition(paged.transfer([0], from: 1, to: 1, asPage: false, on: 1))
        precondition(Array(paged.current.visibleSlots) == [1, 2, 0])
        precondition(Array(paged.current.slots(on: 1)) == [3])
        precondition(paged.transfer([3], from: 1, to: 1, asPage: false, on: 0))
        precondition(Array(paged.current.visibleSlots) == [1, 2, 0, 3])
        paged.add()
        paged.insert(4)
        precondition(paged.transfer([4], from: 2, to: 1, asPage: false, on: 0))
        precondition(Array(paged.current.visibleSlots) == [4, 1, 2, 0])
        precondition(Array(paged.current.slots(on: 1)) == [3])
        let beforeInvalidPage = paged
        precondition(!paged.transfer([4], from: 1, to: 1, asPage: false, on: 0))
        precondition(!paged.transfer([4], from: 1, to: 2, asPage: false, on: 99))
        precondition(!paged.transfer([4], from: 1, to: 2, asPage: true, on: 0))
        precondition(paged == beforeInvalidPage)
        // Cross-window receipt uses the same page placement after slot remapping.
        paged.receive([5], in: 1, asPage: false, on: 1)
        precondition(Array(paged.current.visibleSlots) == [3, 5])
        precondition(Set(paged.boards.flatMap(\.slots)) == Set(0...5))
        for model in [ordered, paged] {
            let restored = try JSONDecoder().decode(ActivityBoards.self, from: JSONEncoder().encode(model))
            precondition(restored == model)
        }

        var pageOrder = ActivityBoards()
        pageOrder.reconcile(with: [0, 1])
        pageOrder.insert(2, startingPage: true)
        pageOrder.insert(3, startingPage: true)
        pageOrder.insert(4)
        pageOrder.setPage(1)
        precondition(pageOrder.reorderPage(in: 1, from: 0, to: 2))
        precondition(pageOrder.current.slots == [2, 3, 4, 0, 1])
        precondition(Array(pageOrder.current.visibleSlots) == [2] && pageOrder.current.page == 0)
        precondition(pageOrder.reorderPage(in: 1, from: 2, to: 0))
        precondition(pageOrder.current.slots == [0, 1, 2, 3, 4])
        precondition(Array(pageOrder.current.visibleSlots) == [2] && pageOrder.current.page == 1)
        let beforeInvalidReorder = pageOrder
        precondition(!pageOrder.reorderPage(in: 1, from: 0, to: 0))
        precondition(!pageOrder.reorderPage(in: 1, from: 3, to: 0))
        precondition(pageOrder == beforeInvalidReorder)

        // A panel title can target a terminal in another page. Moving the only
        // terminal of an earlier page still targets the original destination.
        precondition(pageOrder.transfer([2], from: 1, to: 1, asPage: false, relativeTo: 4))
        precondition(Array(pageOrder.current.visibleSlots) == [3, 2, 4])
        precondition(Array(pageOrder.current.slots(on: 0)) == [0, 1])
        precondition(pageOrder.transfer([3], from: 1, to: 1, asPage: false, relativeTo: 4))
        precondition(Array(pageOrder.current.visibleSlots) == [2, 4, 3])
        pageOrder.add()
        pageOrder.insert(5)
        precondition(pageOrder.transfer([5], from: 2, to: 1, asPage: false, relativeTo: 0))
        precondition(Array(pageOrder.current.visibleSlots) == [5, 0, 1])
        let beforeInvalidTarget = pageOrder
        precondition(!pageOrder.transfer([5], from: 1, to: 2, asPage: false, relativeTo: 99))
        precondition(pageOrder == beforeInvalidTarget)
        let pageOrderRestored = try JSONDecoder().decode(ActivityBoards.self, from: JSONEncoder().encode(pageOrder))
        precondition(pageOrderRestored == pageOrder)

        // Closing a group removes every page and slot, without merging any of
        // them into either neighbor or changing the neighbor's layout.
        var closingGroups = ActivityBoards()
        closingGroups.reconcile(with: [0, 1])
        closingGroups.add()
        closingGroups.insert(2)
        closingGroups.insert(3, startingPage: true)
        closingGroups.add()
        closingGroups.insert(4)
        let survivors = closingGroups.boards.filter { $0.id != 2 }
        closingGroups.select(2)
        closingGroups.close(2)
        precondition(closingGroups.boards == survivors && closingGroups.selected == 3)
        precondition(Set(closingGroups.boards.flatMap(\.slots)) == [0, 1, 4])
        closingGroups.close(1)
        precondition(closingGroups.current.slots == [4])
        closingGroups.close(3)
        precondition(closingGroups.boards.count == 1 && closingGroups.current.slots.isEmpty)
        let closedRoundTrip = try JSONDecoder().decode(ActivityBoards.self, from: JSONEncoder().encode(closingGroups))
        precondition(closedRoundTrip == closingGroups)
        precondition(closingGroups.current.paginatedSlots.count == 1 && closingGroups.current.paginatedSlots[0].isEmpty)
        print("Grid geometry, legacy persistence, pagination and focus checks passed.")
    }
}
