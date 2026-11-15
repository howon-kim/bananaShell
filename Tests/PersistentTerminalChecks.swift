// Link with SwiftTerm.o and its module from the Xcode build.
// Also run with `env -u LANG -u LC_ALL -u LC_CTYPE -u TERM` to cover GUI launches.
// BANANA_TEST_XCODE_ENVIRONMENT may name a JSON file of captured Xcode debugger
// variables. Install them after startup to exercise inherited child launches.
import AppKit
import SwiftTerm

@main
struct PersistentTerminalChecks {
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        var debuggerEnvironment: [String: String] = [:]
        if let file = ProcessInfo.processInfo.environment["BANANA_TEST_XCODE_ENVIRONMENT"] {
            debuggerEnvironment = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: URL(fileURLWithPath: file)))
        }
        let originalEnvironment = ProcessInfo.processInfo.environment
        for (key, value) in debuggerEnvironment { setenv(key, value, 1) }
        defer {
            for key in debuggerEnvironment.keys {
                if let value = originalEnvironment[key] { setenv(key, value, 1) }
                else { unsetenv(key) }
            }
        }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("banana-persistence-" + UUID().uuidString)
        let working = root.appendingPathComponent("한글 folder 'with spaces'")
        try fm.createDirectory(at: working, withIntermediateDirectories: true)
        let socket = "banana-test-" + UUID().uuidString
        let server = try PersistentTerminal(directory: root, socketName: socket)
        var clients: [LocalProcessTerminalView] = []
        defer {
            clients.forEach { $0.terminate() }
            _ = try? server.run(["kill-server"])
            let cleanup = Process()
            cleanup.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            cleanup.arguments = ["bootout", "gui/\(getuid())/" + server.serviceLabel]
            cleanup.environment = ["PATH": "/usr/bin:/bin"]
            cleanup.standardOutput = FileHandle.nullDevice
            cleanup.standardError = FileHandle.nullDevice
            if (try? cleanup.run()) != nil { cleanup.waitUntilExit() }
            try? fm.removeItem(at: root)
        }
        func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
            guard try condition() else { throw NSError(domain: "PersistenceChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        func wait(_ message: String, until condition: () throws -> Bool) throws {
            let deadline = Date(timeIntervalSinceNow: 5)
            while try !condition() {
                try check(Date() < deadline, message)
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
            }
        }
        func output(_ id: UUID) throws -> String {
            try server.run(["capture-pane", "-p", "-S", "-", "-t", PersistentTerminal.name(id)])
        }
        func send(_ id: UUID, _ command: String) throws {
            let target = PersistentTerminal.name(id)
            try server.run(["send-keys", "-t", target, "-l", command])
            try server.run(["send-keys", "-t", target, "Enter"])
        }
        func attach(_ id: UUID, through owner: PersistentTerminal) -> LocalProcessTerminalView {
            let view = LocalProcessTerminalView(frame: CGRect(x: 0, y: 0, width: 760, height: 420))
            clients.append(view)
            view.startProcess(executable: owner.executable.path, args: owner.attachment(id),
                              environment: Terminal.getEnvironmentVariables(), currentDirectory: root.path)
            return view
        }
        func visible(_ view: TerminalView) -> String {
            view.visibleRowsText(0..<view.terminalDimensions.rows).joined(separator: "\n")
        }
        func read(_ name: String) -> String? {
            try? String(contentsOf: working.appendingPathComponent(name), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        try Data("PROMPT='test%# '; HISTFILE=''\n".utf8).write(to: root.appendingPathComponent(".zshrc"))
        try Data("""
        #!/bin/sh
        saved=$(stty -g)
        trap 'stty "$saved"' EXIT
        stty icanon echo echoe -echoprt erase '^?'
        printf 'BACKSPACE> '
        printf ready > backspace.ready
        IFS= read -r value
        printf '%s' "$value" > backspace.result
        """.utf8).write(to: working.appendingPathComponent("backspace.sh"))
        func checkBackspace(_ client: LocalProcessTerminalView, in id: UUID) throws {
            for name in ["backspace.ready", "backspace.result"] {
                try? fm.removeItem(at: working.appendingPathComponent(name))
            }
            try send(id, "/bin/sh ./backspace.sh")
            try wait("Input test did not start") { read("backspace.ready") == "ready" }
            client.send(txt: "abc")
            try wait("Typed text did not appear") { visible(client).contains("BACKSPACE> abc") }
            let backspace = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, characters: "\u{7f}", charactersIgnoringModifiers: "\u{7f}",
                isARepeat: false, keyCode: 51)!
            client.keyDown(with: backspace)
            try wait("Backspace did not erase the displayed character") {
                visible(client).contains("BACKSPACE> ab ") && !visible(client).contains("BACKSPACE> abc")
            }
            client.send(txt: "d\r")
            try wait("Backspace did not erase the input character") { read("backspace.result") == "abd" }
        }
        try Data("""
        #!/bin/sh
        trap 'exit 0' HUP TERM INT
        echo $$ > child.pid
        echo "$KEEP_ME:$TERM" > environment.txt
        printf '\\033[?1000h\\033[?1006h'
        i=0
        while :; do
          i=$((i + 1))
          echo "ALIVE-$i"
          echo "$i" > tick
          sleep 0.1
        done
        """.utf8).write(to: working.appendingPathComponent("worker.sh"))
        try Data("""
        #!/bin/sh
        trap 'printf "\\033[?1049l"; exit 0' HUP TERM INT
        printf '\\033[?1049h\\033[2J\\033[HRESTORED-FULL-SCREEN'
        sleep 120
        """.utf8).write(to: working.appendingPathComponent("screen.sh"))

        try check(server.panes().isEmpty, "New server should have no sessions")
        let first = UUID(), second = UUID()
        var env = ["HOME": root.path, "ZDOTDIR": root.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8"]
        env.merge(debuggerEnvironment) { _, value in value }
        let support = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/PromptSupport")
        let theme = root.appendingPathComponent("state"), fifo = root.appendingPathComponent("theme-fifo")
        try Data("Minimal\nPERSISTENT-PROMPT %# ".utf8).write(to: theme)
        try check(mkfifo(fifo.path, 0o600) == 0, "Could not create theme FIFO")
        var themedEnvironment = env
        themedEnvironment.merge(["ZDOTDIR": support.path, "BANANA_STARTUP_DIR": support.path,
                                 "BANANA_THEME_STATE": theme.path, "BANANA_THEME_FIFO": fifo.path]) { _, value in value }
        try server.create(id: first, slot: 3, shell: "/bin/zsh", workingDirectory: working.path, columns: 90, rows: 28, environment: env)
        try server.create(id: second, slot: 6, shell: "/bin/zsh", workingDirectory: working.path, columns: 90, rows: 28, environment: themedEnvironment)
        let original = try server.panes()
        try check(original.count == 2 && original.first(where: { $0.id == first })?.slot == 3, "Session identity or slot missing")
        try check(original.allSatisfy { URL(fileURLWithPath: $0.directory).resolvingSymlinksInPath() == working.resolvingSymlinksInPath() }, "Quoted working directory changed")
        let status = Process(), serviceOutput = Pipe()
        status.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        status.arguments = ["print", "gui/\(getuid())/" + server.serviceLabel]
        status.environment = ["PATH": "/usr/bin:/bin"]
        status.standardOutput = serviceOutput
        try status.run()
        let definition = String(decoding: serviceOutput.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        status.waitUntilExit()
        let serverPID = try server.run(["display-message", "-p", "#{pid}"]).trimmingCharacters(in: .whitespacesAndNewlines)
        try check(status.terminationStatus == 0 && definition.contains("pid = " + serverPID), "tmux is still owned by the app instead of launchd")
        let servicePlist = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: root.appendingPathComponent("server.plist")), options: [], format: nil) as? [String: Any]
        try check(servicePlist?["AssociatedBundleIdentifiers"] as? [String] == ["local.bananaShell"],
                  "Privacy requests are not associated with bananaShell")
        try check(server.run(["show-options", "-gv", "status"]).trimmingCharacters(in: .whitespacesAndNewlines) == "off", "Unexpected tmux status bar")
        try check(server.run(["show-options", "-gv", "default-terminal"]).trimmingCharacters(in: .whitespacesAndNewlines) == "screen-256color",
                  "New shells must advertise an SSH-compatible terminal type")
        let serverEnvironment = try server.run(["show-environment", "-g"])
        try check(!serverEnvironment.contains("DYLD_INSERT_LIBRARIES="), "App debugger leaked into the persistent server")

        let client = attach(first, through: server)
        let screenClient = attach(second, through: server)
        try wait("Clients did not attach") { try server.run(["list-clients", "-F", "#{client_pid}"]).split(separator: "\n").count == 2 }
        try wait("Bundled shell startup did not render") { visible(screenClient).contains("PERSISTENT-PROMPT") }
        try checkBackspace(client, in: first)
        try send(first, "export KEEP_ME='kept across restart'; for n in {1..100}; do echo HISTORY-$n; done; /bin/sh ./worker.sh")
        try send(second, "/bin/sh ./screen.sh")
        try wait("Foreground processes did not start") { (Int(read("tick") ?? "") ?? 0) > 2 && visible(screenClient).contains("RESTORED-FULL-SCREEN") }
        let childPID = pid_t(read("child.pid")!)!
        let foreground = original.first(where: { $0.id == first })!.foregroundProcessGroup
        try check(foreground == childPID, "Foreground process group \(foreground) differs from running job \(childPID)")
        try check(read("environment.txt") == "kept across restart:screen-256color", "Shell environment was not preserved")
        // Simulate an AI TUI that requests mouse events while continuously
        // writing output. Wheel-up must hold history outside that application.
        try server.setScrollHold(true, for: first)
        try check(server.panes().first(where: { $0.id == first })?.holdsScroll == true, "Scroll policy was not saved")
        let target = PersistentTerminal.name(first)
        func inCopyMode() throws -> Bool {
            try server.run(["display-message", "-p", "-t", target, "#{pane_in_mode}"]).trimmingCharacters(in: .whitespacesAndNewlines) == "1"
        }
        client.send(source: client, data: Array("\u{1b}[<64;2;2M".utf8)[...])
        try wait("AI mouse reporting intercepted scrollback") { try inCopyMode() }
        try server.run(["send-keys", "-t", target, "-X", "-N", "20", "scroll-up"])
        let heldScreen = try server.run(["capture-pane", "-p", "-M", "-t", target])
        let heldTick = Int(read("tick")!)!
        try wait("Output stopped while reading history") { (Int(read("tick") ?? "") ?? 0) > heldTick + 5 }
        try check(server.run(["capture-pane", "-p", "-M", "-t", target]) == heldScreen,
                  "New output moved the held scrollback")
        try server.run(["send-keys", "-t", target, "-X", "-N", "10000", "scroll-down"])
        try wait("Scrolling to the bottom did not resume live output") { try !inCopyMode() }
        client.send(source: client, data: Array("\u{1b}[<64;2;2M".utf8)[...])
        try wait("Could not reenter scrollback") { try inCopyMode() }
        client.send(source: client, data: [27])
        try wait("Escape did not resume live output") { try !inCopyMode() }
        try server.setScrollHold(false, for: first)
        let initialTick = Int(read("tick")!)!

        // These are the same SIGTERM client detach operations used by app/window close.
        client.terminate()
        screenClient.terminate()
        try wait("Clients did not detach") { try server.run(["list-clients"]).isEmpty }
        try wait("Process stopped after app detach") { (Int(read("tick") ?? "") ?? 0) > initialTick + 3 }
        try check(kill(childPID, 0) == 0, "Running child died with the client")
        try check(output(first).contains("HISTORY-1"), "Scrollback was discarded")

        // A new owner and new SwiftTerm views must reconnect, never relaunch commands.
        let reopened = try PersistentTerminal(directory: root, socketName: socket)
        let recovered = try reopened.panes()
        try check(recovered.first(where: { $0.id == first })?.pid == original.first(where: { $0.id == first })?.pid, "Shell PID changed on reopen")
        let reattached = attach(first, through: reopened)
        let screenReattached = attach(second, through: reopened)
        try wait("Restored terminal displays are empty") {
            visible(reattached).contains("ALIVE-") && visible(screenReattached).contains("RESTORED-FULL-SCREEN")
        }
        try check(read("child.pid") == String(childPID), "Foreground process was restarted")
        reattached.frame.size = CGSize(width: 520, height: 310)
        let dimensions = reattached.terminalDimensions
        try wait("Reattached PTY did not resize") {
            try server.run(["display-message", "-p", "-t", PersistentTerminal.name(first), "#{pane_width}x#{pane_height}"])
                .trimmingCharacters(in: .whitespacesAndNewlines) == "\(dimensions.cols)x\(dimensions.rows)"
        }

        // × kills this session, including its ordinary foreground job, but not its neighbor.
        try reopened.kill(first)
        try wait("Closed foreground job survived") { kill(childPID, 0) == -1 && errno == ESRCH }
        let afterClose = try reopened.panes()
        try check(afterClose.count == 1 && afterClose[0].id == second && afterClose[0].pid == original.first(where: { $0.id == second })?.pid,
                  "Closing one terminal affected the other session")
        try reopened.kill(first) // An already-ended session is safe to close again.

        // Control-C still reaches the inner application; an explicit shell exit is final.
        screenReattached.send(source: screenReattached, data: ArraySlice([UInt8(3)]))
        try wait("Control-C was intercepted") { try server.run(["display-message", "-p", "-t", PersistentTerminal.name(second), "#{pane_current_command}"]).contains("zsh") }
        try wait("Prompt did not return") { visible(screenReattached).contains("PERSISTENT-PROMPT") }
        try checkBackspace(screenReattached, in: second)
        try Data("Minimal\nUPDATED-PROMPT %# ".utf8).write(to: theme, options: .atomic)
        let themeFD = open(fifo.path, O_RDWR | O_NONBLOCK)
        try check(themeFD >= 0, "Theme pipe did not survive reopening")
        var byte: UInt8 = 10
        _ = write(themeFD, &byte, 1)
        Darwin.close(themeFD)
        try wait("Live theme updates stopped after reconnect") { visible(screenReattached).contains("UPDATED-PROMPT") }
        try send(second, "exit")
        try wait("Exited shell was retained") { try reopened.panes().isEmpty }
        let batchA = UUID(), batchB = UUID(), neighbor = UUID()
        for (slot, id) in [batchA, batchB, neighbor].enumerated() {
            try reopened.create(id: id, slot: slot, shell: "/bin/zsh", workingDirectory: working.path,
                                columns: 90, rows: 28, environment: env)
        }
        let neighborPID = try reopened.panes().first(where: { $0.id == neighbor })!.pid
        try reopened.kill([batchA, batchB, batchA, UUID()])
        let survivors = try reopened.panes()
        try check(survivors.count == 1 && survivors[0].id == neighbor && survivors[0].pid == neighborPID,
                  "Group batch close affected a neighboring session or left a requested session running")
        try reopened.kill([])
        try check(reopened.panes().count == 1, "An empty batch affected a running session")
        try reopened.kill([neighbor])
        try check(reopened.panes().isEmpty, "Last batch session was not closed")
        print("PASS: independent service, detach/reconnect, PIDs, output, SSH-compatible TERM, Backspace input and display, AI scrollback hold and resume, full-screen state, resizing, isolated terminal/group batch close and final shell exit.")
    }
}
