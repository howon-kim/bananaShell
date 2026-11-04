import Combine
import SwiftUI
import Foundation

enum ConfirmationPolicy: String, CaseIterable {
    case ask, auto
    var title: String { self == .ask ? "Ask me" : "Automatically allow (y)" }
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
                  let args = p["ProgramArguments"] as? [String],
                  (args.count == 3 || (args.count == 2 && args.first == "/usr/bin/expect")),
                  let directory = p["WorkingDirectory"] as? String,
                  let time = p["StartCalendarInterval"] as? [String: Int], let minute = time["Minute"] else { return nil }
            var job = ScheduledJob(id: id, name: name, command: args.count == 3 ? args[2] : (p["bananaShellCommand"] as? String ?? "Terminal recording"), directory: directory, hour: time["Hour"] ?? 0, minute: minute, hourly: time["Hour"] == nil)
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

    func outputEnd(_ job: ScheduledJob) throws -> UInt64 {
        do {
            let handle = try FileHandle(forReadingFrom: logURL(job))
            defer { try? handle.close() }
            return try handle.seekToEnd()
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) { return 0 }
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
            "ProgramArguments": arguments, "WorkingDirectory": job.directory,
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
    func runNow(_ job: ScheduledJob) throws {
        try control(["kickstart", domain + "/" + job.label])
    }
    func stopCurrentRun(_ job: ScheduledJob) throws {
        try control(["kill", "SIGTERM", domain + "/" + job.label])
    }

    // One read covers both manually and periodically started agents.
    static func runningLabels() throws -> Set<String> {
        let task = Process(), pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = ["list"]
        task.standardOutput = pipe
        try task.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { throw launchError("Could not read automation status.") }
        return Set(String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(maxSplits: 2, whereSeparator: \.isWhitespace)
            guard fields.count == 3, let pid = Int32(fields[0]), pid > 0,
                  fields[2].hasPrefix("local.bananaShell.job.") else { return nil }
            return String(fields[2])
        })
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
    let addRequest: PassthroughSubject<Void, Never>
    private let scheduler: JobScheduler
    private let runningLabels: () throws -> Set<String>
    init(addRequest: PassthroughSubject<Void, Never>, scheduler: JobScheduler = .init(),
         runningLabels: @escaping () throws -> Set<String> = JobScheduler.runningLabels) {
        self.addRequest = addRequest
        self.scheduler = scheduler
        self.runningLabels = runningLabels
    }
    @State private var jobs: [ScheduledJob] = []
    @State private var running: Set<String> = []
    @State private var waiting: Set<String> = []
    @State private var observedEnds: [String: UInt64] = [:]
    @State private var logStarts: [String: UInt64] = [:]
    @State private var query = ""
    @State private var selection: UUID?
    @State private var showingDetail = false
    @State private var copied: String?
    @State private var adding = false
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
                }
                if let error { Text(error).font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
                if jobs.isEmpty {
                    emptyState("No automations yet", message: "Use + in the tab bar to record and schedule commands.", icon: "clock.arrow.circlepath")
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
                            }
                        }
                    }
                }
            }.padding(20)
        }.onAppear { reload() }
        .task {
            let readLabels = runningLabels
            while !Task.isCancelled {
                do {
                    let labels = try await Task.detached(priority: .utility) { try readLabels() }.value
                    guard !Task.isCancelled else { break }
                    for job in jobs {
                        let key = job.label
                        let end = try scheduler.outputEnd(job)
                        let previous = observedEnds[key]
                        let started = labels.contains(key) && !running.contains(key)
                        // A scheduled job can finish entirely between status polls.
                        let completedBetweenPolls = !labels.contains(key) && !running.contains(key)
                            && previous.map { end > $0 } == true
                        if started || completedBetweenPolls {
                            logStarts[key] = previous ?? 0
                            selection = job.id
                            showingDetail = true
                        }
                        observedEnds[key] = end
                    }
                    if labels != running { running = labels }
                    let requests = Set(jobs.filter { labels.contains($0.label) && scheduler.pendingQuestion($0) != nil }.map(\.label))
                    if requests != waiting { waiting = requests }
                } catch { self.error = error.localizedDescription }
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { break }
            }
        }
        .onReceive(addRequest) { adding = true }
        .sheet(isPresented: $adding) { JobEditor { job in
            try scheduler.add(job)
            selection = job.id
            query = ""
            showingDetail = true
            adding = false
            reload()
        } }
        .alert("Delete this automation?", isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } }), presenting: removal) { job in
            Button("Delete", role: .destructive) {
                do { try scheduler.remove(job); reload() } catch { self.error = error.localizedDescription }
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text($0.name + " will no longer run on schedule.") }
    }

    private func sidebarRow(_ job: ScheduledJob) -> some View {
        HStack(spacing: 6) {
            Button { selection = job.id; showingDetail = true } label: {
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
                }.contentShape(Rectangle())
            }.help(job.name + " · " + job.command)
             .accessibilityAddTraits(current?.id == job.id ? .isSelected : [])
            Button { toggleRun(job) } label: {
                Image(systemName: running.contains(job.label) ? "stop.fill" : "play.fill").frame(width: 18, height: 24)
            }.help(running.contains(job.label) ? "Stop current run" : "Run now")
             .accessibilityLabel((running.contains(job.label) ? "Stop " : "Run ") + job.name)
        }.buttonStyle(.plain).padding(8)
         .background(current?.id == job.id ? Color.accentColor.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 8))
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
            .background(ink.opacity(0.12), in: RoundedRectangle(cornerRadius: 9)).accessibilityHidden(true)
    }

    @ViewBuilder private func detail(_ job: ScheduledJob, terminalHeight: CGFloat) -> some View {
        let active = running.contains(job.label)
        let offset = logStarts[job.label] ?? 0
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
            Button { toggleRun(job) } label: {
                Label(active ? "Stop" : "Run now", systemImage: active ? "stop.fill" : "play.fill")
            }.buttonStyle(.borderedProminent)
             .accessibilityLabel((active ? "Stop " : "Run ") + job.name)
            Menu {
                Button("Delete Automation…", role: .destructive) { removal = job }
            } label: { Image(systemName: "ellipsis").frame(width: 20, height: 24) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Automation actions").accessibilityLabel("Automation actions")
        }
        Divider()
        if active || (observedEnds[job.label] ?? 0) > offset {
            AutomationRun(job: job, offset: offset, active: active, scheduler: scheduler, terminalHeight: terminalHeight)
                .id("\(job.id):\(offset)")
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
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(value, forType: .string)
                    copied = value
                } label: {
                    Image(systemName: copied == value ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 12)).foregroundStyle(copied == value ? SettingsStyle.accent : .secondary)
                        .frame(width: 24, height: 22).contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .help("Copy " + title).accessibilityLabel("Copy " + title)
            }.padding(16).settingsSurface()
        }.task(id: copied) {
            guard copied == value else { return }
            do { try await Task.sleep(nanoseconds: 1_500_000_000); copied = nil } catch {}
        }
    }

    private func confirmationOption(_ policy: ConfirmationPolicy, selected: Bool, job: ScheduledJob) -> some View {
        Button {
            do { try scheduler.setPolicy(policy, for: job); reload() }
            catch { self.error = error.localizedDescription }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: policy == .ask ? "bubble.left" : "checkmark.circle")
                    Spacer(minLength: 0)
                    if selected { Image(systemName: "checkmark.circle.fill") }
                }.font(.system(size: 13)).foregroundStyle(selected ? SettingsStyle.accent : .secondary)
                 .accessibilityHidden(true)
                Text(policy.title).font(.system(size: 12, weight: .semibold)).lineLimit(2)
                Text(policy == .ask ? "Wait for my response" : "Send y and Enter")
                    .font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
             .contentShape(RoundedRectangle(cornerRadius: 9))
        }.buttonStyle(.plain).settingsSurface(selected: selected)
         .accessibilityLabel(policy.title)
         .accessibilityAddTraits(selected ? .isSelected : [])
         .accessibilityRemoveTraits(selected ? [] : .isSelected)
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
                let offset = try scheduler.outputEnd(job)
                try scheduler.runNow(job)
                logStarts[job.label] = offset
                observedEnds[job.label] = offset
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
    @State private var hour = 9
    @State private var minute = 0
    @State private var error: String?
    let save: (ScheduledJob) throws -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Automation").font(.title2.bold())
            if !recorder.finished {
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
            } else {
                Text("Recording complete · Commands: \(recorder.tape.commands.count)").foregroundStyle(.secondary)
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
            }
            if let message = recorder.error { Text(message).foregroundStyle(.red) }
            if recorder.finished {
            LabeledContent("Name") { TextField("Automation name", text: $name) }

            HStack {
                Picker("Schedule", selection: $hourly) { Text("Daily").tag(false); Text("Hourly").tag(true) }.fixedSize()
                if !hourly { Stepper("Hour: \(hour)", value: $hour, in: 0...23).fixedSize() }
                Stepper("Minute: \(minute)", value: $minute, in: 0...59).fixedSize()
            }
            Picker("Confirmation prompts", selection: $policy) {
                ForEach(ConfirmationPolicy.allCases, id: \.self) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented)
            Text("Uses your Mac’s local time. Jobs run in zsh while you’re logged in, even when the app is closed.").font(.caption).foregroundStyle(.secondary)
            }
            if let error { Text(error).foregroundStyle(.red) }
            HStack { Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                if recorder.finished { Button("Save and Schedule") {
                    do { try save(ScheduledJob(id: UUID(), name: name.trimmingCharacters(in: .whitespacesAndNewlines), command: "Terminal recording",
                        directory: recorder.directory, hour: hour, minute: minute, hourly: hourly, recording: recorder.tape, policy: policy)) }
                    catch { self.error = error.localizedDescription }
                }.keyboardShortcut(.defaultAction).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || recorder.count == 0 || recorder.error != nil) }
            }
        }.padding(20).frame(width: 640)
        .onChange(of: recorder.finished) { finished in
            if finished && name.isEmpty { name = recorder.tape.suggestedName }
        }
        .onDisappear { recorder.stop() }
    }
}

