// Link with the SwiftTerm.o and SwiftTerm module produced by the Xcode build.
import AppKit
import Combine
import SwiftUI
import SwiftTerm
import UserNotifications

let shellSurface = NSColor(srgbRed: 0.075, green: 0.082, blue: 0.10, alpha: 1)
func terminalFont(size: CGFloat) -> NSFont { .monospacedSystemFont(ofSize: size, weight: .regular) }

@main
struct AutomationTerminalChecks {
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let target = UUID()
        let label = "local.bananaShell.job." + target.uuidString
        precondition(AutomationNotificationRoute.resolve(action: UNNotificationDefaultActionIdentifier, jobLabel: label) == .open(target))
        precondition(AutomationNotificationRoute.resolve(action: UNNotificationDismissActionIdentifier, jobLabel: label) == nil)
        precondition(AutomationNotificationRoute.resolve(action: "option-1", jobLabel: label) == .answer(1))
        let pane = UUID()
        precondition(AutomationNotificationRoute.resolve(action: UNNotificationDefaultActionIdentifier, jobLabel: nil, pane: pane.uuidString) == .terminal(pane))
        precondition(AutomationNotificationRoute.resolve(action: "option--1", jobLabel: label) == nil)
        for invalid in [nil, "", "other." + target.uuidString, "local.bananaShell.job.bad"] as [String?] {
            precondition(AutomationNotificationRoute.resolve(action: UNNotificationDefaultActionIdentifier, jobLabel: invalid) == nil)
        }
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

