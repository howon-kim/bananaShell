import Foundation

enum ActivityGrid: Int, Codable, CaseIterable {
    case single = 1, quad = 2, sixteen = 4
    var capacity: Int { rawValue * rawValue }
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
        let n = CGFloat(grid.rawValue)
        let spacing = 2 * Self.outerInset + (n - 1) * Self.gap
        cardSize = CGSize(width: max(1, (viewport.width - spacing) / n),
                          height: max(82, (viewport.height - spacing) / n))
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
    private var pages: [Range<Int>] {
        let starts = [0] + (pageBreaks ?? []).filter { $0 > 0 && $0 < slots.count }.sorted()
        return zip(starts, starts.dropFirst() + [slots.count]).flatMap { start, end in
            stride(from: start, to: end, by: grid.capacity).map { $0..<min($0 + grid.capacity, end) }
        }
    }
    var pageCount: Int { max(1, pages.count) }
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
}

// Use stable shortcut slots so board membership survives window restoration.
struct ActivityBoards: Codable, Equatable {
    private(set) var boards = [ActivityBoard(id: 1)]
    private(set) var selected = 1
    private var index: Int { boards.firstIndex { $0.id == selected } ?? 0 }
    var current: ActivityBoard { boards[index] }

    mutating func select(_ id: Int) {
        if boards.contains(where: { $0.id == id }) { selected = id }
    }

    mutating func rename(_ id: Int, to text: String) {
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let i = boards.firstIndex(where: { $0.id == id }) else { return }
        boards[i].customTitle = name
    }

    mutating func reorder(_ slot: Int, to target: Int) {
        guard let from = current.slots.firstIndex(of: slot), let to = current.slots.firstIndex(of: target), from != to else { return }
        boards[index].slots.remove(at: from)
        boards[index].slots.insert(slot, at: to)
    }

    mutating func add() {
        selected = (boards.map(\.id).max() ?? 0) + 1
        boards.append(ActivityBoard(id: selected))
    }

    // Closing a board transfers its sessions to the adjacent board.
    mutating func close(_ id: Int) {
        guard boards.count > 1, let i = boards.firstIndex(where: { $0.id == id }) else { return }
        let removed = boards.remove(at: i)
        let destination = min(i, boards.count - 1)
        let offset = boards[destination].slots.count
        boards[destination].pageBreaks = (boards[destination].pageBreaks ?? []) + (removed.pageBreaks ?? []).map { offset + $0 }
        boards[destination].slots += removed.slots
        if selected == id { selected = boards[destination].id }
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
