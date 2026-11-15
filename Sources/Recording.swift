import SwiftUI
import SwiftTerm
import Foundation

private extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
    init?(hexText: Substring) {
        guard hexText.count.isMultiple(of: 2) else { return nil }
        var bytes = Data(), i = hexText.startIndex
        while i < hexText.endIndex {
            let j = hexText.index(i, offsetBy: 2)
            guard let byte = UInt8(hexText[i..<j], radix: 16) else { return nil }
            bytes.append(byte); i = j
        }
        self = bytes
    }
}

struct ResponseStep {
    var before: Data
    var keys: Data
    var after = Data()
}
struct RecordedCommand {
    var text: String
    var replies: [ResponseStep] = []
}
struct InputTape {
    var commands: [RecordedCommand] = []
    var summary: String { commands.first(where: { $0.text != "exit" })?.text ?? "Shell session" }

    var suggestedName: String {
        var actions: [String] = [], context: String?
        for command in commands {
            for words in Self.commandWords(command.text) {
                let parts = Array(words.drop(while: { $0.contains("=") || ["env", "command", "sudo"].contains($0) }))
                guard let first = parts.first else { continue }
                let tool = (first as NSString).lastPathComponent
                let arg = parts.dropFirst().first ?? ""
                let target = (arg as NSString).lastPathComponent
                let label: String
                switch tool {
                case "exit", "logout", "export", "source", ".", "pwd", "clear": continue
                case "cd": context = target; continue
                case "conda" where arg == "activate":
                    context = parts.dropFirst(2).first.map { ($0 as NSString).lastPathComponent + " environment" } ?? "Conda environment"
                    continue
                case "claude": label = "Run Claude"
                case "git":
                    label = ["pull": "Pull Git changes", "push": "Push Git changes", "status": "Check Git status", "fetch": "Fetch Git changes"][arg] ?? "Git task"
                case "pytest": label = "Run Python tests"
                case "npm", "pnpm", "yarn", "swift", "cargo", "make":
                    let task = arg == "run" ? parts.dropFirst(2).first ?? "" : arg
                    label = ["test": "Run tests", "build": "Build project", "dev": "Start development server"][task] ?? "Run \(tool)"
                case "python", "python3", "ruby", "node", "bash", "zsh", "sh":
                    label = target.isEmpty || arg.hasPrefix("-") ? "Run \(tool)" : "Run \(target)"
                default: label = "Run \(tool)"
                }
                if actions.last != label { actions.append(label) }
            }
        }
        let action = actions.prefix(2).joined(separator: ", then ")
        let title = [context, action.isEmpty && context != nil ? "Set up" : action].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        return title.isEmpty ? "Shell automation" : String(title.prefix(60))
    }

    // Tokenize for display only; never expand variables or execute a command.
    static func commandWords(_ text: String) -> [[String]] {
        var result: [[String]] = [], words: [String] = [], word = ""
        var quote: Character?, escaped = false
        func endWord() { if !word.isEmpty { words.append(word); word = "" } }
        func endCommand() { endWord(); if !words.isEmpty { result.append(words); words = [] } }
        for ch in text {
            if escaped { word.append(ch); escaped = false }
            else if ch == "\\" && quote != "'" { escaped = true }
            else if let q = quote { if ch == q { quote = nil } else { word.append(ch) } }
            else if ch == "'" || ch == "\"" { quote = ch }
            else if ";&|\n".contains(ch) { endCommand() }
            else if ch.isWhitespace { endWord() }
            else { word.append(ch) }
        }
        endCommand()
        return result
    }