        // Copy must work without a menu and with a non-English input layout,
        // before TerminalView's key handling can clear the selection.
        let savedClipboard: [NSPasteboardItem] = NSPasteboard.general.pasteboardItems?.map { item in
            let saved = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { saved.setData(data, forType: type) }
            }
            return saved
        } ?? []
        defer {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects(savedClipboard)
        }
        let copyWindow = NSWindow(contentRect: session.terminal.frame, styleMask: [.titled], backing: .buffered, defer: false)
        copyWindow.contentView = session.terminal
        precondition(copyWindow.makeFirstResponder(session.terminal))
        session.terminal.selectAll(nil)
        let copyKey = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                      timestamp: 0, windowNumber: copyWindow.windowNumber, context: nil,
                                      characters: "ㅊ", charactersIgnoringModifiers: "ㅊ", isARepeat: false, keyCode: 8)!
        precondition(session.handleCopyShortcut(copyKey))
        precondition(NSPasteboard.general.string(forType: .string)?.contains("✔︎ 설치 중") == true)
        precondition(session.handleCopyShortcut(copyKey))
        precondition(NSPasteboard.general.string(forType: .string)?.contains("완료") == true)
        copyWindow.contentView = nil

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
        try Data().write(to: stream)
        let emptied = try reader.read()
        precondition(emptied.reset && emptied.bytes.isEmpty, "An empty truncation must still reset the terminal")
        try check(!reader.read().reset)
        try append(Data("resumed".utf8), to: stream)
        try check(reader.read().bytes == Data("resumed".utf8))
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

        // Idle polls must not invalidate SwiftUI. Errors publish once, and a
        // successful retry clears the error while continuing to display output.
        var idleUpdates = 0
        let idleObserver = session.objectWillChange.sink { idleUpdates += 1 }
        for _ in 0..<100 { session.readOutput() }
        precondition(idleUpdates == 0, "Unchanged output published redundant UI updates")
        idleObserver.cancel()

        let unavailable = root.appendingPathComponent("recover.log")
        try fm.createSymbolicLink(atPath: unavailable.path, withDestinationPath: unavailable.lastPathComponent)
        let recovering = AutomationTerminalSession(outputURL: unavailable, offset: 0, sizeURL: nil)
        var errorUpdates = 0
        let errorObserver = recovering.objectWillChange.sink { errorUpdates += 1 }
        for _ in 0..<10 { recovering.readOutput() }
        precondition(recovering.failure != nil && errorUpdates == 1, "Repeated errors should publish only once")
        try fm.removeItem(at: unavailable)
        try Data("Recovered".utf8).write(to: unavailable)
        recovering.readOutput()
        settle()
        precondition(recovering.failure == nil && errorUpdates == 2 && text(recovering.terminal).contains("Recovered"))
        errorObserver.cancel()

        // Run a real disposable Expect PTY, never Homebrew or a saved user job.
        try Data("PROMPT='%# '; RPROMPT=''\n".utf8).write(to: root.appendingPathComponent(".zshrc"))
        let command = #"printf '\033[2J\033[H\033[32m✔︎ 설치 중\033[0m\r\n'; printf '\r진행 10%%'; sleep 0.3; printf '\r\033[2K완료\r\n'; /bin/stty size; sleep 1; /bin/stty size"#
        let tape = InputTape(commands: [RecordedCommand(text: command), RecordedCommand(text: "exit")])
        let script = tape.script(jobName: "한글 자동화")
        precondition(script.contains("fconfigure stdout -translation binary -buffering none"))
        precondition(InputTape.updatedTerminalOutput(in: script) == nil, "Migration must be idempotent")
        var legacy = String(script[script.range(of: "set env(TERM)")!.lowerBound...])
        let runtimeStart = legacy.range(of: "proc updateTerminalSize {}")!.lowerBound
        let runtimeEnd = legacy.range(of: "\nforwardInput\n")!.upperBound
        legacy.removeSubrange(runtimeStart..<runtimeEnd)
        legacy = legacy.replacingOccurrences(of: "log_file -a -leaveopen stdout\n", with: "")
        precondition(InputTape.updatedTerminalOutput(in: legacy) == script, "Existing commands changed during migration")
        // Live terminal v1 replays (without keyboard input) gain input forwarding only.
        let inputStart = script.range(of: "proc inputFiles {}")!.lowerBound
        let inputEnd = script.range(of: "\nforwardInput\n")!.upperBound
        var v1 = script; v1.removeSubrange(inputStart..<inputEnd)
        precondition(InputTape.updatedTerminalOutput(in: v1) == script, "v1 replay was not upgraded with input forwarding")
        var controls: [String] = []
        let scheduler = JobScheduler(home: root, control: { controls.append($0[0]) })
        let job = ScheduledJob(id: UUID(), name: "Disposable test", command: command, directory: root.path,
                               hour: 9, minute: 0, hourly: false, recording: tape, policy: .ask)
        try scheduler.add(job)
        let stored = root.appendingPathComponent("Library/Application Support/bananaShell/Recordings/" + job.label + ".exp")
        try Data(legacy.utf8).write(to: stored)
        let agent = root.appendingPathComponent("Library/LaunchAgents/" + job.label + ".plist")
        func definition(_ url: URL) throws -> [String: Any] {
            try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as! [String: Any]
        }
        var oldAgent = try definition(agent)
        oldAgent["ProgramArguments"] = ["/usr/bin/expect", stored.path]
        try PropertyListSerialization.data(fromPropertyList: oldAgent, format: .xml, options: 0).write(to: agent)
        let legacyJobs = try scheduler.jobs()
        controls.removeAll()
        try check(legacyJobs.first?.needsOutputUpgrade == true)
        try check(!scheduler.upgradeOutput(for: legacyJobs) { [job.label: true] })
        precondition(controls.isEmpty)
        try check(scheduler.upgradeOutput(for: legacyJobs) { [job.label: false] })
        precondition(controls == ["bootout", "bootstrap"])
        try check(scheduler.jobs().first?.needsOutputUpgrade == false)
        try check(String(contentsOf: stored, encoding: .utf8) == script)
        let permissions = try fm.attributesOfItem(atPath: stored.path)[.posixPermissions] as! NSNumber
        precondition(permissions.intValue == 0o600)
        let replay = stored
        try Data("100 24".utf8).write(to: scheduler.terminalSizeURL(job))
        let output = scheduler.logURL(job)
        try Data("previous run".utf8).write(to: output)
        let priorID = try scheduler.outputFileID(job)
        let args = try definition(agent)["ProgramArguments"] as! [String]
        let task = Process()
        task.executableURL = URL(fileURLWithPath: args[0])
        task.arguments = Array(args.dropFirst())
        task.currentDirectoryURL = root
        task.environment = ["HOME": root.path, "ZDOTDIR": root.path, "PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"]
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
        try check(scheduler.outputFileID(job) != priorID && !transcript.contains("previous run"))
        precondition(task.terminationStatus == 0, "Replay failed: \(transcript)")
        precondition(sawLive, "The terminal only received output after process exit")
        precondition(raw.range(of: Data("✔︎ 설치 중".utf8)) != nil && !transcript.contains("â"), "Expect re-encoded PTY bytes")
        precondition(!transcript.contains("unset HISTFILE"), "Bootstrap commands leaked into the terminal")
        let size = live.terminal.terminalDimensions
        precondition(transcript.contains("\(size.rows) \(size.cols)"), "PTY did not follow the viewer size: \(transcript)")
        precondition(text(live.terminal).contains("완료") && !text(live.terminal).contains("진행 10%"))
        try scheduler.remove(job)
        precondition(!fm.fileExists(atPath: scheduler.terminalSizeURL(job).path))

        // Short, equal-length and silent runs can all finish between two viewer polls.
        let plain = ScheduledJob(id: UUID(), name: "Plain command", command: "/bin/cat payload >&2",
                                 directory: root.path, hour: 10, minute: 15, hourly: true)
        try scheduler.add(plain)
        let plainAgent = root.appendingPathComponent("Library/LaunchAgents/" + plain.label + ".plist")
        let plainArgs = try definition(plainAgent)["ProgramArguments"] as! [String]
        let plainLog = scheduler.logURL(plain)
        let viewer = AutomationOutputReader(url: plainLog, offset: 0)
        let console = AutomationTerminalSession(outputURL: plainLog, offset: 0, sizeURL: nil)
        for payload in ["First", "Other", "", "OK"] {
            try Data(payload.utf8).write(to: root.appendingPathComponent("payload"))
            let run = Process()
            run.executableURL = URL(fileURLWithPath: plainArgs[0])
            run.arguments = Array(plainArgs.dropFirst())
            run.environment = task.environment
            run.currentDirectoryURL = root
            try run.run()
            run.waitUntilExit()
            precondition(run.terminationStatus == 0)
            let chunk = try viewer.read()
            precondition(chunk.bytes == Data(payload.utf8) && (payload == "First" || chunk.reset))
            try check(Data(contentsOf: plainLog) == Data(payload.utf8))
            console.readOutput()
            settle()
            precondition(text(console.terminal).trimmingCharacters(in: .whitespacesAndNewlines) == payload)
        }
        try check(Data(contentsOf: output) == raw)

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
        confirm.executableURL = URL(fileURLWithPath: "/usr/bin/expect")
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
