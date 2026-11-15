// swiftc -parse-as-library Sources/PersistentTerminal.swift Tests/TerminalStatusPollerChecks.swift -o /tmp/banana-status-checks
import Foundation

private final class Probe: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var offMain = true
    var calls: Int { lock.lock(); defer { lock.unlock() }; return count }
    var ranOffMain: Bool { lock.lock(); defer { lock.unlock() }; return offMain }
    func record() -> Int {
        lock.lock(); defer { lock.unlock() }
        count += 1
        offMain = offMain && !Thread.isMainThread
        return count
    }
}

@main
enum TerminalStatusPollerChecks {
    @MainActor static func wait(_ message: String, until condition: () -> Bool) async throws {
        let deadline = Date(timeIntervalSinceNow: 3)
        while !condition() {
            guard Date() < deadline else { throw NSError(domain: "PollerChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    @MainActor static func main() async throws {
        let gate = DispatchSemaphore(value: 0), probe = Probe()
        var results: [Int] = []
        let poller = TerminalStatusPoller(read: {
            let call = probe.record()
            gate.wait()
            return call
        }, completion: { result in
            if case .success(let value) = result { results.append(value) }
        })
        for _ in 0..<100 { poller.request() }
        try await wait("Background read never started") { probe.calls == 1 }
        precondition(probe.ranOffMain && results.isEmpty)
        // Reaching this assertion while the read is blocked verifies that the
        // main actor remains responsive, without relying on elapsed-time limits.
        for _ in 0..<100 { poller.request() }
        gate.signal()
        try await wait("First result not delivered") { results == [1] }
        precondition(probe.calls == 1)
        poller.request()
        try await wait("Subsequent refresh never started") { probe.calls == 2 }
        poller.invalidate()
        gate.signal()
        try await Task.sleep(nanoseconds: 50_000_000)
        precondition(results == [1])
        poller.request()
        precondition(probe.calls == 2)

        let retryProbe = Probe()
        var failures = 0, recovered = false
        let retrying = TerminalStatusPoller(read: {
            if retryProbe.record() == 1 { throw NSError(domain: "ExpectedFailure", code: 1) }
            return 42
        }, completion: { result in
            switch result {
            case .failure: failures += 1
            case .success(let value): recovered = value == 42
            }
        })
        retrying.request()
        try await wait("Error was not delivered") { failures == 1 }
        retrying.request()
        try await wait("Polling did not recover after a failed read") { recovered }
        retrying.invalidate()
        print("Status polling checks passed: background work, no queued timer backlog, recovery and shutdown cancellation.")
    }
}