private struct AutomationRun: View {
    let job: ScheduledJob
    let offset: UInt64
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
                Spacer()
                Text((job.directory as NSString).abbreviatingWithTildeInPath)
                    .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            AutomationConsole(outputURL: scheduler.logURL(job), offset: offset,
                              sizeURL: job.policy != nil ? scheduler.terminalSizeURL(job) : nil,
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

final class AutomationNotifications: NSObject, UNUserNotificationCenterDelegate {
    private let scheduler = JobScheduler()
    private var live: [String: UNNotificationCategory] = [:]
    private let center = UNUserNotificationCenter.current()
    private var posting = false

    func start() {
        center.delegate = self
        _ = try? scheduler.jobs() // Upgrade existing recorded jobs before their next launch.
        poll()
    }

    func poll() {
        guard !posting else { return }
        let folder = scheduler.home.appendingPathComponent("Library/Application Support/bananaShell/Recordings")
        let pending = (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.filter { $0.hasSuffix(".exp.pending") } ?? []
        var requests: [UNNotificationRequest] = []
        var current: Set<String> = []
        if !pending.isEmpty {
            guard let jobs = try? scheduler.jobs() else { return }
            for job in jobs where pending.contains(job.label + ".exp.pending") {
                guard let q = scheduler.pendingQuestion(job) else { continue }
                let id = job.label + "." + q.nonce
                current.insert(id)
                guard live[id] == nil else { continue }
                let actions = q.options.enumerated().map {
                    UNNotificationAction(identifier: "option-" + String($0.offset), title: $0.element, options: [])
                }
                live[id] = UNNotificationCategory(identifier: id, actions: actions, intentIdentifiers: [], options: [])
                let content = UNMutableNotificationContent()
                content.title = job.name
                content.body = InputTape.Prompt(q.question)?.question ?? q.question
                content.categoryIdentifier = id
                content.userInfo = ["job": job.label, "nonce": q.nonce]
                requests.append(UNNotificationRequest(identifier: id, content: content, trigger: nil))
            }
        }
        let stale = Set(live.keys).subtracting(current)
        guard !requests.isEmpty || !stale.isEmpty else { return }
        for id in stale { live.removeValue(forKey: id) }
        center.setNotificationCategories(Set(live.values))
        guard !requests.isEmpty else { return }
        posting = true
        Task { @MainActor in
            defer { posting = false }
            do {
                guard try await center.requestAuthorization(options: [.alert]) else { return }
                for request in requests {
                    let info = request.content.userInfo
                    guard let job = try scheduler.jobs().first(where: { $0.label == info["job"] as? String }),
                          let q = scheduler.pendingQuestion(job), q.nonce == info["nonce"] as? String else { continue }
                    try await center.add(request)
                }
            } catch { NSLog("Automation notification: %@", error.localizedDescription) }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completion: @escaping (UNNotificationPresentationOptions) -> Void) {
        completion([.banner, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completion: @escaping () -> Void) {
        defer { completion() }
        let info = response.notification.request.content.userInfo
        let action = response.actionIdentifier
        guard action.hasPrefix("option-"), let index = Int(action.dropFirst(7)),
              let jobs = try? scheduler.jobs(), let job = jobs.first(where: { $0.label == info["job"] as? String }),
              let question = scheduler.pendingQuestion(job), question.nonce == info["nonce"] as? String,
              question.options.indices.contains(index) else { return }
        do { try scheduler.respond(question.options[index], to: question, for: job) }
        catch { NSLog("Automation response: %@", error.localizedDescription) }
    }
}
