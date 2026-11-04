// Link with the SwiftTerm.o and SwiftTerm module produced by the Xcode build.
import AppKit
import SwiftUI
import SwiftTerm

let shellSurface = NSColor(srgbRed: 0.075, green: 0.082, blue: 0.10, alpha: 1)
func terminalFont(size: CGFloat) -> NSFont { .monospacedSystemFont(ofSize: size, weight: .regular) }

@main
struct AutomationTerminalChecks {
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("banana-automation-check-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        func append(_ data: Data, to url: URL) throws {
            let f = try FileHandle(forWritingTo: url)
            defer { try? f.close() }
            try f.seekToEnd(); try f.write(contentsOf: data)
        }
        func settle(_ seconds: Double = 0.08) {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
        }
        func text(_ view: TerminalView) -> String {
            view.visibleRowsText(0..<view.terminalDimensions.rows).joined(separator: "\n")
        }
        func check(_ condition: @autoclosure () throws -> Bool) throws {
            let result = try condition()
            precondition(result)
        }

        // A continuation byte, CSI parameters and a CR redraw can all cross reads.
        let stream = root.appendingPathComponent("stream.log")
        fm.createFile(atPath: stream.path, contents: Data())
        let session = AutomationTerminalSession(outputURL: stream, offset: 0, sizeURL: nil)
        let display = Data("\u{1b}[32m✔︎ 설치 중\u{1b}[0m\r\n진행 10%\r\u{1b}[2K완료".utf8)
        for byte in display {
            try append(Data([byte]), to: stream)
            session.readOutput()
        }
        settle()
        precondition(text(session.terminal).contains("✔︎ 설치 중"), "Split UTF-8 was corrupted")
        precondition(text(session.terminal).contains("완료") && !text(session.terminal).contains("진행 10%"), "CR/erase redraw was appended as a log line")

        // Restarts skip old output; truncation and replacement reset the screen.
        let reader = AutomationOutputReader(url: stream, offset: UInt64(display.count))
        try check(reader.read().bytes.isEmpty)
        try append(Data("NEW".utf8), to: stream)
        try check(reader.read().bytes == Data("NEW".utf8))
        try Data("reset".utf8).write(to: stream)
        let truncated = try reader.read()
        precondition(truncated.reset && truncated.bytes == Data("reset".utf8))
        try Data("replacement".utf8).write(to: stream, options: .atomic)
        let replaced = try reader.read()
        precondition(replaced.reset && replaced.bytes == Data("replacement".utf8))
        let missing = root.appendingPathComponent("later.log")
        let lateReader = AutomationOutputReader(url: missing, offset: 0)
        try check(lateReader.read().bytes.isEmpty)
        try Data("arrived".utf8).write(to: missing)
        try check(lateReader.read().bytes == Data("arrived".utf8))
        let large = root.appendingPathComponent("large.log")
        try Data(repeating: 120, count: 2 * 1024 * 1024).write(to: large)
        let largeReader = AutomationOutputReader(url: large, offset: 0)
        let first = try largeReader.read()
        precondition(first.omitted && first.bytes.count == 256 * 1024)
        var total = first.bytes.count
        for _ in 0..<4 { total += try largeReader.read().bytes.count }
        precondition(total == 1024 * 1024, "Historical output was not bounded")

