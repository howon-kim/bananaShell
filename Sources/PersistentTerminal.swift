import Foundation
import Darwin

/// A dedicated tmux server owns the PTYs; the app owns only disposable clients.
struct PersistentTerminal: Sendable {
    struct Pane: Sendable, Equatable {
        let id: UUID
        let slot: Int?
        let pid: Int32
        let tty: String
        let directory: String
        let title: String
        let command: String
        let holdsScroll: Bool

        var foregroundProcessGroup: pid_t {
            // The slave PTY belongs to tmux's session, so tcgetpgrp on a newly
            // opened slave can fail with ENOTTY. Query the owning shell instead.
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout.size(ofValue: info))
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
                  info.e_tpgid > 0, info.e_tpgid <= UInt32(Int32.max) else { return -1 }
            return pid_t(info.e_tpgid)
        }
    }

    let directory: URL
    let socketName: String
    let executable: URL
    var serviceLabel: String { "local.bananaShell.tmux." + socketName }
    private var serviceTarget: String { "gui/\(getuid())/" + serviceLabel }

    init(directory: URL = FileManager.default.homeDirectoryForCurrentUser
         .appendingPathComponent("Library/Application Support/bananaShell/TerminalSessions"),
         socketName: String = "bananaShell-v1", executable: URL? = nil) throws {
        self.directory = directory
        self.socketName = socketName
        let candidates = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/opt/local/bin/tmux"]
            + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { String($0) + "/tmux" }
        guard let binary = executable ?? candidates.first(where: FileManager.default.isExecutableFile(atPath:)).map({ URL(fileURLWithPath: $0) }) else {
            throw Self.failure("tmux is required to keep terminals running. Install it with ‘brew install tmux’, then reopen bananaShell.")
        }
        self.executable = binary
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Ignore the user's tmux configuration, including key bindings and exit rules.
        let configurationURL = directory.appendingPathComponent("tmux.conf")
        let configuration = Data(Self.configuration.utf8)
        if (try? Data(contentsOf: configurationURL)) != configuration {
            try configuration.write(to: configurationURL, options: .atomic)
            // Apply changed bindings to preserved sessions without restarting them.
            try run(["source-file", configurationURL.path], allowMissingServer: true)
        }
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "bananaShell.tmux", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
    private static let configuration = """
    set -g status off
    set -g prefix None
    set -g prefix2 None
    set -g mouse on
    set -g history-limit 50000
    set -g exit-unattached off
    set -g destroy-unattached off
    set -g detach-on-destroy on
    # SSH forwards TERM to the remote host. Older/minimal hosts often lack
    # tmux-256color; screen-256color describes tmux with wider compatibility.
    set -g default-terminal screen-256color
    set -as terminal-features ',xterm-256color:RGB:clipboard'
    set -s set-clipboard on
    set -g set-titles on
    set -g set-titles-string '#{pane_title}'
    set -g remain-on-exit off
    set -s escape-time 10
    # AI applications may redraw or jump to their prompt on new output. Keep
    # wheel-up in our scrollback until the user scrolls down to the live screen.
    bind -n WheelUpPane if -F -t= '#{@banana-hold-scroll}' { copy-mode -e -t=; send-keys -M } { if -F -t= '#{||:#{pane_in_mode},#{mouse_any_flag}}' { send-keys -M } { copy-mode -e -t= } }
    bind -T copy-mode Escape send-keys -X cancel
    bind -T copy-mode-vi Escape send-keys -X cancel
    # tmux owns mouse selection. Its defaults copy and then cancel copy mode
    # on release, erasing the highlight. Copy but keep the selection visible;
    # a later click clears it, and leaves copy mode on the live screen.
    bind -T copy-mode MouseDragEnd1Pane send-keys -X copy-pipe-no-clear
    bind -T copy-mode-vi MouseDragEnd1Pane send-keys -X copy-pipe-no-clear
    bind -T copy-mode DoubleClick1Pane select-pane \\; send-keys -X select-word \\; send-keys -X copy-pipe-no-clear
    bind -T copy-mode-vi DoubleClick1Pane select-pane \\; send-keys -X select-word \\; send-keys -X copy-pipe-no-clear
    bind -T copy-mode TripleClick1Pane select-pane \\; send-keys -X select-line \\; send-keys -X copy-pipe-no-clear
    bind -T copy-mode-vi TripleClick1Pane select-pane \\; send-keys -X select-line \\; send-keys -X copy-pipe-no-clear
    bind -n DoubleClick1Pane select-pane -t= \\; if -F '#{||:#{pane_in_mode},#{mouse_any_flag}}' { send-keys -M } { copy-mode -H; send-keys -X select-word; send-keys -X copy-pipe-no-clear }
    bind -n TripleClick1Pane select-pane -t= \\; if -F '#{||:#{pane_in_mode},#{mouse_any_flag}}' { send-keys -M } { copy-mode -H; send-keys -X select-line; send-keys -X copy-pipe-no-clear }
    bind -T copy-mode MouseDown1Pane select-pane \\; if -F '#{scroll_position}' { send-keys -X clear-selection } { send-keys -X cancel }
    bind -T copy-mode-vi MouseDown1Pane select-pane \\; if -F '#{scroll_position}' { send-keys -X clear-selection } { send-keys -X cancel }
    """

    // Finder and Xcode may launch without LANG/LC_CTYPE. In that environment
    // tmux replaces tabs and non-ASCII characters with underscores, corrupting
    // our metadata records. Force UTF-8 for every control and display client.
    // Clients must never implicitly spawn a server attributed to the app.
    var arguments: [String] { ["-N", "-u", "-L", socketName, "-f", directory.appendingPathComponent("tmux.conf").path] }
    static func name(_ id: UUID) -> String { "banana-" + id.uuidString.lowercased() }
    func attachment(_ id: UUID) -> [String] { arguments + ["attach-session", "-d", "-E", "-t", Self.name(id)] }
    /// A second client (the notch terminal) that leaves the window's client attached.
    func sharedAttachment(_ id: UUID) -> [String] { arguments + ["attach-session", "-E", "-t", Self.name(id)] }

    private static func childEnvironment(_ source: [String: String]) -> [String: String] {
        // Xcode injects UI debugging/checker libraries into the app. Loading
        // those into Homebrew tmux can crash its allocator before main runs.
        // Keep application-specific dyld overrides out of the external process.
        source.filter { key, _ in
            key != "TMUX" && key != "TMUX_PANE" && key != "TMUX_TMPDIR" &&
            !key.hasPrefix("DYLD_") && !key.hasPrefix("__XPC_DYLD_")
        }
    }

    static let serviceArgument = "--persistent-terminal-service"

    // Keep the native app alive as the responsible process. An association
    // alone cannot give the external Homebrew binary our app's code identity.
    static func runServiceIfRequested() {
        guard CommandLine.arguments.dropFirst().first == serviceArgument else { return }
        let arguments = Array(CommandLine.arguments.dropFirst(2))
        guard let executable = arguments.first, executable.hasPrefix("/") else { exit(64) }
        let server = Process()
        server.executableURL = URL(fileURLWithPath: executable)
        server.arguments = Array(arguments.dropFirst())
        server.environment = childEnvironment(ProcessInfo.processInfo.environment)
        do {
            try server.run()
            server.waitUntilExit()
            exit(server.terminationReason == .exit ? server.terminationStatus : 128 + server.terminationStatus)
        } catch {
            FileHandle.standardError.write(Data("Could not start terminal service: \(error.localizedDescription)\n".utf8))
            exit(70)
        }
    }

    func serviceArguments(bundle: Bundle = .main) -> [String] {
        let server = [executable.path, "-D", "-u", "-L", socketName,
                      "-f", directory.appendingPathComponent("tmux.conf").path]
        // Unbundled test runners and SwiftPM builds have no app identity.
        guard bundle.bundleURL.pathExtension == "app",
              bundle.bundleIdentifier == "local.bananaShell",
              let host = bundle.executableURL else { return server }
        return [host.path, Self.serviceArgument] + server
    }

    /// False after a reboot, logout, or crash took down the server with every session.
    func isRunning() throws -> Bool {
        try !run(["show-options", "-sv", "exit-empty"], allowMissingServer: true).isEmpty
    }

    private func ensureServer() throws {
        // Preserve any server from an older app version until its sessions end.
        if try isRunning() { return }

        let file = directory.appendingPathComponent("server.plist")
        let definition: [String: Any] = [
            "Label": serviceLabel,
            // Also associate the background service with the app in Settings.
            "AssociatedBundleIdentifiers": ["local.bananaShell"],
            "ProgramArguments": serviceArguments(),
            "RunAtLoad": true,
            "ProcessType": "Interactive",
            "EnvironmentVariables": ["HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                                     "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
                                     "LANG": "en_US.UTF-8"],
            "StandardOutPath": "/dev/null",
            "StandardErrorPath": directory.appendingPathComponent("server-error.log").path
        ]
        try PropertyListSerialization.data(fromPropertyList: definition, format: .xml, options: 0)
            .write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)

        // Register on demand in this login session. This is deliberately outside
        // ~/Library/LaunchAgents: it does not start terminals automatically at login.
        if try launchctl(["print", serviceTarget], allowFailure: true) {
            // No server is running (checked above). Reload the definition so an
            // older registration also receives the app attribution metadata.
            try launchctl(["bootout", serviceTarget])
        }
        try launchctl(["bootstrap", "gui/\(getuid())", file.path])
        let deadline = Date(timeIntervalSinceNow: 3)
        repeat {
            if try !run(["show-options", "-sv", "exit-empty"], allowMissingServer: true).isEmpty { return }
            Thread.sleep(forTimeInterval: 0.025)
        } while Date() < deadline
        throw Self.failure("The independent terminal service did not become ready. Reopen bananaShell to try again.")
    }

    @discardableResult
    private func launchctl(_ arguments: [String], allowFailure: Bool = false) throws -> Bool {
        let task = Process(), errors = Pipe()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = arguments
        task.environment = Self.childEnvironment(ProcessInfo.processInfo.environment)
        task.standardInput = FileHandle.nullDevice
        task.standardOutput = FileHandle.nullDevice
        task.standardError = errors
        try task.run()
        let data = errors.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else {
            if allowFailure { return false }
            let detail = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw Self.failure("Could not start the independent terminal service.\n" + detail)
        }
        return true
    }

    @discardableResult
    func run(_ command: [String], environment: [String: String]? = nil, allowMissingServer: Bool = false) throws -> String {
        let task = Process(), output = Pipe(), errors = Pipe()
        task.executableURL = executable
        task.arguments = arguments + command
        task.environment = Self.childEnvironment(environment ?? ProcessInfo.processInfo.environment)
        task.standardInput = FileHandle.nullDevice
        task.standardOutput = output
        task.standardError = errors
        try task.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        if task.terminationStatus != 0 {
            if allowMissingServer && (message.contains("no server running") || message.contains("No such file or directory") || message.contains("Connection refused")) { return "" }
            if command.first == "list-panes", message.trimmingCharacters(in: .whitespacesAndNewlines) == "no current target" { return "" }
            let detail = message.trimmingCharacters(in: .whitespacesAndNewlines)
            let reason = task.terminationReason == .uncaughtSignal ? "stopped unexpectedly (signal \(task.terminationStatus))" : "failed (exit \(task.terminationStatus))"
            throw Self.failure("tmux \(command.first ?? "command") \(reason)." +
                               (detail.isEmpty ? "" : "\n" + detail))
        }
        return String(decoding: data, as: UTF8.self)
    }

    func panes() throws -> [Pane] {
        let text = try run(["list-panes", "-a", "-F",
            "#{session_name}\t#{@banana-slot}\t#{pane_pid}\t#{pane_tty}\t#{pane_current_path}\t#{pane_current_command}\t#{@banana-hold-scroll}\t#{pane_title}"], allowMissingServer: true)
        return text.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", maxSplits: 7, omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 8, fields[0].hasPrefix("banana-"),
                  let id = UUID(uuidString: String(fields[0].dropFirst(7))), let pid = Int32(fields[2]) else { return nil }
            return Pane(id: id, slot: Int(fields[1]), pid: pid, tty: fields[3], directory: fields[4], title: fields[7], command: fields[5], holdsScroll: fields[6] == "1")
        }
    }

    func create(id: UUID, slot: Int, shell: String, workingDirectory: String,
                columns: Int, rows: Int, environment: [String: String]) throws {
        try ensureServer()
        let environment = Self.childEnvironment(environment)
        var command = ["new-session", "-d", "-s", Self.name(id), "-c", workingDirectory,
                       "-x", String(max(2, columns)), "-y", String(max(2, rows))]
        // A server outlives the app: explicitly supply each new shell's current environment.
        for (key, value) in environment.sorted(by: { $0.key < $1.key })
            where !["TMUX", "TMUX_PANE", "TERM"].contains(key) {
            command += ["-e", key + "=" + value]
        }
        // Multiple argv entries execute directly, without interpolating paths into shell code.
        command += [shell, "-l", ";", "set-option", "-t", Self.name(id), "@banana-slot", String(slot)]
        try run(command, environment: environment)
    }

    func setShortcutSlot(_ slot: Int, for id: UUID) throws {
        try run(["set-option", "-t", Self.name(id), "@banana-slot", String(slot)])
    }

    func setScrollHold(_ enabled: Bool, for id: UUID) throws {
        try run(["set-option", "-p", "-t", Self.name(id), "@banana-hold-scroll", enabled ? "1" : "0"])
    }

    func kill(_ id: UUID) throws {
        try kill([id])
    }

    func kill(_ ids: [UUID]) throws {
        let requested = Set(ids)
        guard !requested.isEmpty else { return }
        let live = Set(try panes().map(\.id)).intersection(requested)
        guard !live.isEmpty else { return }
        var commands: [String] = []
        for id in live.sorted(by: { $0.uuidString < $1.uuidString }) {
            if !commands.isEmpty { commands.append(";") }
            commands += ["kill-session", "-t", Self.name(id)]
        }
        do { try run(commands) }
        catch {
            // A shell may exit during the batch, stopping the command queue.
            // Retry only requested sessions that still exist; never affect a neighbor.
            let remaining = Set(try panes().map(\.id)).intersection(requested)
            for id in remaining {
                do { try run(["kill-session", "-t", Self.name(id)]) }
                catch {
                    if try panes().contains(where: { $0.id == id }) { throw error }
                }
            }
        }
    }
}

// One in-flight read per app, shared by every window. Slow reads cannot block
// input or accumulate a queue of obsolete timer ticks. Invalidating the owner
// also prevents a late result from updating a window after shutdown.
@MainActor
final class TerminalStatusPoller<Value: Sendable> {
    private let queue = DispatchQueue(label: "bananaShell.terminal-status", qos: .utility)
    private let read: @Sendable () throws -> Value
    private var completion: ((Result<Value, Error>) -> Void)?
    private var inFlight = false
    private var invalidated = false

    init(read: @escaping @Sendable () throws -> Value, completion: @escaping (Result<Value, Error>) -> Void) {
        self.read = read
        self.completion = completion
    }

    func request() {
        guard !invalidated, !inFlight else { return }
        inFlight = true
        let read = self.read
        queue.async { [weak self] in
            let result = Result(catching: read)
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.invalidated else { return }
                self.inFlight = false
                self.completion?(result)
            }
        }
    }

    func invalidate() {
        invalidated = true
        completion = nil
    }
}