    static func hook(_ token: String, capture: Bool) -> String {
        // The OSC frames distinguish shell editing from input to a running command.
        let argument = capture ? #" "$(printf '%s' "$1" | /usr/bin/od -An -v -tx1 | /usr/bin/tr -d ' \n')""# : " ''"
        return " unset HISTFILE; PROMPT_EOL_MARK=''; function _bs_pre { printf '\\033]777;\(token):C%s\\007'" + argument +
            "; }; function _bs_ready { printf '\\033]777;\(token):R\\007'; }; preexec_functions=(_bs_pre ${preexec_functions[@]}); precmd_functions+=(_bs_ready)"
    }
    // Match the final prompt, whether the tool waits on the same or the next line.
    static let choice = #"(?:\[[A-Za-z]{1,12}(?:/[A-Za-z]{1,12}){1,2}\]|\([A-Za-z]{1,12}(?:/[A-Za-z]{1,12}){1,2}\)|\m[yY]/[nN]\M)[ \t?:]*$"#
    struct Prompt: Equatable {
        let question: String
        let options: [String]
        var preferred: String? { options.first { $0 != $0.lowercased() } }
        static func label(_ token: String) -> String {
            switch token.lowercased() { case "y", "yes": return "Yes"; case "n", "no": return "No"; default: return token.capitalized }
        }
        init?(_ text: String) {
            let line = text.replacingOccurrences(of: #"\x1B\[[0-9;:]*m"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: .newlines).last ?? ""
            let pattern = InputTape.choice.replacingOccurrences(of: #"\m"#, with: #"\b"#).replacingOccurrences(of: #"\M"#, with: #"\b"#)
            guard let range = line.range(of: pattern, options: .regularExpression) else { return nil }
            let title = line[..<range.lowerBound].replacingOccurrences(of: #"^==>\s*"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
            question = title.isEmpty ? "Choose an option" : title
            options = line[range].split(whereSeparator: { !$0.isLetter }).map(String.init)
        }
    }
    private static func isChoice(_ data: Data) -> Bool { Prompt(String(decoding: data, as: UTF8.self)) != nil }
    private static let confirmationRuntime = #"""
    proc answer {raw} {
        global jobName
        set policy ask
        set path "[info script].policy"
        if {[file exists $path]} {
            set f [open $path r]; set policy [string trim [read $f]]; close $f
        }
        set question [encoding convertfrom utf-8 $raw]
        regsub -all {\x1b\[[0-9;:]*m} $question {} question
        set question [string trimright $question]
        if {![regexp {([A-Za-z]+(?:/[A-Za-z]+){1,2})[\]) \t?:]*$} $question -> choices]} {exit 65}
        set tokens [split $choices /]
        set labels {}; set replies {}; set preferred 0; set positive -1; set negative -1
        foreach token $tokens {
            set value [string tolower $token]
            set idx [llength $labels]
            if {$token ne $value} {set preferred [expr {$idx + 1}]}
            switch -- $value {
                y - yes {set title Yes; set positive $idx}
                n - no {set title No; set negative $idx}
                default {set title [string totitle $value]}
            }
            lappend labels $title; lappend replies $value
        }
        set binary [expr {[llength $tokens] == 2 && $positive >= 0 && $negative >= 0}]
        if {$policy eq "auto" && $binary} {
            set idx $positive
        } else {
            set idx -1
            # Each answer belongs to one live process and one question.
            set base [info script]
            set nonce "[pid]-[clock clicks]"
            set pending "$base.pending"
            set reply "$base.$nonce.reply"
            set f [open "$pending.tmp" w 0600]
            fconfigure $f -encoding utf-8
            puts $f $nonce; puts $f 0; puts $f [join $labels /]; puts -nonewline $f $question
            close $f; file rename -force "$pending.tmp" $pending
            catch {exec /usr/bin/open -g -b local.bananaShell --args --automation-notification}
            while {$idx < 0} {
                if {[llength [info commands updateTerminalSize]]} {updateTerminalSize}
                if {[file exists $reply]} {
                    set f [open $reply r]; set decision [string trim [read $f]]; close $f
                    set idx [lsearch -exact $labels $decision]
                    if {$idx >= 0} {break}
                }
                after 100
            }
            file delete -force $pending $reply

        }
        send -- "[lindex $replies $idx]\r"
        puts stderr "\r\nbananaShell: selected [lindex $labels $idx]\r"
        if {$binary && $idx == $negative} {
            expect {
                -exact $::ready {puts stderr "\nbananaShell: command finished; replay stopped after No."}
                eof {puts stderr "\nbananaShell: terminal closed; replay stopped after No."}
                timeout {puts stderr "\nbananaShell: command did not finish within the timeout after No; stopping replay."; exit 124}
            }
            exit 77
        }
    }
    proc confirmNext {label} {
        global confirmationRE ready
        expect -timeout -1 -exact $ready {puts stderr "$label: missing confirmation"; exit 65} -re $confirmationRE {answer $expect_out(0,string)} eof {exit 65}
    }
    proc need {anchor label {interactive 0}} {
        global ready confirmationRE
        binary scan $anchor c* octets; set pattern ""
        foreach b $octets {append pattern [format {\u%04x} [expr {$b & 255}]]}
        if {$interactive} {
            expect -timeout -1 -re $pattern {return} -exact $ready {puts stderr "$label: unexpected shell prompt"; exit 65} -re $confirmationRE {answer $expect_out(0,string); exp_continue} eof {exit 65}
        } else {
            expect -re $pattern {return} -exact $ready {puts stderr "$label: unexpected shell prompt"; exit 65} timeout {exit 124} eof {exit 65}
        }
    }
    """#

    private static let promptPatternLine = #"set confirmationRE {(?:[^\r\n\x1b]|\x1b\[[0-9;:]*m)*"# + String(choice.dropLast()) + #"(?:\x1b\[[0-9;:]*m[ \t]*)*(?:\r\n|\n|\r)?[ \t]*$}"#

    // Refresh the generated input-wait runtime in existing recordings as well.
    // Replace only that preamble, leaving commands, anchors and policy intact.
    static func updatedDialog(in script: String) -> String? {
        guard script.contains("proc answer {raw}"), script.contains("proc confirmNext {label}"),
              let start = script.range(of: "\nset confirmationRE {"),
              let end = script.range(of: "\nsend -- [binary format H* {", range: start.upperBound..<script.endIndex)
        else { return nil }
        let replacement = "\n" + promptPatternLine + "\n" + confirmationRuntime
        var result = String(script[..<start.lowerBound]) + replacement + String(script[end.lowerBound...])
        result = result.replacingOccurrences(of: legacyCompletionWait, with: completionWait)
        return result == script ? nil : result
    }

    private static let legacyCompletionWait = "expect eof {} -re $confirmationRE {answer $expect_out(0,string); exp_continue} timeout {puts stderr {shell exit timeout}; exit 124}"
    private static let completionWait = "expect -timeout -1 eof {} -re $confirmationRE {answer $expect_out(0,string); exp_continue}"

    private static let terminalPreamble = #"""
    # bananaShell live terminal v1
    fconfigure stdout -translation binary -buffering none
    set stty_init {rows 24 columns 100}
    log_user 0
    """#
    private static let terminalRuntime = #"""
    proc updateTerminalSize {} {
        global terminalSize spawn_out
        set path "[info script].size"
        if {[catch {
            set f [open $path r]
            set value [read $f 32]; close $f
            if {[regexp {^([0-9]{1,3}) ([0-9]{1,3})$} $value -> cols rows] &&
                $cols >= 20 && $cols <= 500 && $rows >= 5 && $rows <= 200 && $value ne $terminalSize} {
                stty rows $rows columns $cols < $spawn_out(slave,name)
                set terminalSize $value
            }
        }]} {return}
    }
    proc watchTerminalSize {} {
        updateTerminalSize
        after 200 watchTerminalSize
    }
    set terminalSize {}
    watchTerminalSize
    """# + "\n" + inputRuntime

    // Keys typed into the live terminal (e.g. a password) arrive as owner-only
    // files next to the replay. They go straight to the PTY: never recorded,
    // and `send` is not written to the output log.
    private static let inputRuntimeMarker = "proc forwardInput {} {"
    private static let inputRuntime = #"""
    proc inputFiles {} {
        set base [info script]
        lsort -dictionary [glob -nocomplain -directory [file dirname $base] -tails "[file tail $base].input.*"]
    }
    proc forwardInput {} {
        global spawn_id
        set dir [file dirname [info script]]
        foreach name [inputFiles] {
            set path [file join $dir $name]
            if {[catch {
                set f [open $path r]; fconfigure $f -translation binary; set data [read $f]; close $f
            }]} {continue}
            file delete -force $path
            if {$data ne ""} {catch {send -- $data}}
        }
        after 50 forwardInput
    }
    foreach name [inputFiles] {file delete -force [file join [file dirname [info script]] $name]}
    forwardInput
    """#

    // Upgrade only our generated replays. Commands, anchors, replies and the
    // confirmation policy stay intact. Expect's legacy user logger re-encodes
    // binary spawn data as UTF-8. Its log channel honors stdout's binary
    // encoding, preserving the original PTY bytes (including split UTF-8).
    static func updatedTerminalOutput(in script: String) -> String? {
        let watch = "set terminalSize {}\nwatchTerminalSize\n"
        if script.hasPrefix(terminalPreamble), script.contains(watch) {
            // Live terminal v1 replays gain keyboard input forwarding.
            guard !script.contains(inputRuntimeMarker) else { return nil }
            return script.replacingOccurrences(of: watch, with: watch + inputRuntime + "\n")
        }
        let channel = "fconfigure $spawn_id -encoding binary -translation binary\n"
        let firstReady = "need $ready command-1 0\n"
        guard script.hasPrefix("set env(TERM) xterm-256color\n"),
              script.contains(channel), let ready = script.range(of: firstReady) else { return nil }
        var result = script
        result.insert(contentsOf: "log_file -a -leaveopen stdout\n", at: ready.upperBound)
        result = result.replacingOccurrences(of: channel, with: channel + terminalRuntime + "\n")
        return terminalPreamble + "\n" + result
    }
    func script(jobName: String = "bananaShell") -> String {
        let token = UUID().uuidString
        let prefix = "\u{1b}]777;" + token + ":"
        func bin(_ s: String) -> String { "[binary format H* {\(Data(s.utf8).hex)}]" }
        var rows = ["set env(TERM) xterm-256color", "set timeout 120", "spawn -noecho /bin/zsh -ilo histignorespace",
                    "fconfigure $spawn_id -encoding binary -translation binary", "match_max 65536", "remove_nulls 0",
                    "set ready " + bin(prefix + "R\u{7}"), "set begun " + bin(prefix + "C\u{7}"),
                    "set jobName [encoding convertfrom utf-8 " + bin(jobName) + "]",
                    Self.promptPatternLine,
                    Self.confirmationRuntime,
                    "send -- " + bin(Self.hook(token, capture: false) + "\r")]
        var commandActive = false
        for (n, cmd) in commands.enumerated() {
            rows.append("need $ready command-\(n+1) \(commandActive ? 1 : 0)")
            commandActive = true
            let line = cmd.text.contains("\n") ? "\u{1b}[200~" + cmd.text + "\u{1b}[201~" : cmd.text
            rows += ["send -- " + bin(line + "\r"), "need $begun command-\(n+1)"]
            var previous = Data()
            var k = 0
            while k < cmd.replies.count {
                let reply = cmd.replies[k]
                let label = "command-\(n+1)/input-\(k+1)"
                if Self.isChoice(reply.before) {
                    // A typed "y" and Return often arrive as separate events. Neither
                    // should be replayed on top of the decision made during this run.
                    var recorded = reply.keys
                    while recorded.last != 13 && recorded.last != 10 && k + 1 < cmd.replies.count {
                        let more = cmd.replies[k+1].keys
                        guard recorded.count <= 12, more.allSatisfy({ $0 == 13 || $0 == 10 || (65...90).contains($0) || (97...122).contains($0) }) else { break }
                        k += 1; recorded.append(more)
                    }
                    rows.append("confirmNext \(label)")
                    previous = Data()
                } else {
                    if !reply.before.isEmpty && reply.before != previous {
                        rows.append("need [binary format H* {\(reply.before.hex)}] \(label)-before 1")
                    }
                    rows.append("send -- [binary format H* {\(reply.keys.hex)}]")
                    if !reply.after.isEmpty && !Self.isChoice(reply.after) {
                        rows.append("need [binary format H* {\(reply.after.hex)}] \(label)-after 1")
                    }
                    previous = reply.after
                }
                k += 1
            }
        }
        rows += [Self.completionWait, "set result [wait]",
                 "if {[llength $result] != 4 || [lindex $result 2] != 0} {exit 1}", "exit [lindex $result 3]"]
        let result = rows.joined(separator: "\n") + "\n"
        return Self.updatedTerminalOutput(in: result) ?? result
    }
}

// Terminal-generated replies go straight to the PTY, not into the recording.
private final class CaptureTerminal: ComposingTerminalView {
    weak var transport: LocalProcess?
    nonisolated override func send(source: Terminal, data: ArraySlice<UInt8>) {
        let bytes = Array(data)
        Task { @MainActor in self.transport?.send(data: bytes[...]) }
    }
}

@MainActor
final class RecordingSession: NSObject, ObservableObject, @preconcurrency LocalProcessDelegate, TerminalViewDelegate {
    @Published private(set) var count = 0
    @Published private(set) var prompt: InputTape.Prompt?
    @Published private(set) var finished = false
    @Published private(set) var error: String?
    private(set) var tape = InputTape()
    let directory = FileManager.default.homeDirectoryForCurrentUser.path
    fileprivate let terminal = CaptureTerminal(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
    private lazy var process = LocalProcess(delegate: self, dispatchQueue: .main)
    private let token = UUID().uuidString
    private lazy var marker = Data(("\u{1b}]777;" + token + ":").utf8)
    private var pending = Data(), output = Data()
    private var started = false, active = false, ready = false
    private var size = 0

    func start() {
        guard !started else { return }
        started = true
        terminal.terminalDelegate = self
        terminal.transport = process
        process.startProcess(executable: "/bin/zsh", args: ["-ilo", "histignorespace"], currentDirectory: directory)
        process.send(data: Array((InputTape.hook(token, capture: true) + "\r").utf8)[...])
    }
    func stop() { if process.running { process.terminate() } }

    // Keep a short contiguous printable anchor from the latest output, excluding
    // ANSI control sequences. The exact bytes can then be matched in the PTY.
    private func anchor() -> Data {
        let text = String(decoding: output, as: UTF8.self)
            .replacingOccurrences(of: #"\x1B(?:\[[0-?]*[ -/]*[@-~]|\][^\x07]*(?:\x07|\x1B\\)|.)"#, with: "\n", options: .regularExpression)
        let tail = text.components(separatedBy: .controlCharacters).last { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        return Data(String(tail.suffix(64)).utf8)
    }
    private func finishReply(_ context: Data) {
        guard active, let i = tape.commands.indices.last, let j = tape.commands[i].replies.indices.last else { return }
        tape.commands[i].replies[j].after = context
    }
    private func frame(_ payload: String) {
        finishReply(anchor()); output.removeAll(); prompt = nil
        if payload == "R" { active = false; ready = true; return }
        if payload.first == "C", let bytes = Data(hexText: payload.dropFirst()), let command = String(data: bytes, encoding: .utf8), error == nil {
            guard size + bytes.count <= 262144, count < 20000 else { invalidate("Recording limit reached."); return }
            size += bytes.count
            tape.commands.append(RecordedCommand(text: command))
            count += 1; active = true
        }
    }
    private func rendered(_ data: Data) {
        guard !data.isEmpty else { return }
        if ready { terminal.feed(byteArray: Array(data)[...]) }
        if active {
            output.append(data); output = Data(output.suffix(2048))
            let next = InputTape.Prompt(String(decoding: output, as: UTF8.self))
            if prompt != next { prompt = next }
        }
    }
    func dataReceived(slice: ArraySlice<UInt8>) {
        pending.append(contentsOf: slice)
        while !pending.isEmpty {
            if let r = pending.range(of: marker) {
                rendered(Data(pending[..<r.lowerBound])); pending.removeSubrange(..<r.lowerBound)
                guard let end = pending.firstIndex(of: 7) else {
                    if pending.count > 600000 { invalidate("The command is too long."); pending.removeAll() }
                    return
                }
                frame(String(decoding: pending.dropFirst(marker.count).prefix(upTo: end), as: UTF8.self))
                pending.removeSubrange(...end)
            } else {
                var keep = min(marker.count-1, pending.count)
                while keep > 0 && !pending.suffix(keep).elementsEqual(marker.prefix(keep)) { keep -= 1 }
                rendered(Data(pending.dropLast(keep))); pending = Data(pending.suffix(keep)); return
            }
        }
    }
    private func invalidate(_ message: String) { tape.commands.removeAll(); count = 0; error = message }
    func choose(_ token: String) {
        guard active, !finished, prompt?.options.contains(token) == true else { return }
        send(source: terminal, data: Array((token.lowercased() + "\r").utf8)[...])
        terminal.window?.makeFirstResponder(terminal)
    }
    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        guard ready, !data.isEmpty else { return }
        prompt = nil
        defer { process.send(data: data) }
        guard active, error == nil, let i = tape.commands.indices.last else { return }
        var mode = termios()
        if tcgetattr(process.childfd, &mode) == 0, mode.c_lflag & tcflag_t(ICANON) != 0, mode.c_lflag & tcflag_t(ECHO) == 0 {
            invalidate("Recording discarded because hidden input was detected."); return
        }
        size += data.count
        guard size <= 262144, count < 20000 else { invalidate("Recording limit reached."); return }
        let before = anchor()
        if before.isEmpty, let j = tape.commands[i].replies.indices.last {
            tape.commands[i].replies[j].keys.append(contentsOf: data)
        } else {
            finishReply(before)
            tape.commands[i].replies.append(ResponseStep(before: before, keys: Data(data)))
            count += 1
        }
        output.removeAll()
    }
    func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        finishReply(anchor())
        if !active, !tape.commands.isEmpty { tape.commands.append(RecordedCommand(text: "exit")) }
        finished = true
    }
    func processFailedToStart(_ source: LocalProcess, error: LocalProcessError) { invalidate("Could not start the recording shell: \(error)") }
    func getWindowSize() -> winsize {
        let d = terminal.terminalDimensions
        return winsize(ws_row: UInt16(d.rows), ws_col: UInt16(d.cols), ws_xpixel: 0, ws_ypixel: 0)
    }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) { var w = getWindowSize(); _ = process.updateWindowSize(&w) }
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    func clipboardCopy(source: TerminalView, content: Data) {}
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
}

struct RecordingConsole: NSViewRepresentable {
    let session: RecordingSession
    func makeNSView(context: Context) -> NSView {
        let terminal = session.terminal
        session.start()
        DispatchQueue.main.async { terminal.window?.makeFirstResponder(terminal) }
        return terminal
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
