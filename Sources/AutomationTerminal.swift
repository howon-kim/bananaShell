import AppKit
import SwiftUI
import SwiftTerm
import Carbon

/// Read only appended bytes. UTF-8 and escape sequences may span reads; the
/// terminal parser, rather than a String conversion, retains that state.
final class AutomationOutputReader {
    struct Chunk {
        var bytes = Data()
        var reset = false
        var omitted = false
    }
    private let url: URL
    private let start: UInt64
    private var identity: String?
    private var position: UInt64 = 0
    private let historyLimit: UInt64 = 1024 * 1024

    init(url: URL, offset: UInt64) { self.url = url; self.start = offset }

    func read() throws -> Chunk {
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: url) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain &&
            [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) { return Chunk() }
        defer { try? handle.close() }
        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            throw NSError(domain: "bananaShell.automation", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Could not read terminal output."])
        }
        let end = UInt64(max(0, info.st_size))
        let current = "\(info.st_dev):\(info.st_ino)"
        var chunk = Chunk()
        if identity == nil {
            position = start <= end ? start : 0
            if end - position > historyLimit {
                position = end - historyLimit
                chunk.omitted = true
            }
        } else if current != identity || end < position {
            position = 0
            chunk.reset = true
        }
        identity = current
        guard end > position else { return chunk }
        try handle.seek(toOffset: position)
        chunk.bytes = try handle.read(upToCount: 256 * 1024) ?? Data()
        position += UInt64(chunk.bytes.count)
        return chunk
    }
}

// Terminal reports never reach the replay. While a run is live, keys the user
// types (e.g. a password the command asks for) are forwarded to its PTY.
private final class PlaybackTerminal: TerminalView {
    var forward: (([UInt8]) -> Void)?
    private(set) var typing = false

    /// Called from a key monitor before AppKit dispatches the key, so bytes the
    /// key produces count as typed; terminal reports that follow later do not.
    func beginKeystroke() {
        typing = true
        DispatchQueue.main.async { [weak self] in self?.typing = false }
    }
    override func paste(_ sender: Any) {
        typing = true; defer { typing = false }
        super.paste(sender)
    }
    // Replies the emulator generates while replaying output (cursor reports,
    // device attributes) belong to the original run; drop them.
    nonisolated override func send(source: Terminal, data: ArraySlice<UInt8>) {}

    /// Keyboard input arrives through the delegate; forward only real keystrokes.
    func typed(_ data: ArraySlice<UInt8>) {
        guard typing, let forward, !data.isEmpty else { return }
        forward(Array(data))
    }
}

@MainActor
final class AutomationTerminalSession: NSObject, ObservableObject, TerminalViewDelegate {
    @Published private(set) var failure: String?
    let terminal: TerminalView
    private let reader: AutomationOutputReader
    private let sizeURL: URL?
    private var timer: Timer?
    private var copyMonitor: Any?
    private var active = false
    private var lastSize = ""

    private let inputURL: URL?
    private var inputSequence = 0