        // Run a real disposable Expect PTY, never Homebrew or a saved user job.
        try Data("PROMPT='%# '; RPROMPT=''\n".utf8).write(to: root.appendingPathComponent(".zshrc"))
        let command = #"printf '\033[2J\033[H\033[32m✔︎ 설치 중\033[0m\r\n'; printf '\r진행 10%%'; sleep 0.3; printf '\r\033[2K완료\r\n'; /bin/stty size; sleep 1; /bin/stty size"#
        let tape = InputTape(commands: [RecordedCommand(text: command), RecordedCommand(text: "exit")])
        let script = tape.script(jobName: "한글 자동화")
        precondition(script.contains("fconfigure stdout -translation binary -buffering none"))
        precondition(InputTape.updatedTerminalOutput(in: script) == nil, "Migration must be idempotent")
        var legacy = String(script[script.range(of: "set env(TERM)")!.lowerBound...])
        let runtimeStart = legacy.range(of: "proc updateTerminalSize {}")!.lowerBound
        let runtimeEnd = legacy.range(of: "\nwatchTerminalSize\n")!.upperBound
        legacy.removeSubrange(runtimeStart..<runtimeEnd)
        legacy = legacy.replacingOccurrences(of: "log_file -a -leaveopen stdout\n", with: "")
        precondition(InputTape.updatedTerminalOutput(in: legacy) == script, "Existing commands changed during migration")
        let scheduler = JobScheduler(home: root, control: { _ in })
        let job = ScheduledJob(id: UUID(), name: "Disposable test", command: command, directory: root.path,
                               hour: 9, minute: 0, hourly: false, recording: tape, policy: .ask)
        try scheduler.add(job)
        let stored = root.appendingPathComponent("Library/Application Support/bananaShell/Recordings/" + job.label + ".exp")
        try Data(legacy.utf8).write(to: stored)
        _ = try scheduler.jobs()
        try check(String(contentsOf: stored, encoding: .utf8) == script)
        let permissions = try fm.attributesOfItem(atPath: stored.path)[.posixPermissions] as! NSNumber
        precondition(permissions.intValue == 0o600)
        try Data("100 24".utf8).write(to: scheduler.terminalSizeURL(job))
        try scheduler.remove(job)
        precondition(!fm.fileExists(atPath: scheduler.terminalSizeURL(job).path))
        let replay = root.appendingPathComponent("replay.exp")
        try Data(script.utf8).write(to: replay)
        try Data("100 24".utf8).write(to: replay.appendingPathExtension("size"))
        let output = root.appendingPathComponent("replay.log")
        fm.createFile(atPath: output.path, contents: nil)
        let log = try FileHandle(forWritingTo: output)
        defer { try? log.close() }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/expect")
        task.arguments = [replay.path]
        task.currentDirectoryURL = root
        task.environment = ["HOME": root.path, "ZDOTDIR": root.path, "PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"]
        task.standardOutput = log; task.standardError = log
        try task.run()
        defer { if task.isRunning { task.terminate() } }
        let live = AutomationTerminalSession(outputURL: output, offset: 0, sizeURL: replay.appendingPathExtension("size"))
        live.start(active: true)
        defer { live.stop() }
        var sawLive = false, resized = false
        let deadline = Date(timeIntervalSinceNow: 15)
        while task.isRunning && Date() < deadline {
            settle(0.025)
            let visible = text(live.terminal)
            if visible.contains("✔︎ 설치 중") {
                sawLive = true
                if !resized {
                    // Exercise the actual delegate path used when SwiftUI resizes.
                    live.terminal.setFrameSize(NSSize(width: 700, height: 280))
                    resized = true
                }
            }
        }
        precondition(!task.isRunning, "Replay did not finish")
        task.waitUntilExit(); live.readOutput(); settle()
        let raw = try Data(contentsOf: output)
        let transcript = String(decoding: raw, as: UTF8.self)
        precondition(task.terminationStatus == 0, "Replay failed: \(transcript)")
        precondition(sawLive, "The terminal only received output after process exit")
        precondition(raw.range(of: Data("✔︎ 설치 중".utf8)) != nil && !transcript.contains("â"), "Expect re-encoded PTY bytes")
        precondition(!transcript.contains("unset HISTFILE"), "Bootstrap commands leaked into the terminal")
        let size = live.terminal.terminalDimensions
        precondition(transcript.contains("\(size.rows) \(size.cols)"), "PTY did not follow the viewer size: \(transcript)")
        precondition(text(live.terminal).contains("완료") && !text(live.terminal).contains("진행 10%"))

        // Confirmation replay continues to work with the binary terminal stream.
        let confirmCommand = #"printf 'Upgrade [y/n] '; read reply; printf '\r\nanswer=%s\r\n' "$reply""#
        let confirmTape = InputTape(commands: [RecordedCommand(text: confirmCommand, replies: [
            ResponseStep(before: Data("Upgrade [y/n] ".utf8), keys: Data("y\r".utf8))
        ]), RecordedCommand(text: "exit")])
        let confirmScript = root.appendingPathComponent("confirm.exp")
        try Data(confirmTape.script().utf8).write(to: confirmScript)
        try Data("auto".utf8).write(to: confirmScript.appendingPathExtension("policy"))
        let confirmOutput = root.appendingPathComponent("confirm.log")
        fm.createFile(atPath: confirmOutput.path, contents: nil)
        let confirmLog = try FileHandle(forWritingTo: confirmOutput)
        defer { try? confirmLog.close() }
        let confirm = Process()
        confirm.executableURL = task.executableURL
        confirm.arguments = [confirmScript.path]
        confirm.environment = task.environment
        confirm.currentDirectoryURL = root
        confirm.standardOutput = confirmLog; confirm.standardError = confirmLog
        try confirm.run()
        defer { if confirm.isRunning { confirm.terminate() } }
        let confirmDeadline = Date(timeIntervalSinceNow: 8)
        while confirm.isRunning && Date() < confirmDeadline { settle(0.025) }
        precondition(!confirm.isRunning, "Confirmation stopped replay")
        confirm.waitUntilExit()
        let confirmed = try String(contentsOf: confirmOutput, encoding: .utf8)
        precondition(confirm.terminationStatus == 0 && confirmed.contains("answer=y") && confirmed.contains("selected Yes"), confirmed)

        // Opening a finished task still mounts a selectable native terminal.
        let host = NSHostingView(rootView: AutomationConsole(outputURL: output, offset: 0, sizeURL: nil, active: false))
        let window = NSWindow(contentRect: NSRect(x: -3000, y: 0, width: 860, height: 360),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        settle(0.2); host.layoutSubtreeIfNeeded()
        if let path = ProcessInfo.processInfo.environment["AUTOMATION_CHECK_SCREENSHOT"],
           let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
        window.contentView = nil
        print("Automation terminal checks passed: live PTY, split UTF-8/ANSI, progress redraws, resize, existing-job migration, confirmations, offsets, rotation and bounded history.")
    }
}
