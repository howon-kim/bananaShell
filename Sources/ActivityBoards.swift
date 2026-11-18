import Foundation

struct WorkspaceGroupDragPayload: Equatable {
    let sourceWindow: UUID
    let sourceGroup: Int
}

struct WorkspaceDragPayload: Equatable {
    let sourceWindow: UUID
    let sourceGroup: Int
    let slots: [Int]
    let isPage: Bool
}

enum ActivityGrid: Int, Codable, CaseIterable {
    // Preserve the saved values of the original square layouts.
    case single = 1, dual = 5, quad = 2, six = 6, sixteen = 4
    var columns: Int {
        switch self {
        case .single: return 1
        case .dual, .quad: return 2
        case .six: return 3
        case .sixteen: return 4
        }
    }
    var rows: Int {
        switch self {
        case .single, .dual: return 1
        case .quad, .six: return 2
        case .sixteen: return 4
        }
    }
    var capacity: Int { columns * rows }
    var label: String { String(capacity) }
}

// Share the actual pane dimensions with the PTY before the shell prints its first prompt.
struct ActivityTileLayout {
    static let outerInset: CGFloat = 10
    static let gap: CGFloat = 6
    static let header: CGFloat = 28
    static let inset: CGFloat = 4
    let cardSize: CGSize
    var terminalSize: CGSize {
        CGSize(width: max(1, cardSize.width - 2 * Self.inset),
               height: max(1, cardSize.height - Self.header - Self.inset))
    }

    init(viewport: CGSize, grid: ActivityGrid) {
        let columns = CGFloat(grid.columns), rows = CGFloat(grid.rows)
        let horizontalSpacing = 2 * Self.outerInset + (columns - 1) * Self.gap
        let verticalSpacing = 2 * Self.outerInset + (rows - 1) * Self.gap
        cardSize = CGSize(width: max(1, (viewport.width - horizontalSpacing) / columns),
                          height: max(82, (viewport.height - verticalSpacing) / rows))
    }
}

struct ActivityBoard: Codable, Identifiable, Equatable {
    let id: Int
    var grid: ActivityGrid = .quad
    var slots: [Int] = []
    var page = 0

    // Explicit page starts split the slot list before automatic grid pagination.
    // Optional so older saved boards decode without migration.
    var pageBreaks: [Int]?
    var customTitle: String?
    var title: String { customTitle ?? "Group \(id)" }
    /// The group's own terminal colors: an installed theme ID, `TerminalTheme.defaultScheme`,
    /// or nil to follow the current theme.
    var colorScheme: String?
    private var pages: [Range<Int>] {
        let ends = (pageBreaks ?? []).filter { $0 > 0 && $0 < slots.count }.sorted() + [slots.count]
        var result: [Range<Int>] = []
        result.reserveCapacity((slots.count + grid.capacity - 1) / grid.capacity + ends.count - 1)
        var start = 0
        for end in ends {
            while start < end {
                let next = min(start + grid.capacity, end)
                result.append(start..<next)
                start = next
            }
        }
        return result
    }
    var pageCount: Int { max(1, pages.count) }
    // Batch consumers calculate pagination once instead of rebuilding every
    // range separately for each page label, move and drag update.
    var paginatedSlots: [ArraySlice<Int>] {
        let ranges = pages
        return ranges.isEmpty ? [slots[0..<0]] : ranges.map { slots[$0] }
    }
    var visibleSlots: ArraySlice<Int> { slots(on: page) }
    func slots(on page: Int) -> ArraySlice<Int> {
        let ranges = pages
        guard ranges.indices.contains(page) else { return [] }
        return slots[ranges[page]]
    }

    mutating func reveal(_ slot: Int) {
        if let index = slots.firstIndex(of: slot), let target = pages.firstIndex(where: { $0.contains(index) }) { page = target }
    }

    mutating func insert(_ slot: Int, startingPage: Bool) {
        var breaks = pageBreaks ?? []
        let index: Int
        if startingPage {
            index = slots.count
            if index > 0 { breaks.append(index) }
        } else if !visibleSlots.isEmpty && visibleSlots.count < grid.capacity {
            index = visibleSlots.endIndex
            breaks = breaks.map { $0 >= index ? $0 + 1 : $0 }
        } else { index = slots.count }
        pageBreaks = breaks
        slots.insert(slot, at: index)
        reveal(slot)
    }

    mutating func remove(_ slot: Int) {
        guard let index = slots.firstIndex(of: slot) else { return }
        let anchor = visibleSlots.first { $0 != slot }
        slots.remove(at: index)
        pageBreaks = Set((pageBreaks ?? []).map { $0 > index ? $0 - 1 : $0 }
            .filter { $0 > 0 && $0 < slots.count }).sorted()
        page = min(page, pageCount - 1)
        if let anchor { reveal(anchor) }
    }

