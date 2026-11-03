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
                if args == ["/usr/bin/expect", replay.path],
                   let old = try? String(contentsOf: replay, encoding: .utf8),
                   let updated = InputTape.updatedDialog(in: old) {
                    try Data(updated.utf8).write(to: replay, options: .atomic)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: replay.path)
                }
                job.policy = (try? String(contentsOf: policyURL(job), encoding: .utf8)).flatMap(ConfirmationPolicy.init(rawValue:)) ?? .ask
            }
            return job
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    private var logFolder: URL { home.appendingPathComponent("Library/Logs/bananaShell") }
    private func logURL(_ job: ScheduledJob) -> URL { logFolder.appendingPathComponent(job.label + ".log") }

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
        try FileManager.default.removeItem(at: file(job))
    }
}

private struct CardRows: Layout {
    private func positions(_ views: Subviews, width: CGFloat) -> ([CGRect], CGFloat) {
        var rects: [CGRect] = [], x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in views {
            let w = min(width, view.sizeThatFits(.unspecified).width)
            let h = view.sizeThatFits(ProposedViewSize(width: w, height: nil)).height
            if x > 0 && x + w > width { x = 0; y += rowHeight + 8; rowHeight = 0 }
            rects.append(CGRect(x: x, y: y, width: w, height: h))
            x += w + 8; rowHeight = max(rowHeight, h)
        }
        return (rects, y + rowHeight)
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = proposal.width ?? 400
        return CGSize(width: w, height: positions(subviews, width: w).1)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (view, rect) in zip(subviews, positions(subviews, width: bounds.width).0) {
            view.place(at: CGPoint(x: bounds.minX + rect.minX, y: bounds.minY + rect.minY),
                       anchor: .topLeading, proposal: ProposedViewSize(rect.size))
        }
    }
}

struct AutomationPanel: View {
    let addRequest: PassthroughSubject<Void, Never>
    private let scheduler = JobScheduler()
    @State private var jobs: [ScheduledJob] = []
    @State private var running: Set<String> = []
    @State private var observedEnds: [String: UInt64] = [:]
    @State private var logStarts: [String: UInt64] = [:]
    @State private var expanded: UUID?
    @State private var adding = false
    @State private var removal: ScheduledJob?
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Automations", systemImage: "clock.arrow.circlepath").font(.title2.bold())
                Spacer()

            }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if jobs.isEmpty && error == nil {
                Text("No automations yet. Use + in the tab bar to add one.").foregroundStyle(.secondary)
            }
            ScrollView {
                CardRows {
                    ForEach(jobs) { job in card(job) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding(18).onAppear { reload() }
        .task {
            while !Task.isCancelled {
                do {
                    let labels = try await Task.detached(priority: .utility) { try JobScheduler.runningLabels() }.value
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
                            logStarts[key] = previous ?? end
                            expanded = job.id
                        }
                        observedEnds[key] = end
                    }
                    if labels != running { running = labels }
                } catch { self.error = error.localizedDescription }
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { break }
            }
        }
        .onReceive(addRequest) { adding = true }
        .sheet(isPresented: $adding) { JobEditor { job in
            try scheduler.add(job)
            expanded = job.id
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
    private func card(_ job: ScheduledJob) -> some View {
        let word = InputTape.commandWords(job.command).first?.drop(while: {
            $0.range(of: #"^[A-Za-z_][A-Za-z_0-9]*="#, options: .regularExpression) != nil
        }).first
        let name = word.map { ($0 as NSString).lastPathComponent } ?? job.name
        let active = running.contains(job.label)
        let open = active || expanded == job.id
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Button { expanded = expanded == job.id ? nil : job.id } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(verbatim: name).font(.system(.body, design: .monospaced).weight(.semibold)).lineLimit(1)
                            if active { Label("Running", systemImage: "waveform").font(.caption).foregroundStyle(.green) }
                        }
                        Text(job.schedule).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain).help(job.name + " · " + job.command)
                Button {
                    do {
                        if active { try scheduler.stopCurrentRun(job) }
                        else {
                            let offset = try scheduler.outputEnd(job)
                            try scheduler.runNow(job)
                            logStarts[job.label] = offset
                            observedEnds[job.label] = try scheduler.outputEnd(job)
                            expanded = job.id
                        }
                        running = try JobScheduler.runningLabels()
                        error = nil
                    } catch { self.error = error.localizedDescription }
                } label: { Image(systemName: active ? "stop.fill" : "play.fill").frame(width: 24, height: 24) }
                .buttonStyle(.borderless).help(active ? "Stop current run" : "Run now")
                .accessibilityLabel((active ? "Stop " : "Run ") + job.name)
            }.padding(.horizontal, 10).frame(height: 50)
            if open, let offset = logStarts[job.label] { AutomationLog(job: job, offset: offset, active: active).id("\(job.id):\(offset)").padding([.horizontal, .bottom], 10) }
        }
        .frame(minWidth: 0, idealWidth: open ? 420 : 200, maxWidth: open ? 420 : 200, alignment: .leading)
        .background(open ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 8))
        .contextMenu {
            Text(job.command)
            Text((job.directory as NSString).abbreviatingWithTildeInPath)
            Divider()
            if let current = job.policy {
                Picker("Confirmation", selection: Binding(get: { current }, set: { value in
                    do { try scheduler.setPolicy(value, for: job); reload() }
                    catch { self.error = error.localizedDescription }
                })) {
                    ForEach(ConfirmationPolicy.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            }
            Button("Delete Automation…", role: .destructive) { removal = job }
        }
    }

    private func reload() {
        do { jobs = try scheduler.jobs(); error = nil } catch { self.error = error.localizedDescription }
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

private struct AutomationLog: View {
    let job: ScheduledJob
    let offset: UInt64
    let active: Bool
    private let scheduler = JobScheduler()
    @State private var pending: JobScheduler.PendingQuestion?
    @State private var sent: String?
    @State private var responseError: String?
    @State private var showLog = false
    @State private var output = ""
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
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
            if let failure {
                Text(failure).foregroundStyle(.red).textSelection(.enabled)
            } else if output.isEmpty {
                Text("No output recorded yet.").foregroundStyle(.secondary)
            } else {
                DisclosureGroup("Run log", isExpanded: $showLog) {
                    ScrollView([.vertical, .horizontal]) {
                    Text(verbatim: output).font(.body.monospaced()).textSelection(.enabled).padding(10)
                }.frame(maxWidth: .infinity, alignment: .topLeading).frame(height: 144)
                 .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                }.font(.caption)
                if !showLog && pending == nil, let last = output.split(whereSeparator: \.isNewline).last {
                    Text(verbatim: String(last)).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
        .task(id: active) {
            readOutput()
            while active && !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { break }
                readOutput()
            }
        }
    }
    private func readOutput() {
        if active { scheduler.markViewing(job) }
        let next = active ? scheduler.pendingQuestion(job) : nil
        if next != pending { pending = next; sent = nil; responseError = nil }
        do { let latest = try scheduler.recentOutput(job, since: offset); if output != latest { output = latest }; failure = nil }
        catch { output = ""; failure = error.localizedDescription }
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
