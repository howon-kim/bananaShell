// Run with: swiftc -parse-as-library Sources/TerminalSlots.swift Tests/TerminalSlotChecks.swift -o /tmp/banana-slot-checks && /tmp/banana-slot-checks
@main
enum TerminalSlotChecks {
    static func main() {
        var slots = (0..<5).map { $0 }
        slots.removeAll { $0 == 1 || $0 == 3 }
        precondition(slots == [0, 2, 4])
        let first = TerminalSlots.assign(occupied: slots)
        precondition(first == 1)
        slots.append(first)
        precondition(TerminalSlots.assign(occupied: slots) == 3)
        precondition(TerminalSlots.assign(occupied: slots.reversed()) == 3)
        precondition(TerminalSlots.assign(occupied: [], preferred: 4) == 4)
        precondition(TerminalSlots.assign(occupied: [4], preferred: 4) == 0)
        precondition(TerminalSlots.assign(occupied: [], preferred: -1) == 0)
        precondition(TerminalSlots.assign(occupied: Array(0..<12)) == 12)
        precondition(TerminalSlots.assign(occupied: [0, 2, 12]) == 1)
        print("Terminal slot reuse, reorder stability, restoration and overflow checks passed.")
    }
}
