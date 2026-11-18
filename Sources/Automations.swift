import Combine
import SwiftUI
import Foundation

enum ConfirmationPolicy: String, CaseIterable {
    case ask, auto
    var title: String { self == .ask ? "Ask me" : "Automatically allow" }
}

struct ScheduledJob: Identifiable {
    let id: UUID
    let name: String
    let command: String
    let directory: String
    let hour: Int
    let minute: Int
    let hourly: Bool
    var recording: InputTape? = nil
    var policy: ConfirmationPolicy? = nil
    var needsOutputUpgrade = false
    var schedule: String {
        hourly ? String(format: "Hourly at :%02d", minute) : String(format: "Daily at %02d:%02d", hour, minute)
    }
    var label: String { "local.bananaShell.job." + id.uuidString }
}

// Display the bounded PTY transcript without changing the on-disk diagnostic log.
enum RunLogText {
    private static let marker = try! NSRegularExpression(pattern: #"\x1B\]777;[0-9a-fA-F-]{36}:([RC])\x07"#)
    private static let controls = try! NSRegularExpression(pattern:
        #"\x1B\][^\x07\x1B]*(?:\x07|\x1B\\|$)|\x1B\[[0-?]*[ -/]*[@-~]|\x1B[()][0-9A-Za-z]|\x1B[@-Z\\-_=>]|[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]"#)

    static func render(_ data: Data) -> String {
        let raw = String(decoding: data, as: UTF8.self) as NSString
        let full = NSRange(location: 0, length: raw.length)
        var result = "", offset = 0, betweenCommands = false
        func append(_ range: NSRange, beforeReady: Bool = false) {
            var chunk = raw.substring(with: range)
            // Older replays echoed the bootstrap line, then zsh drew it again
            // using cursor movement. Keep diagnostics emitted before that redraw.
            if let hook = chunk.range(of: #"(?m)^[ \t]*(?:unset HISTFILE|HISTFILE=/dev/null); PROMPT_EOL_MARK=.+(?:\n|$)"#, options: .regularExpression) {
                chunk.removeSubrange(hook)
            }
            if beforeReady && (chunk.contains("_bs_pre") || chunk.contains("preexec_functions")) {
                if let redraw = chunk.range(of: #"\x1B(?:\[1m|\]2;|\[\?2004h)"#, options: .regularExpression) {
                    chunk = String(chunk[..<redraw.lowerBound])
                }
            }
            if betweenCommands {
                // This region is the shell prompt and its line editor, not child output.
                chunk = chunk.components(separatedBy: .newlines).filter {
                    $0.contains("bananaShell:") || $0.contains("context timeout") || $0.contains("premature EOF") || $0.contains("unexpected shell prompt")
                }.joined(separator: "\n")
            }
            let clean = controls.stringByReplacingMatches(in: chunk, range: NSRange(chunk.startIndex..., in: chunk), withTemplate: "")
            result += clean.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        }
        for m in marker.matches(in: raw as String, range: full) {
            let ready = raw.substring(with: m.range(at: 1)) == "R"
            append(NSRange(location: offset, length: m.range.location - offset), beforeReady: ready)
            betweenCommands = ready
            offset = NSMaxRange(m.range)
        }
        append(NSRange(location: offset, length: full.length - offset))
        return result.replacingOccurrences(of: #"(?<=[^\n])(?=bananaShell: confirmation (?:accepted|declined))"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"(?m)^[ \t]+$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .newlines)
    }
}

struct JobScheduler {
    let home: URL
    let control: ([String]) throws -> Void
    init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
         control: @escaping ([String]) throws -> Void = JobScheduler.launchctl) {
        self.home = home
        self.control = control
    }
    private var agents: URL { home.appendingPathComponent("Library/LaunchAgents") }
    private var domain: String { "gui/\(getuid())" }
    private func file(_ job: ScheduledJob) -> URL { agents.appendingPathComponent(job.label + ".plist") }
    // Publish an empty file before starting the command. A reader can identify a new
    // run even when it finishes between polls with exactly the same number of bytes.
    private static let outputLauncher = #"""
    log=$1
    shift
    fresh=$(/usr/bin/mktemp "${log}.XXXXXXXX") || exit 1
    exec >"$fresh"
    /bin/mv -f "$fresh" "$log" || { /bin/rm -f "$fresh"; exit 1; }
    exec "$@" 2>&1
    """#
    private static let launcherName = "bananaShell-automation"
    private func launchArguments(_ command: [String], for job: ScheduledJob) -> [String] {
        ["/bin/sh", "-c", Self.outputLauncher, Self.launcherName, logURL(job).path] + command
    }
    private func commandArguments(_ arguments: [String]) -> [String] {
        if arguments.count > 5, arguments[0] == "/bin/sh", arguments[3] == Self.launcherName {
            return Array(arguments.dropFirst(5))
        }
        return arguments
    }
    private static func launchError(_ message: String, code: Int = 1) -> NSError {
        NSError(domain: "bananaShell.scheduler", code: code, userInfo: [NSLocalizedDescriptionKey: message])
    }
    static func launchctl(_ arguments: [String]) throws {
        let task = Process(), pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = arguments
        task.standardError = pipe
        try task.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        if task.terminationStatus != 0 {
            throw launchError(String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines), code: Int(task.terminationStatus))
        }
    }
    func jobs() throws -> [ScheduledJob] {
        let files: [URL]
        do { files = try FileManager.default.contentsOfDirectory(at: agents, includingPropertiesForKeys: nil) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) { return [] }
        return try files.filter { $0.lastPathComponent.hasPrefix("local.bananaShell.job.") && $0.pathExtension == "plist" }.compactMap { url in
            let label = url.deletingPathExtension().lastPathComponent
            guard let id = UUID(uuidString: String(label.dropFirst("local.bananaShell.job.".count))),
                  let p = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any],
                  p["Label"] as? String == label, let name = p["Comment"] as? String,
                  let arguments = p["ProgramArguments"] as? [String],
                  let directory = p["WorkingDirectory"] as? String,
                  let time = p["StartCalendarInterval"] as? [String: Int], let minute = time["Minute"] else { return nil }
            let args = commandArguments(arguments)
            guard args.count == 3 || (args.count == 2 && args.first == "/usr/bin/expect") else { return nil }
            var job = ScheduledJob(id: id, name: name, command: args.count == 3 ? args[2] : (p["bananaShellCommand"] as? String ?? "Terminal recording"), directory: directory, hour: time["Hour"] ?? 0, minute: minute, hourly: time["Hour"] == nil, needsOutputUpgrade: args == arguments)
            if p["bananaShellConfirmation"] as? Bool == true {
                let replay = replayURL(job)
                if args == ["/usr/bin/expect", replay.path], let old = try? String(contentsOf: replay, encoding: .utf8) {
                    let dialog = InputTape.updatedDialog(in: old) ?? old
                    let updated = InputTape.updatedTerminalOutput(in: dialog) ?? dialog
                    if updated != old {
                        try Data(updated.utf8).write(to: replay, options: .atomic)
                        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: replay.path)
                    }
                }
                job.policy = (try? String(contentsOf: policyURL(job), encoding: .utf8)).flatMap(ConfirmationPolicy.init(rawValue:)) ?? .ask
            }
            return job
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    private var logFolder: URL { home.appendingPathComponent("Library/Logs/bananaShell") }
    func logURL(_ job: ScheduledJob) -> URL { logFolder.appendingPathComponent(job.label + ".log") }
    func terminalSizeURL(_ job: ScheduledJob) -> URL { replayURL(job).appendingPathExtension("size") }
    /// The live terminal writes typed keys beside this replay script.
    func terminalInputURL(_ job: ScheduledJob) -> URL { replayURL(job) }

    func outputFileID(_ job: ScheduledJob) throws -> UInt64? {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: logURL(job).path)
            return (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) { return nil }
    }

    /// Limit each refresh to the end of the file, even for long-running jobs.
    func recentOutput(_ job: ScheduledJob, since offset: UInt64) throws -> String {
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: logURL(job)) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) { return "" }
        defer { try? handle.close() }
        let end = try handle.seekToEnd()
        let limit: UInt64 = 64 * 1024
        guard end > offset else { return "" }
        let start = max(offset, end > limit ? end - limit : 0)
        try handle.seek(toOffset: start)
        let data = try handle.read(upToCount: Int(limit)) ?? Data()
        return (start > offset ? "… Earlier output omitted …\n" : "") + RunLogText.render(data)
    }
    private func replayURL(_ job: ScheduledJob) -> URL {
        home.appendingPathComponent("Library/Application Support/bananaShell/Recordings").appendingPathComponent(job.label + ".exp")
    }
    struct PendingQuestion: Equatable {
        let nonce: String
        let options: [String]
        let question: String
    }
    func pendingQuestion(_ job: ScheduledJob) -> PendingQuestion? {
        let url = replayURL(job).appendingPathExtension("pending")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let fields = text.split(separator: "\n", maxSplits: 3)
        guard fields.count == 4, let deadline = TimeInterval(fields[1]), (deadline == 0 || deadline > Date().timeIntervalSince1970),
              fields[0].range(of: #"^[0-9]+-[0-9]+$"#, options: .regularExpression) != nil,
              let pid = Int32(fields[0].prefix(while: { $0.isNumber })), pid > 0, kill(pid, 0) == 0 else { return nil }
        let options = fields[2].split(separator: "/").map(String.init)
        guard (2...3).contains(options.count) else { return nil }
        return PendingQuestion(nonce: String(fields[0]), options: options, question: String(fields[3]))
    }
    func markViewing(_ job: ScheduledJob) {
        let url = replayURL(job).appendingPathExtension("viewing")
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        } else if job.policy != nil { try? Data().write(to: url, options: .atomic) }
    }
    func respond(_ option: String, to request: PendingQuestion, for job: ScheduledJob) throws {
        guard pendingQuestion(job) == request, request.options.contains(option) else {
            throw Self.launchError("This question is no longer waiting for an answer.")
        }
        try Data(option.utf8).write(to: replayURL(job).appendingPathExtension(request.nonce + ".reply"), options: .atomic)
    }
    private func policyURL(_ job: ScheduledJob) -> URL { replayURL(job).appendingPathExtension("policy") }
    func setPolicy(_ policy: ConfirmationPolicy, for job: ScheduledJob) throws {
        try Data(policy.rawValue.utf8).write(to: policyURL(job), options: .atomic)
    }
    func add(_ job: ScheduledJob) throws {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard job.directory.hasPrefix("/"), fm.fileExists(atPath: job.directory, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw Self.launchError("Choose an existing working directory.")
        }
        try fm.createDirectory(at: agents, withIntermediateDirectories: true)
        try fm.createDirectory(at: logFolder, withIntermediateDirectories: true)
        let log = logURL(job).path
        let replay = replayURL(job)
        var arguments = ["/bin/zsh", "-lc", job.command]
        if let tape = job.recording {
            guard !tape.commands.isEmpty, fm.isExecutableFile(atPath: "/usr/bin/expect") else { throw Self.launchError("No recorded commands or the expect executable is unavailable.") }
            try fm.createDirectory(at: replay.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            arguments = ["/usr/bin/expect", replay.path]
        }
        var plist: [String: Any] = ["Label": job.label, "Comment": job.name,
            "ProgramArguments": launchArguments(arguments, for: job), "WorkingDirectory": job.directory,
            "StartCalendarInterval": job.hourly ? ["Minute": job.minute] : ["Hour": job.hour, "Minute": job.minute],
            "StandardOutPath": log, "StandardErrorPath": log]
        if let tape = job.recording { plist["bananaShellCommand"] = tape.summary; plist["bananaShellConfirmation"] = true }
        let url = file(job)
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: url, options: .withoutOverwriting)
        do {
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            if let tape = job.recording {
                try setPolicy(job.policy ?? .ask, for: job)
                try Data(tape.script(jobName: job.name).utf8).write(to: replay, options: .withoutOverwriting)
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: replay.path)
            }
            try control(["bootstrap", domain, url.path])
        } catch {
            if job.recording != nil { try? fm.removeItem(at: replay); try? fm.removeItem(at: policyURL(job)) }
            try fm.removeItem(at: url)
            throw error
        }
    }
    // Replace the registered definition in place so its ID, output and replay history survive edits.
    func update(_ job: ScheduledJob) throws {
        var isDirectory: ObjCBool = false
        guard job.directory.hasPrefix("/"), FileManager.default.fileExists(atPath: job.directory, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw Self.launchError("Choose an existing working directory.")
        }
        let url = file(job), original = try Data(contentsOf: url)
        guard var plist = try PropertyListSerialization.propertyList(from: original, format: nil) as? [String: Any],
              plist["Label"] as? String == job.label else { throw Self.launchError("Invalid automation definition.") }
        plist["Comment"] = job.name
        plist["WorkingDirectory"] = job.directory
        plist["StartCalendarInterval"] = job.hourly ? ["Minute": job.minute] : ["Hour": job.hour, "Minute": job.minute]
        var changes: [(URL, Data)] = []
        if let tape = job.recording {
            guard !tape.commands.isEmpty, job.policy != nil else { throw Self.launchError("Record a command first.") }
            changes.append((replayURL(job), Data(tape.script(jobName: job.name).utf8)))
            plist["bananaShellCommand"] = tape.summary
        }
        guard let arguments = plist["ProgramArguments"] as? [String] else { throw Self.launchError("Invalid automation command.") }
        var command = commandArguments(arguments)
        if command.count == 3 { command[2] = job.command }
        plist["ProgramArguments"] = launchArguments(command, for: job)
        if let policy = job.policy { changes.append((policyURL(job), Data(policy.rawValue.utf8))) }
        changes.append((url, try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)))
        try replaceFiles(changes, for: job, registered: true)
    }

    // Existing LaunchAgents keep their loaded arguments until re-registered.
    // Let an active run finish and keep an unloaded job unloaded.
    func upgradeOutput(for jobs: [ScheduledJob], readRegistrations: () throws -> [String: Bool] = JobScheduler.registrations) throws -> Bool {
        let legacy = jobs.filter(\.needsOutputUpgrade)
        guard !legacy.isEmpty else { return true }
        let registrations = try readRegistrations()
        var finished = true
        for job in legacy {
            if registrations[job.label] == true { finished = false; continue }
            let url = file(job)
            guard var plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any],
                  let args = plist["ProgramArguments"] as? [String], args == commandArguments(args) else { continue }
            plist["ProgramArguments"] = launchArguments(args, for: job)
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try replaceFiles([(url, data)], for: job, registered: registrations[job.label] != nil)
        }
        return finished
    }

    private func replaceFiles(_ changes: [(URL, Data)], for job: ScheduledJob, registered: Bool) throws {
        let url = file(job)
        let backups = try changes.map { (file, _) in
            (file, FileManager.default.fileExists(atPath: file.path) ? try Data(contentsOf: file) : nil)
        }
        if registered { try control(["bootout", domain + "/" + job.label]) }
        func write(_ data: Data, _ file: URL) throws {
            try data.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        do {
            for (file, data) in changes { try write(data, file) }
            if registered { try control(["bootstrap", domain, url.path]) }
        } catch {
            let cause = error
            do {
                for (file, data) in backups {
                    if let data { try write(data, file) }
                    else if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
                }
                if registered { try control(["bootstrap", domain, url.path]) }
            } catch { throw Self.launchError("Update failed: " + cause.localizedDescription + ". Could not restore the previous schedule: " + error.localizedDescription) }
            throw cause
        }
    }

    func runNow(_ job: ScheduledJob) throws {
        if job.needsOutputUpgrade, try !upgradeOutput(for: [job]) { return }
        try control(["kickstart", domain + "/" + job.label])
    }
    func stopCurrentRun(_ job: ScheduledJob) throws {
        try control(["kill", "SIGTERM", domain + "/" + job.label])
    }

    // One read covers both manually and periodically started agents.
    static func runningLabels() throws -> Set<String> {
        Set(try registrations().filter(\.value).keys)
    }
    private static func registrations() throws -> [String: Bool] {
        let task = Process(), pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = ["list"]
        task.standardOutput = pipe
        try task.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { throw launchError("Could not read automation status.") }
        var registrations: [String: Bool] = [:]
        for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
            let fields = line.split(maxSplits: 2, whereSeparator: \.isWhitespace)
            guard fields.count == 3, fields[2].hasPrefix("local.bananaShell.job.") else { continue }
            registrations[String(fields[2])] = (Int32(fields[0]) ?? 0) > 0
        }
        return registrations
    }
    func remove(_ job: ScheduledJob) throws {
        do { try control(["bootout", domain + "/" + job.label]) }
        catch let error as NSError where error.domain == "bananaShell.scheduler" && error.code == 3 { /* already unloaded */ }
        let replay = replayURL(job)
        if FileManager.default.fileExists(atPath: replay.path) { try FileManager.default.removeItem(at: replay) }
        if FileManager.default.fileExists(atPath: policyURL(job).path) { try FileManager.default.removeItem(at: policyURL(job)) }
        if FileManager.default.fileExists(atPath: terminalSizeURL(job).path) { try FileManager.default.removeItem(at: terminalSizeURL(job)) }
        try FileManager.default.removeItem(at: file(job))
    }
}

struct AutomationPanel: View {
    let openRequest: CurrentValueSubject<UUID?, Never>
    private let scheduler: JobScheduler
    private let runningLabels: () throws -> Set<String>
    init(openRequest: CurrentValueSubject<UUID?, Never> = .init(nil), scheduler: JobScheduler = .init(),
         runningLabels: @escaping () throws -> Set<String> = JobScheduler.runningLabels) {
        self.openRequest = openRequest
        self.scheduler = scheduler
        self.runningLabels = runningLabels
    }
    @State private var jobs: [ScheduledJob] = []
    @State private var running: Set<String> = []
    @State private var waiting: Set<String> = []
    @State private var outputFiles: [String: UInt64] = [:]
    @State private var query = ""
    @State private var selection: UUID?
    @State private var showingDetail = false
    @State private var copied: String?
    @State private var adding = false
    @State private var editing: ScheduledJob?
    @State private var removal: ScheduledJob?
    @State private var error: String?

    private var matches: [ScheduledJob] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return term.isEmpty ? jobs : jobs.filter { job in
            [job.name, job.command, job.directory, job.schedule].contains { $0.localizedCaseInsensitiveContains(term) }
        }
    }
    private var current: ScheduledJob? { matches.first(where: { $0.id == selection }) ?? matches.first }

    var body: some View {
        GeometryReader { geo in
            let narrow = geo.size.width < 690
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Automations")
                            .font(TabTypography.suite(size: NSFont.preferredFont(forTextStyle: .title1).pointSize, relativeTo: .title))
                            .bold().kerning(-0.6)
                        Text("Scheduled commands · Local time")
                            .font(TabTypography.suite(size: NSFont.preferredFont(forTextStyle: .caption1).pointSize + 1, relativeTo: .caption))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { adding = true } label: { Label("Add Automation", systemImage: "plus") }
                        .fixedSize()
                }.padding(.trailing, jobs.isEmpty || (narrow && !showingDetail) ? 0 : 20)
                if let error { Text(error).font(.callout).foregroundStyle(.orange).textSelection(.enabled).padding(.trailing, 20) }
                if jobs.isEmpty {
                    emptyState("No automations yet", message: "Choose Add Automation to record and schedule commands.", icon: "clock.arrow.circlepath")
                } else {
                    HStack(alignment: .top, spacing: 16) {
                        if !narrow || !showingDetail {
                            VStack(alignment: .leading, spacing: 14) {
                                TextField("Search by name, command, or folder", text: $query)
                                    .textFieldStyle(.roundedBorder)
                                    .accessibilityLabel("Search automations")
                                ScrollView {
                                    VStack(spacing: 4) {
                                        ForEach(matches) { job in sidebarRow(job) }
                                        if matches.isEmpty { Text("No matching automations").foregroundStyle(.secondary) }
                                    }
                                }
                            }.frame(maxWidth: narrow ? .infinity : 260)
                        }
                        if !narrow { Divider() }
                        if !narrow || showingDetail {
                            ScrollView {
                                VStack(alignment: .leading, spacing: 16) {
                                    if narrow { Button("‹  All Automations") { showingDetail = false } }
                                    if let job = current {
                                        detail(job, terminalHeight: max(260, min(420, geo.size.height - 300)))
                                    } else {
                                        emptyState("No matching automations", message: "Try a different name, command, or folder.", icon: "magnifyingglass")
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
                                 .padding(.trailing, 20)
                            }
                        }
                    }
                }
            }.padding([.leading, .vertical], 20)
             .padding(.trailing, jobs.isEmpty || (narrow && !showingDetail) ? 20 : 0)
        }.onAppear { reload() }
        .task {
            let readLabels = runningLabels
            while !Task.isCancelled {
                do {
                    let labels = try await Task.detached(priority: .utility) { try readLabels() }.value
                    guard !Task.isCancelled else { break }
                    for job in jobs {
                        let key = job.label
                        let fileID = try scheduler.outputFileID(job)
                        let replaced = fileID != outputFiles[key]
                        let started = labels.contains(key) && !running.contains(key)
                        if selection == nil && (started || (replaced && fileID != nil)) {
                            selection = job.id
                            showingDetail = true
                        }
                        if replaced { outputFiles[key] = fileID }
                    }
                    if labels != running { running = labels }
                    let requests = Set(jobs.filter { labels.contains($0.label) && scheduler.pendingQuestion($0) != nil }.map(\.label))
                    if requests != waiting { waiting = requests }
                } catch { self.error = error.localizedDescription }
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { break }
            }
        }
        .onReceive(openRequest.compactMap { $0 }) { id in
            // CurrentValueSubject retains a click delivered before this view mounts.
            openRequest.send(nil)
            do {
                jobs = try scheduler.jobs()
                guard jobs.contains(where: { $0.id == id }) else {
                    error = "This automation no longer exists."
                    return
                }
                query = ""
                selection = id
                showingDetail = true
                error = nil
            } catch { self.error = error.localizedDescription }
        }
        .sheet(isPresented: $adding) { JobEditor { job in
            try scheduler.add(job)
            selection = job.id
            query = ""
            showingDetail = true
            adding = false
            reload()
        } }
        .sheet(item: $editing) { existing in
            JobEditor(existing: existing) { job in
                guard !(try runningLabels()).contains(job.label) else {
                    throw NSError(domain: "bananaShell.scheduler", code: 1, userInfo: [NSLocalizedDescriptionKey: "Stop the current run before saving changes."])
                }
                try scheduler.update(job)
                query = ""; selection = job.id; editing = nil
                reload()
            }
        }
        .alert("Delete this automation?", isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } }), presenting: removal) { job in
            Button("Delete", role: .destructive) {
                do { try scheduler.remove(job); reload() } catch { self.error = error.localizedDescription }
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text($0.name + " will no longer run on schedule.") }
    }

    private func sidebarRow(_ job: ScheduledJob) -> some View {
        let active = running.contains(job.label)
        return LibraryRow(selected: current?.id == job.id, select: { selection = job.id; showingDetail = true }) {
            HStack {
                mark(job, size: 34)
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: job.name).lineLimit(1)
                    HStack(spacing: 5) {
                        if running.contains(job.label) {
                            Circle().fill(waiting.contains(job.label) ? Color.orange : Color.green).frame(width: 5, height: 5)
                        }
                        Text(job.schedule).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .help(job.name + " · " + job.command)
        } action: {
            PanelActionButton(symbol: active ? "stop.fill" : "play.fill", title: (active ? "Stop " : "Run ") + job.name,
                              highlighted: active) { toggleRun(job) }
        }
        .contextMenu {
            Button(running.contains(job.label) ? "Stop Current Run" : "Run Now") { toggleRun(job) }
            Divider()
            Button("Delete Automation…", role: .destructive) { removal = job }
        }
    }

    private func mark(_ job: ScheduledJob, size: CGFloat) -> some View {
        let ink: Color = waiting.contains(job.label) ? .orange : running.contains(job.label) ? .green : .accentColor
        return Image(systemName: waiting.contains(job.label) ? "bubble.left" : "clock.arrow.circlepath")
            .font(.system(size: size * 0.45, weight: .medium)).foregroundStyle(ink)
            .frame(width: size, height: size)
            .background(ink.opacity(0.12), in: RoundedRectangle(cornerRadius: SurfaceRadius.tile)).accessibilityHidden(true)
    }

    @ViewBuilder private func detail(_ job: ScheduledJob, terminalHeight: CGFloat) -> some View {
        let active = running.contains(job.label)
        HStack(alignment: .top, spacing: 14) {
            mark(job, size: 56)
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: job.name).font(.title2.bold()).fixedSize(horizontal: false, vertical: true)
                Text(job.schedule).font(.caption.monospaced()).foregroundStyle(.secondary)
                if active {
                    Label(waiting.contains(job.label) ? "Waiting for input" : "Running",
                          systemImage: waiting.contains(job.label) ? "bubble.left" : "waveform")
                        .font(.caption).foregroundStyle(waiting.contains(job.label) ? .orange : .green)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            AutomationHeaderActions(running: active, name: job.name,
                                    toggle: { toggleRun(job) }, edit: { editing = job }, remove: { removal = job })
        }
        Divider()
        if active || outputFiles[job.label] != nil {
            AutomationRun(job: job, active: active, scheduler: scheduler, terminalHeight: terminalHeight)
                .id("\(job.id):\(outputFiles[job.label] ?? 0)")
        } else {
            emptyState("Ready to run", message: "The live terminal appears here when this automation starts.", icon: "terminal")
                .frame(height: terminalHeight)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
        }
        Divider()
        VStack(alignment: .leading, spacing: 24) {
            copyField("Command", job.command, icon: "terminal")
            copyField("Working directory", (job.directory as NSString).abbreviatingWithTildeInPath, icon: "folder")
            if let policy = job.policy {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Confirmation").settingsSectionTitle()
                    HStack(spacing: 8) {
                        ForEach(ConfirmationPolicy.allCases, id: \.self) { option in
                            confirmationOption(option, selected: policy == option, job: job)
                        }
                    }
                }
            }
        }
    }

    private func copyField(_ title: String, _ value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).settingsSectionTitle()
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon).font(.system(size: 13)).foregroundStyle(.secondary)
                    .frame(width: 18, height: 20).accessibilityHidden(true)
                Text(verbatim: value).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                PanelActionButton(symbol: copied == value ? "checkmark" : "doc.on.doc",
                                  title: "Copy " + title, highlighted: copied == value) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(value, forType: .string)
                    copied = value
                }
            }.padding(16).settingsSurface()
        }.task(id: copied) {
            guard copied == value else { return }
            do { try await Task.sleep(nanoseconds: 1_500_000_000); copied = nil } catch {}
        }
    }

    private func confirmationOption(_ policy: ConfirmationPolicy, selected: Bool, job: ScheduledJob) -> some View {
        EditorChoice(policy: policy, selected: selected) {
            do { try scheduler.setPolicy(policy, for: job); reload() }
            catch { self.error = error.localizedDescription }
        }
    }

    private func emptyState(_ title: String, message: String, icon: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.largeTitle).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func toggleRun(_ job: ScheduledJob) {
        do {
            if running.contains(job.label) { try scheduler.stopCurrentRun(job) }
            else {
                try scheduler.runNow(job)
                outputFiles[job.label] = try scheduler.outputFileID(job)
            }
            selection = job.id
            query = ""
            showingDetail = true
            running = try runningLabels()
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func reload() {
        do {
            jobs = try scheduler.jobs()
            if !jobs.contains(where: { $0.id == selection }) { selection = matches.first?.id }
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}

private struct JobEditor: View {
    @Environment(\.dismiss) var dismiss
    @State private var name = ""
    @State private var policy: ConfirmationPolicy = .ask
    @StateObject private var recorder = RecordingSession()
    @State private var hourly = false
    @State private var hour: String
    @State private var minute: String
    @State private var error: String?
    let existing: ScheduledJob?
    let save: (ScheduledJob) throws -> Void
    @State private var recording: Bool
    @State private var directory: String
    @State private var command: String

    init(existing: ScheduledJob? = nil, save: @escaping (ScheduledJob) throws -> Void) {
        self.existing = existing
        self.save = save
        _name = State(initialValue: existing?.name ?? "")
        _policy = State(initialValue: existing?.policy ?? .ask)
        _hour = State(initialValue: String(format: "%02d", existing?.hour ?? 9))
        _minute = State(initialValue: String(format: "%02d", existing?.minute ?? 0))
        _hourly = State(initialValue: existing?.hourly ?? false)
        _directory = State(initialValue: existing?.directory ?? "")
        _command = State(initialValue: existing?.command ?? "")
        _recording = State(initialValue: existing == nil)
    }

    private var canSave: Bool {
        (hourly || ScheduleNumber.parse(hour, in: 0...23) != nil) && ScheduleNumber.parse(minute, in: 0...59) != nil &&
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        (recording ? recorder.finished && recorder.count > 0 && recorder.error == nil
                   : !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    var body: some View {
        EditorSheet(icon: "clock.arrow.circlepath",
                    title: existing == nil ? "Add Automation" : "Edit Automation",
                    subtitle: "Choose what runs on this Mac and when.",
                    message: recorder.error ?? error) {
            if recording && !recorder.finished {
                editorSection("01", "Record commands") { liveRecording }
            } else {
                HStack(alignment: .top, spacing: 14) {
                    VStack(spacing: 12) {
                        editorSection("01", "Details") {
                            editorField("Name") { TextField("Automation name", text: $name) }
                        }
                        editorSection("02", "Schedule") { scheduleFields }
                    }.frame(width: 268)
                    VStack(spacing: 12) {
                        editorSection("03", recording || existing?.policy != nil ? "Recording" : "Command") {
                            commandFields
                        }
                        if recording || existing?.policy != nil {
                            editorSection("04", "Confirmation prompts") {
                                HStack(spacing: 8) {
                                    ForEach(ConfirmationPolicy.allCases, id: \.self) { option in
                                        EditorChoice(policy: option, selected: policy == option) { policy = option }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        } actions: {
            Spacer()
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Button(existing == nil ? "Save and Schedule" : "Save changes", action: submit)
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(!canSave)
        }
        .onChange(of: recorder.finished) { finished in
            if finished && name.isEmpty { name = recorder.tape.suggestedName }
        }
        .onDisappear { recorder.stop() }
    }

    private var scheduleFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                EditorChoice("Daily", symbol: "calendar", selected: !hourly) { hourly = false }
                EditorChoice("Hourly", symbol: "clock", selected: hourly) { hourly = true }
            }
            VStack(spacing: 0) {
                if !hourly {
                    ScheduleNumber(title: "Hour", value: $hour, range: 0...23)
                    Divider().padding(.horizontal, 10)
                }
                ScheduleNumber(title: "Minute", value: $minute, range: 0...59)
            }.settingsSurface()
            Text("Uses your Mac’s local time. Runs while you’re logged in, even when bananaShell is closed.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var commandFields: some View {
        if recording {
            Text("Recorded commands: \(recorder.tape.commands.count)").font(.callout).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(recorder.tape.commands.indices, id: \.self) { i in
                        let cmd = recorder.tape.commands[i]
                        Text(verbatim: cmd.text).font(.body.monospaced())
                        ForEach(cmd.replies.indices, id: \.self) { j in
                            let r = cmd.replies[j]
                            Text(verbatim: "  " + String(decoding: r.before, as: UTF8.self) + " → " + String(reflecting: String(decoding: r.keys, as: UTF8.self)) + " → " + String(decoding: r.after, as: UTF8.self)).font(.caption.monospaced())
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 160)
        } else if existing?.policy != nil {
            Text(verbatim: command).font(.system(size: 12, design: .monospaced))
                .lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
            Button { recording = true } label: {
                Label("Replace recording…", systemImage: "arrow.triangle.2.circlepath")
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 12).frame(height: 30)
            }.buttonStyle(HoverButtonStyle(cornerRadius: SurfaceRadius.tile)).settingsSurface()
        } else {
            editorField("Shell command") { TextField("Command", text: $command).font(.body.monospaced()) }
        }
        editorField("Working directory") {
            if recording {
                Text(verbatim: recorder.directory).font(TabTypography.path(size: 12))
            } else {
                TextField("Absolute path", text: $directory).font(TabTypography.path(size: 12))
            }
        }
    }

    @ViewBuilder private var liveRecording: some View {
        Text("● Recording · Run your commands in this terminal.").foregroundStyle(.orange)
        Text("Commands and follow-up keystrokes are recorded. Do not enter passwords or tokens. Type exit at the shell prompt when finished.").font(.callout)
        RecordingConsole(session: recorder).frame(height: 300)
        if let prompt = recorder.prompt {
            HStack {
                Text(verbatim: prompt.question).font(.callout).textSelection(.enabled)
                Spacer()
                ForEach(Array(prompt.options.enumerated()), id: \.offset) { _, token in
                    Button(InputTape.Prompt.label(token)) { recorder.choose(token) }
                        .fontWeight(prompt.preferred == token ? .bold : .regular)
                }
            }
        }
    }

    private func submit() {
        guard canSave, let minute = ScheduleNumber.parse(minute, in: 0...59) else { return }
        do {
            try save(ScheduledJob(id: existing?.id ?? UUID(), name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                command: recording ? recorder.tape.summary : command,
                directory: recording ? recorder.directory : (directory as NSString).expandingTildeInPath,
                hour: ScheduleNumber.parse(hour, in: 0...23) ?? 0, minute: minute, hourly: hourly, recording: recording ? recorder.tape : nil,
                policy: recording || existing?.policy != nil ? policy : nil))
        } catch { self.error = error.localizedDescription }
    }
}

private struct EditorChoice: View {
    let title: String
    let symbol: String
    let selected: Bool
    let choose: () -> Void

    init(_ title: String, symbol: String, selected: Bool, choose: @escaping () -> Void) {
        self.title = title; self.symbol = symbol
        self.selected = selected; self.choose = choose
    }

    init(policy: ConfirmationPolicy, selected: Bool, choose: @escaping () -> Void) {
        self.init(policy.title, symbol: policy == .ask ? "bubble.left" : "checkmark.circle",
                  selected: selected, choose: choose)
    }

    var body: some View {
        Button(action: choose) {
            HStack(spacing: 7) {
                Image(systemName: symbol)
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                    .accessibilityHidden(true)
                Text(title).font(.system(size: 12, weight: .semibold))
            }.frame(maxWidth: .infinity, minHeight: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverButtonStyle(cornerRadius: SurfaceRadius.tile))
        .settingsSurface(selected: selected)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct ScheduleNumber: View {
    let title: String
    @Binding var value: String
    let range: ClosedRange<Int>
    @FocusState private var focused: Bool

    static func parse(_ text: String, in range: ClosedRange<Int>) -> Int? {
        guard (1...2).contains(text.count), text.utf8.allSatisfy({ (48...57).contains($0) }),
              let number = Int(text), range.contains(number) else { return nil }
        return number
    }

    var body: some View {
        HStack(spacing: 4) {
            Text(title).font(.callout)
            Spacer()
            if Self.parse(value, in: range) == nil {
                Text("\(range.lowerBound)–\(range.upperBound)").font(.caption2).foregroundStyle(.orange)
            }
            step(-1)
            TextField("00", text: $value)
                .font(.system(size: 15, weight: .medium, design: .monospaced))
                .textFieldStyle(.roundedBorder).multilineTextAlignment(.center)
                .frame(width: 38).focused($focused)
                .accessibilityLabel(title)
                .onChange(of: focused) { editing in
                    if !editing, let n = Self.parse(value, in: range) { value = String(format: "%02d", n) }
                }
            step(1)
        }.padding(.horizontal, 10).padding(.vertical, 5)
    }

    private func step(_ delta: Int) -> some View {
        let next = (Self.parse(value, in: range) ?? range.lowerBound) + delta
        let enabled = range.contains(next)
        return Button { value = String(format: "%02d", next) } label: {
            Image(systemName: delta > 0 ? "plus" : "minus")
                .font(.system(size: 10, weight: .semibold)).frame(width: 24, height: 24)
        }.buttonStyle(HoverButtonStyle()).disabled(!enabled).opacity(enabled ? 1 : 0.35)
            .accessibilityLabel((delta > 0 ? "Increase " : "Decrease ") + title.lowercased())
    }
}

private struct AutomationRun: View {
    let job: ScheduledJob
    let active: Bool
    let scheduler: JobScheduler
    let terminalHeight: CGFloat
    @State private var pending: JobScheduler.PendingQuestion?
    @State private var sent: String?
    @State private var responseError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Circle().fill(active ? Color.green : Color.secondary).frame(width: 6, height: 6)
                Text(active ? "Live terminal" : "Terminal output").font(.caption.weight(.medium))
                if active && job.policy != nil {
                    Text("· Click and type to send input").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text((job.directory as NSString).abbreviatingWithTildeInPath)
                    .font(TabTypography.path(size: NSFont.preferredFont(forTextStyle: .caption1).pointSize)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            AutomationConsole(outputURL: scheduler.logURL(job), offset: 0,
                              sizeURL: job.policy != nil ? scheduler.terminalSizeURL(job) : nil,
                              inputURL: job.policy != nil ? scheduler.terminalInputURL(job) : nil,
                              active: active)
                .frame(height: terminalHeight)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            if let pending {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "bubble.left.fill").font(.caption).foregroundStyle(.orange)
                        .frame(width: 24, height: 24).background(.orange.opacity(0.12), in: Circle()).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 8) {
                    Text(verbatim: InputTape.Prompt(pending.question)?.question ?? pending.question)
                        .font(.callout.weight(.semibold)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    HStack {
                        ForEach(pending.options, id: \.self) { option in
                            Button {
                                do { try scheduler.respond(option, to: pending, for: job); sent = pending.nonce; responseError = nil }
                                catch { responseError = error.localizedDescription }
                            } label: {
                                HStack(spacing: 4) {
                                    if option == "Yes" { Image(systemName: "checkmark") }
                                    if option == "No" { Image(systemName: "xmark") }
                                    Text(option)
                                }.padding(.horizontal, 3)
                            }.buttonStyle(.bordered).controlSize(.small)
                        }
                    }.disabled(sent == pending.nonce)
                    }
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                 .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }
            if let responseError { Text(responseError).foregroundStyle(.red) }
        }
        .task(id: active) {
            readQuestion()
            while active && !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 250_000_000) } catch { break }
                readQuestion()
            }
        }
    }
    private func readQuestion() {
        if active { scheduler.markViewing(job) }
        let next = active ? scheduler.pendingQuestion(job) : nil
        if next != pending { pending = next; sent = nil; responseError = nil }
    }
}

import UserNotifications

/// Where bananaShell shows its system alerts: Claude completions and automation questions.
/// Exactly one destination is used at a time, so an alert never appears in both places.
enum AlertDestination: String, CaseIterable, Identifiable {
    case notch, notificationCenter
    static let storageKey = "alertDestination"
    static var current: Self {
        UserDefaults.standard.string(forKey: storageKey).flatMap(Self.init(rawValue:)) ?? .notch
    }
    var id: String { rawValue }
    var title: String { self == .notch ? "Notch" : "Notification Center" }
}

enum AutomationNotificationRoute: Equatable {
    case open(UUID), answer(Int), terminal(UUID)

    static func resolve(action: String, jobLabel: String?, pane: String? = nil) -> Self? {
        if action == UNNotificationDefaultActionIdentifier {
            if let pane, let id = UUID(uuidString: pane) { return .terminal(id) }
            let prefix = "local.bananaShell.job."
            guard let jobLabel, jobLabel.hasPrefix(prefix),
                  let id = UUID(uuidString: String(jobLabel.dropFirst(prefix.count))) else { return nil }
            return .open(id)
        }
        if action.hasPrefix("option-"), let index = Int(action.dropFirst(7)), index >= 0 { return .answer(index) }
        return nil
    }
}

struct AutomationQuestion: Equatable {
    let id: String
    let jobLabel: String
    let nonce: String
    let name: String
    let question: String
    let options: [String]
}

/// Delivers automation questions and Claude completions to the destination chosen
/// in Settings: the notch (default) or Notification Center, never both.
final class AutomationNotifications: NSObject, UNUserNotificationCenterDelegate {
    @MainActor var openAutomation: ((UUID) -> Void)?
    @MainActor var openTerminal: ((UUID) -> Void)?
    @MainActor var presentQuestion: ((AutomationQuestion) -> Void)?
    @MainActor var retractQuestion: ((String) -> Void)?

    private let scheduler = JobScheduler()
    private let center = UNUserNotificationCenter.current()
    /// Questions currently presented, by job label and nonce, and where they were shown.
    private var shown: Set<String> = []
    private var shownIn: AlertDestination = .notch
    private var categories: [String: UNNotificationCategory] = [:]
    private var nextOutputUpgradeCheck: Date? = .distantPast

    func start() {
        center.delegate = self
        // Ask for badges up front: the dock count for finished Claude replies needs it.
        Task { _ = try? await center.requestAuthorization(options: [.alert, .badge]) }
        poll()
    }

    func poll() {
        if let nextOutputUpgradeCheck, nextOutputUpgradeCheck <= Date() {
            self.nextOutputUpgradeCheck = Date().addingTimeInterval(10)
            do {
                if try scheduler.upgradeOutput(for: scheduler.jobs()) { self.nextOutputUpgradeCheck = nil }
            } catch { NSLog("Automation upgrade: %@", error.localizedDescription) }
        }
        let folder = scheduler.home.appendingPathComponent("Library/Application Support/bananaShell/Recordings")
        let pending = (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.filter { $0.hasSuffix(".exp.pending") } ?? []
        var questions: [AutomationQuestion] = []
        if !pending.isEmpty {
            guard let jobs = try? scheduler.jobs() else { return }
            for job in jobs where pending.contains(job.label + ".exp.pending") {
                guard let q = scheduler.pendingQuestion(job) else { continue }
                questions.append(AutomationQuestion(id: job.label + "." + q.nonce, jobLabel: job.label, nonce: q.nonce, name: job.name,
                                                    question: InputTape.Prompt(q.question)?.question ?? q.question, options: q.options))
            }
        }
        let destination = AlertDestination.current
        if destination != shownIn {
            // The setting changed: withdraw everything from the old place and show it again in the new one.
            retract(shown, from: shownIn)
            shown = []
            shownIn = destination
        }
        let current = Set(questions.map(\.id))
        let stale = shown.subtracting(current)
        let fresh = questions.filter { !shown.contains($0.id) }
        shown = current
        guard !stale.isEmpty || !fresh.isEmpty else { return }
        retract(stale, from: destination)
        switch destination {
        case .notch:
            // Questions appear in the notch with their answer buttons; poll runs on the main thread.
            MainActor.assumeIsolated { for question in fresh { presentQuestion?(question) } }
        case .notificationCenter:
            post(fresh)
        }
    }

    private func retract(_ ids: Set<String>, from destination: AlertDestination) {
        guard !ids.isEmpty else { return }
        switch destination {
        case .notch:
            MainActor.assumeIsolated { for id in ids { retractQuestion?(id) } }
        case .notificationCenter:
            center.removeDeliveredNotifications(withIdentifiers: Array(ids))
            center.removePendingNotificationRequests(withIdentifiers: Array(ids))
            for id in ids { categories.removeValue(forKey: id) }
            center.setNotificationCategories(Set(categories.values))
        }
    }

    /// Posts questions to Notification Center with one action button per answer.
    private func post(_ questions: [AutomationQuestion]) {
        guard !questions.isEmpty else { return }
        var requests: [UNNotificationRequest] = []
        for q in questions {
            let actions = q.options.enumerated().map {
                UNNotificationAction(identifier: "option-" + String($0.offset), title: $0.element, options: [])
            }
            categories[q.id] = UNNotificationCategory(identifier: q.id, actions: actions, intentIdentifiers: [], options: [])
            let content = UNMutableNotificationContent()
            content.title = q.name
            content.subtitle = "Automation · Needs input"
            content.body = q.question
            content.categoryIdentifier = q.id
            content.userInfo = ["job": q.jobLabel, "nonce": q.nonce]
            requests.append(UNNotificationRequest(identifier: q.id, content: content, trigger: nil))
        }
        center.setNotificationCategories(Set(categories.values))
        Task {
            do {
                guard try await center.requestAuthorization(options: [.alert, .badge]) else { return }
                for request in requests { try await center.add(request) }
            } catch { NSLog("Automation notification: %@", error.localizedDescription) }
        }
    }

    /// A finished Claude response, shown in Notification Center instead of the notch.
    func postCompletion(title: String, summary: String?, source: ClaudeCompletion.Source, pane: UUID) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = source.announcement
        content.body = summary ?? "Check the terminal for the result"
        content.userInfo = ["pane": pane.uuidString]
        let request = UNNotificationRequest(identifier: "completion." + UUID().uuidString, content: content, trigger: nil)
        Task {
            do {
                guard try await center.requestAuthorization(options: [.alert, .badge]) else { return }
                try await center.add(request)
            } catch { NSLog("Completion notification: %@", error.localizedDescription) }
        }
    }

    /// Opens the automation that asked, from a notch card or a delivered notification.
    @MainActor func open(jobLabel: String) {
        if case .open(let id)? = AutomationNotificationRoute.resolve(action: UNNotificationDefaultActionIdentifier, jobLabel: jobLabel) {
            openAutomation?(id)
        }
    }

    /// Answers only the exact question that was shown, so a late click can't answer a newer one.
    func respond(jobLabel: String?, nonce: String?, index: Int) {
        guard let jobs = try? scheduler.jobs(), let job = jobs.first(where: { $0.label == jobLabel }),
              let question = scheduler.pendingQuestion(job), question.nonce == nonce,
              question.options.indices.contains(index) else { return }
        do { try scheduler.respond(question.options[index], to: question, for: job) }
        catch { NSLog("Automation response: %@", error.localizedDescription) }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completion: @escaping (UNNotificationPresentationOptions) -> Void) {
        completion([.banner, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completion: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let label = info["job"] as? String
        let nonce = info["nonce"] as? String
        let route = AutomationNotificationRoute.resolve(action: response.actionIdentifier, jobLabel: label,
                                                        pane: info["pane"] as? String)
        Task { @MainActor in
            defer { completion() }
            switch route {
            case .open(let id):
                // A body click opens the job even after its question has been answered.
                openAutomation?(id)
            case .terminal(let id):
                openTerminal?(id)
            case .answer(let index):
                respond(jobLabel: label, nonce: nonce, index: index)
            case nil: break
            }
        }
    }
}

private struct AutomationHeaderActions: View {
    let running: Bool
    let name: String
    let toggle: () -> Void
    let edit: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: toggle) {
                HStack(spacing: 6) {
                    Image(systemName: running ? "stop.fill" : "play.fill")
                        .font(.system(size: 10, weight: .semibold))
                    Text(running ? "Stop" : "Run now").font(.callout.weight(.semibold))
                }
                .foregroundStyle(running ? Color.primary : Color.accentColor)
                .frame(width: 88, height: 30)
                .background((running ? Color.primary : Color.accentColor).opacity(0.12),
                            in: RoundedRectangle(cornerRadius: SurfaceRadius.tab))
            }.buttonStyle(HoverButtonStyle(cornerRadius: SurfaceRadius.tab))
                .accessibilityLabel((running ? "Stop " : "Run ") + name)
            Menu {
                Button("Edit Automation…", action: edit)
                Divider()
                Button("Delete Automation…", role: .destructive, action: remove)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 30, height: 30)
                    .background(Color.primary.opacity(0.065), in: RoundedRectangle(cornerRadius: SurfaceRadius.tab))
            }.menuStyle(.button).menuIndicator(.hidden)
                .buttonStyle(HoverButtonStyle(cornerRadius: SurfaceRadius.tab))
                .help("Automation actions").accessibilityLabel("Automation actions")
        }.fixedSize()
    }
}
