// Compile with the InputTape declarations from Sources/Recording.swift.
// Disposable Expect PTYs; no saved jobs or user shell configuration are used.
import Foundation

@main enum AutomationInputWaitChecks {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("banana-input-wait-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }
        try Data("PROMPT='%# '; RPROMPT=''\n".utf8).write(to: root.appendingPathComponent(".zshrc"))

        func run(_ script: String, name: String, expected: Int32) throws -> String {
            let file = root.appendingPathComponent(name + ".exp")
            // Compress the normal two-minute limit to one second for testing.
            try Data(script.replacingOccurrences(of: "set timeout 120", with: "set timeout 1").utf8).write(to: file)
            try Data("auto".utf8).write(to: file.appendingPathExtension("policy"))
            let output = root.appendingPathComponent(name + ".log")
            fm.createFile(atPath: output.path, contents: nil)
            let log = try FileHandle(forWritingTo: output)
            defer { try? log.close() }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/expect")
            process.arguments = [file.path]
            process.currentDirectoryURL = root
            process.environment = ["HOME": root.path, "ZDOTDIR": root.path, "PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"]
            process.standardOutput = log; process.standardError = log
            try process.run()
            defer { if process.isRunning { process.terminate() } }
            let deadline = Date(timeIntervalSinceNow: 10)
            while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
            precondition(!process.isRunning, "Replay did not finish: " + name)
            process.waitUntilExit()
            let text = try String(contentsOf: output, encoding: .utf8)
            precondition(process.terminationStatus == expected, "\(name): \(process.terminationStatus)\n\(text)")
            return text
        }

        let command = "sleep 2; printf 'INPUT> '; read value; sleep 2; printf 'RECEIVED=%s\\n' \"$value\""
        let tape = InputTape(commands: [RecordedCommand(text: command, replies: [
            ResponseStep(before: Data("INPUT> ".utf8), keys: Data("hello\r".utf8), after: Data("RECEIVED=hello".utf8))
        ]), RecordedCommand(text: "exit")])
        let script = tape.script()
        let legacy = script.replacingOccurrences(of: "expect -timeout -1 ", with: "expect ")
            .replacingOccurrences(of: "expect eof {} -re $confirmationRE {answer $expect_out(0,string); exp_continue}",
                with: "expect eof {} -re $confirmationRE {answer $expect_out(0,string); exp_continue} timeout {puts stderr {shell exit timeout}; exit 124}")
        precondition(InputTape.updatedDialog(in: legacy) == script, "Existing recording was not upgraded without changing its commands")
        precondition(InputTape.updatedDialog(in: script) == nil, "Migration must be idempotent")
        let input = try run(script, name: "input", expected: 0)
        precondition(input.contains("RECEIVED=hello"))

        let confirmation = InputTape(commands: [RecordedCommand(text: "sleep 2; printf 'Continue [y/n] '; read value; printf 'ANSWER=%s\\n' \"$value\"", replies: [
            ResponseStep(before: Data("Continue [y/n] ".utf8), keys: Data("y\r".utf8))
        ]), RecordedCommand(text: "exit")]).script()
        let confirmed = try run(confirmation, name: "confirmation", expected: 0)
        precondition(confirmed.contains("ANSWER=y"))

        _ = try run(InputTape(commands: [RecordedCommand(text: "sleep 2; exit")]).script(), name: "delayed-exit", expected: 0)

        let noStartup = script.replacingOccurrences(of: "spawn -noecho /bin/zsh -ilo histignorespace", with: "spawn -noecho /bin/sleep 5")
        _ = try run(noStartup, name: "startup-timeout", expected: 124)
        let interrupted = InputTape(commands: [RecordedCommand(text: "kill -KILL $$", replies: [
            ResponseStep(before: Data("never appears".utf8), keys: Data("unused\r".utf8))
        ])]).script()
        _ = try run(interrupted, name: "closed-input", expected: 65)
        print("PASS: delayed input/output and confirmations survive the timeout; startup and EOF guards remain; existing recordings migrate idempotently.")
    }
}
