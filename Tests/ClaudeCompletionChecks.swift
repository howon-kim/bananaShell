// swiftc -parse-as-library Sources/ClaudeCompletion.swift Tests/ClaudeCompletionChecks.swift -o /tmp/banana-completion-checks
import Foundation

@main enum ClaudeCompletionChecks {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID(), now = Date(timeIntervalSince1970: 1000)
        func write(_ name: String, _ text: String) throws {
            try text.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        try write("valid.json", "{\"pane\":\"\(id)\",\"timestamp\":999}")
        try write("stale.json", "{\"pane\":\"\(id)\",\"timestamp\":900}")
        try write("future.json", "{\"pane\":\"\(id)\",\"timestamp\":1001}")
        try write("invalid.json", "{invalid}")
        try write(".pending", "in progress")
        let events = ClaudeCompletion.drain(directory, now: now)
        precondition(events.count == 1 && events.first?.pane == id && events.first?.sender == .claude)
        let test = try JSONDecoder().decode(ClaudeCompletion.self, from: Data("{\"pane\":\"\(id)\",\"timestamp\":999,\"source\":\"test\"}".utf8))
        precondition(test.sender == .test && test.sender.name == "bananaShell Test")
        precondition(test.summary == nil)
        let preview = try JSONDecoder().decode(ClaudeCompletion.self, from: Data("{\"pane\":\"\(id)\",\"timestamp\":999,\"summary\":\"완료\"}".utf8))
        precondition(preview.summary == "완료")
        precondition(ClaudeCompletion.drain(directory, now: now).isEmpty)
        precondition(FileManager.default.fileExists(atPath: directory.appendingPathComponent(".pending").path))
        print("Completion checks passed: routing, stale/future/malformed filtering, exactly-once consumption, atomic writes.")
    }
}