    /// `inputURL` is the replay script; typed keys are written beside it as `<script>.input.<n>`.
    init(outputURL: URL, offset: UInt64, sizeURL: URL?, inputURL: URL? = nil) {
        reader = AutomationOutputReader(url: outputURL, offset: offset)
        self.sizeURL = sizeURL
        self.inputURL = inputURL
        let playback = PlaybackTerminal(frame: NSRect(x: 0, y: 0, width: 860, height: 360))
        terminal = playback
        super.init()
        playback.forward = { [weak self] bytes in self?.sendInput(bytes) }
        terminal.font = terminalFont(size: 14)
        terminal.lineSpacing = 1.15
        terminal.nativeBackgroundColor = shellSurface
        terminal.nativeForegroundColor = NSColor(white: 0.93, alpha: 1)
        terminal.allowMouseReporting = false
        terminal.terminalDelegate = self
        terminal.setAccessibilityLabel("Automation terminal output")
        copyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return event }
                if self.handleCopyShortcut(event) { return nil }
                if let window = self.terminal.window, window.firstResponder === self.terminal,
                   event.windowNumber == window.windowNumber {
                    (self.terminal as? PlaybackTerminal)?.beginKeystroke()
                }
                return event
            }
        }
    }

    // Intercept before terminal key handling clears the selection. Physical
    // key matching also works when a Korean input source is selected.
    func handleCopyShortcut(_ event: NSEvent) -> Bool {
        guard let window = terminal.window, window.firstResponder === terminal,
              event.windowNumber == window.windowNumber,
              event.type == .keyDown, event.keyCode == UInt16(kVK_ANSI_C),
              event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command else { return false }
        terminal.copy(terminal)
        return true
    }

    func start(active: Bool) {
        stop()
        self.active = active
        readOutput()
        publishSize()
        let timer = Timer(timeInterval: active ? 0.1 : 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.readOutput() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stop() { timer?.invalidate(); timer = nil }
    deinit {
        timer?.invalidate()
        if let copyMonitor { NSEvent.removeMonitor(copyMonitor) }
    }

    func readOutput() {
        do {
            let chunk = try reader.read()
            if chunk.reset { terminal.feed(text: "\u{1b}c") }
            if chunk.omitted { terminal.feed(text: "Earlier output omitted.\r\n") }
            if !chunk.bytes.isEmpty { terminal.feed(byteArray: Array(chunk.bytes)[...]) }
            if failure != nil { failure = nil }
        } catch {
            let message = error.localizedDescription
            if failure != message { failure = message }
        }
    }

    /// Hands typed bytes to the running replay through owner-only files it polls and deletes.
    func sendInput(_ bytes: [UInt8]) {
        guard active, let inputURL, !bytes.isEmpty else { return }
        inputSequence += 1
        let name = String(format: "%@.input.%019llu-%06d", inputURL.lastPathComponent,
                          UInt64(Date().timeIntervalSince1970 * 1_000_000), inputSequence)
        let folder = inputURL.deletingLastPathComponent()
        let staging = folder.appendingPathComponent("." + name + ".tmp")
        let fm = FileManager.default
        guard fm.createFile(atPath: staging.path, contents: Data(bytes), attributes: [.posixPermissions: 0o600]) else {
            failure = "Could not send input to the automation."; return
        }
        do { try fm.moveItem(at: staging, to: folder.appendingPathComponent(name)) }
        catch { try? fm.removeItem(at: staging); failure = "Could not send input to the automation." }
    }

    private func publishSize() {
        guard active, let sizeURL else { return }
        let size = terminal.terminalDimensions
        let value = "\(min(500, max(20, size.cols))) \(min(200, max(5, size.rows)))"
        guard lastSize != value else { return }
        do {
            try Data(value.utf8).write(to: sizeURL, options: .atomic)
            lastSize = value
        } catch { /* The replay can still use its default grid. */ }
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) { publishSize() }
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    func send(source: TerminalView, data: ArraySlice<UInt8>) { (source as? PlaybackTerminal)?.typed(data) }
    func clipboardCopy(source: TerminalView, content: Data) {}
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
}

struct AutomationConsole: View {
    @StateObject private var session: AutomationTerminalSession
    let active: Bool

    init(outputURL: URL, offset: UInt64, sizeURL: URL?, inputURL: URL? = nil, active: Bool) {
        _session = StateObject(wrappedValue: AutomationTerminalSession(outputURL: outputURL, offset: offset, sizeURL: sizeURL, inputURL: inputURL))
        self.active = active
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Surface(terminal: session.terminal)
            if let failure = session.failure {
                Text(failure).font(.caption).foregroundStyle(.red).padding(10)
            }
        }
        .onAppear { session.start(active: active) }
        .onChange(of: active) { session.start(active: $0) }
        .onDisappear { session.stop() }
    }

    private struct Surface: NSViewRepresentable {
        let terminal: TerminalView
        func makeNSView(context: Context) -> TerminalView { terminal }
        func updateNSView(_ view: TerminalView, context: Context) {}
    }
}
