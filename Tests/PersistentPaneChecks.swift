// swiftc -parse-as-library Sources/PersistentTerminal.swift Tests/PersistentPaneChecks.swift -o /tmp/banana-pane-checks
import Foundation

@main
enum PersistentPaneChecks {
    static func main() {
        let first = UUID(uuidString: "453331B7-4B7F-4775-BD56-25C38435FD9C")!, second = UUID()
        func row(_ id: UUID, window: Int = 1, active: Int = 1, pid: String = "123",
                 slot: String = "3", title: String = "Active split") -> String {
            [String(window), String(active), PersistentTerminal.name(id), slot, pid,
             "/dev/ttys001", "/tmp/한글 folder", "zsh", "1", title].joined(separator: "\t")
        }
        // A split and an inactive window share the session's UUID. Neither
        // should replace the selected pane, regardless of enumeration order.
        let selected = row(first, title: "Active\tsplit")
        let other = row(second, pid: "456", slot: "", title: "")
        let rows = [row(first, active: 0, pid: "100"), row(first, window: 0, pid: "101"),
                    selected, other, selected, row(first, pid: "999")]
        let panes = PersistentTerminal.parsePanes(rows.joined(separator: "\n"))
        precondition(panes.count == 2 && Set(panes.map(\.id)).count == 2)
        precondition(panes[0].id == first && panes[0].pid == 123 && panes[0].slot == 3)
        precondition(panes[0].directory == "/tmp/한글 folder" && panes[0].title == "Active\tsplit")
        precondition(panes[0].tty == "/dev/ttys001" && panes[0].command == "zsh" && panes[0].holdsScroll)
        precondition(panes[1].id == second && panes[1].pid == 456 && panes[1].slot == nil && panes[1].title.isEmpty)
        // This is the dictionary operation that previously crashed.
        precondition(Dictionary(uniqueKeysWithValues: panes.map { ($0.id, $0) }).count == 2)
        let switched = PersistentTerminal.parsePanes([
            row(first, active: 0), row(first, pid: "789"), row(first, window: 0)
        ].joined(separator: "\n"))
        precondition(switched.count == 1 && switched[0].pid == 789)
        let invalid = ["", "malformed", row(first, pid: "invalid"),
                       row(first).replacingOccurrences(of: PersistentTerminal.name(first), with: "unrelated"),
                       row(first).replacingOccurrences(of: first.uuidString.lowercased(), with: "invalid")]
        precondition(PersistentTerminal.parsePanes(invalid.joined(separator: "\n")).isEmpty)
        precondition(PersistentTerminal.parsePanes((invalid + [selected]).joined(separator: "\n")).count == 1)
        print("PASS: unique terminal UUIDs, active split/window selection, duplicate records, metadata and malformed records.")
    }
}