    // Capture page membership before removing the source so an emptied earlier
    // page cannot change which page receives the terminal.
    @discardableResult
    mutating func place(_ slot: Int, on targetPage: Int, relativeTo target: Int? = nil) -> Bool {
        var sections = paginatedSlots.map(Array.init)
        guard sections.indices.contains(targetPage) else { return false }
        var after = false
        if let target {
            guard target != slot, let targetIndex = sections[targetPage].firstIndex(of: target) else { return false }
            after = sections[targetPage].firstIndex(of: slot).map { $0 < targetIndex } ?? false
        } else if sections[targetPage].contains(slot) { return false }
        for i in sections.indices { sections[i].removeAll { $0 == slot } }
        if let target, let index = sections[targetPage].firstIndex(of: target) {
            sections[targetPage].insert(slot, at: index + (after ? 1 : 0))
        } else if sections[targetPage].count >= grid.capacity { sections[targetPage].insert(slot, at: 0) }
        else { sections[targetPage].append(slot) }
        sections.removeAll(where: \.isEmpty)
        replacePages(sections)
        reveal(slot)
        return true
    }

    @discardableResult
    mutating func reorderPage(_ source: Int, to target: Int) -> Bool {
        var sections = paginatedSlots.map(Array.init)
        guard sections.indices.contains(source), sections.indices.contains(target), source != target else { return false }
        let anchor = visibleSlots.first
        let moved = sections.remove(at: source)
        sections.insert(moved, at: target)
        replacePages(sections)
        if let anchor { reveal(anchor) }
        return true
    }

    private mutating func replacePages(_ sections: [[Int]]) {
        slots = sections.flatMap { $0 }
        var offset = 0
        pageBreaks = sections.dropLast().map { section in offset += section.count; return offset }
    }

    func page(containing slot: Int) -> Int? {
        pages.firstIndex { slots[$0].contains(slot) }
    }
}

// Stable storage slots keep board membership intact across window restoration.
// Visible shortcut numbers are derived from the current page's order.
struct ActivityBoards: Codable, Equatable {
    private(set) var boards = [ActivityBoard(id: 1)]
    private(set) var selected = 1
    private var index: Int { boards.firstIndex { $0.id == selected } ?? 0 }
    var current: ActivityBoard { boards[index] }

    init() {}

    init(board: ActivityBoard) {
        boards = [board]
        selected = board.id
    }

    // Detaching transfers the whole board, including explicit pages and layout.
    // The source keeps an empty board when its last group is moved out.
    mutating func detach(_ id: Int) -> ActivityBoard? {
        guard let i = boards.firstIndex(where: { $0.id == id }) else { return nil }
        let board = boards.remove(at: i)
        if boards.isEmpty { boards = [ActivityBoard(id: 1)] }
        if selected == id { selected = boards[min(i, boards.count - 1)].id }
        return board
    }

    // Keep a transferred group separate, with its name, layout and selected page.
    // Only window-local IDs and storage slots need to change on collision.
    mutating func receiveGroup(_ board: ActivityBoard, slots: [Int]) {
        precondition(slots.count == board.slots.count && Set(slots).count == slots.count)
        precondition(Set(boards.flatMap(\.slots)).isDisjoint(with: slots))
        let id = boards.contains(where: { $0.id == board.id }) ? (boards.map(\.id).max() ?? 0) + 1 : board.id
        let title = board.customTitle ?? (id == board.id ? nil : board.title)
        boards.append(ActivityBoard(id: id, grid: board.grid, slots: slots, page: board.page,
                                    pageBreaks: board.pageBreaks, customTitle: title))
        selected = id
    }

    mutating func select(_ id: Int) {
        if boards.contains(where: { $0.id == id }) { selected = id }
    }

    mutating func rename(_ id: Int, to text: String) {
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let i = boards.firstIndex(where: { $0.id == id }) else { return }
        boards[i].customTitle = name
    }

    mutating func setColorScheme(_ id: Int, to scheme: String?) {
        guard let i = boards.firstIndex(where: { $0.id == id }) else { return }
        boards[i].colorScheme = scheme
    }

    mutating func reorder(_ slot: Int, to target: Int) {
        guard let from = current.slots.firstIndex(of: slot), let to = current.slots.firstIndex(of: target), from != to else { return }
        boards[index].slots.remove(at: from)
        boards[index].slots.insert(slot, at: to)
    }

