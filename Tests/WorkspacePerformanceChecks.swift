// Optimized: swiftc -O -parse-as-library Sources/ActivityBoards.swift Tests/WorkspacePerformanceChecks.swift -o /tmp/banana-workspace-bench
// Baseline: compile the same check with -D BASELINE_PAGINATION and the prior ActivityBoards.swift.
import Foundation

@inline(never)
private func renderPageList(_ board: ActivityBoard) -> Int {
    var count = 0
    #if BASELINE_PAGINATION
    for page in 0..<board.pageCount {
        for slot in board.slots(on: page) { count &+= slot }
    }
    #else
    for page in board.paginatedSlots {
        for slot in page { count &+= slot }
    }
    #endif
    return count
}

@main
enum WorkspacePerformanceChecks {
    static func main() {
        for terminals in [16, 64, 256] {
            var groups = ActivityBoards()
            groups.reconcile(with: Array(0..<terminals))
            let board = groups.current
            var checksum = 0
            let iterations = 5_000
            let start = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<iterations { checksum &+= renderPageList(board) }
            let milliseconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            precondition(checksum == iterations * terminals * (terminals - 1) / 2)
            print("\(terminals) terminals, \(board.pageCount) pages, \(iterations) page-list passes: \(String(format: "%.2f", milliseconds)) ms; checksum \(checksum)")
        }
    }
}