    @discardableResult
    mutating func reorderGroup(_ id: Int, to target: Int) -> Bool {
        guard let from = boards.firstIndex(where: { $0.id == id }),
              let to = boards.firstIndex(where: { $0.id == target }), from != to else { return false }
        let board = boards.remove(at: from)
        boards.insert(board, at: to)
        return true
    }

    @discardableResult
    mutating func reorderPage(in id: Int, from source: Int, to target: Int) -> Bool {
        guard let i = boards.firstIndex(where: { $0.id == id }) else { return false }
        return boards[i].reorderPage(source, to: target)
    }

    mutating func add() {
        selected = (boards.map(\.id).max() ?? 0) + 1
        boards.append(ActivityBoard(id: selected))
    }

    // The owner ends this group's sessions before removing its membership.
    // Moving a group uses detach/receiveGroup, never the close action.
    mutating func close(_ id: Int) {
        _ = detach(id)
    }

    mutating func insert(_ slot: Int, startingPage: Bool = false) {
        boards[index].insert(slot, startingPage: startingPage)
    }

    mutating func remove(_ slot: Int) {
        if let i = boards.firstIndex(where: { $0.slots.contains(slot) }) { boards[i].remove(slot) }
    }

    mutating func move(_ slot: Int, to id: Int) {
        guard let i = boards.firstIndex(where: { $0.id == id }), !boards[i].slots.contains(slot) else { return }
        remove(slot)
        boards[i].slots.append(slot)
        boards[i].reveal(slot)
    }

    // Pages arrive as a separate section even when the target page has space.
    // A smaller target grid may display that section across multiple pages.
    mutating func receive(_ slots: [Int], in id: Int, asPage: Bool, on page: Int? = nil, relativeTo target: Int? = nil) {
        guard !slots.isEmpty, let i = boards.firstIndex(where: { $0.id == id }) else { return }
        if let target, !boards[i].slots.contains(target) { return }
        if let page = target.flatMap({ boards[i].page(containing: $0) }) ?? page {
            guard !asPage, slots.count == 1, boards[i].place(slots[0], on: page, relativeTo: target) else { return }
            selected = id
            return
        }
        let incoming = slots.filter { !boards[i].slots.contains($0) }
        guard let first = incoming.first else { return }
        if asPage {
            let offset = boards[i].slots.count
            if offset > 0 { boards[i].pageBreaks = (boards[i].pageBreaks ?? []) + [offset] }
            boards[i].slots += incoming
        } else {
            for slot in incoming { boards[i].insert(slot, startingPage: false) }
        }
        boards[i].reveal(first)
        selected = id
    }

    @discardableResult
    mutating func transfer(_ slots: [Int], from source: Int, to destination: Int, asPage: Bool, on page: Int? = nil, relativeTo terminal: Int? = nil) -> Bool {
        guard !slots.isEmpty, Set(slots).count == slots.count,
              let board = boards.first(where: { $0.id == source }),
              slots.allSatisfy(board.slots.contains), let target = boards.firstIndex(where: { $0.id == destination }) else { return false }
        if let terminal, !boards[target].slots.contains(terminal) { return false }
        if let page = terminal.flatMap({ boards[target].page(containing: $0) }) ?? page {
            guard !asPage, slots.count == 1, (0..<boards[target].pageCount).contains(page),
                  terminal != slots[0], terminal != nil || !boards[target].slots(on: page).contains(slots[0]) else { return false }
            if source != destination { remove(slots[0]) }
            guard boards[target].place(slots[0], on: page, relativeTo: terminal) else { return false }
            selected = destination
            return true
        }
        guard source != destination else { return false }
        for slot in slots { remove(slot) }
        receive(slots, in: destination, asPage: asPage)
        return true
    }

    mutating func reveal(_ slot: Int) {
        guard let i = boards.firstIndex(where: { $0.slots.contains(slot) }) else { return }
        selected = boards[i].id
        boards[i].reveal(slot)
    }

    mutating func setGrid(_ grid: ActivityGrid, keeping slot: Int?) {
        let anchor = slot ?? current.visibleSlots.first
        boards[index].grid = grid
        boards[index].page = 0
        if let anchor { boards[index].reveal(anchor) }
    }

    mutating func setPage(_ page: Int) {
        boards[index].page = min(max(0, page), current.pageCount - 1)
    }

    mutating func reconcile(with slots: [Int]) {
        var remaining = Set(slots)
        if boards.isEmpty { boards = [ActivityBoard(id: 1)] }
        selected = current.id
        for i in boards.indices {
            for slot in boards[i].slots where remaining.remove(slot) == nil { boards[i].remove(slot) }
            boards[i].page = min(max(0, boards[i].page), boards[i].pageCount - 1)
        }
        boards[index].slots += slots.filter(remaining.contains)
    }
}
