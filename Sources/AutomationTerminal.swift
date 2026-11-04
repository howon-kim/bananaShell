import AppKit
import SwiftUI
import SwiftTerm

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
        try handle.seek(toOffset: position)
        chunk.bytes = try handle.read(upToCount: 256 * 1024) ?? Data()
        position += UInt64(chunk.bytes.count)
        return chunk
    }
}

// Playback owns input. Selecting/copying/scrolling remain available, while
// terminal reports and keystrokes cannot interfere with recorded responses.
private final class PlaybackTerminal: TerminalView {
    nonisolated override func send(source: Terminal, data: ArraySlice<UInt8>) {}
}

@MainActor
final class AutomationTerminalSession: NSObject, ObservableObject, TerminalViewDelegate {
    @Published private(set) var failure: String?
    let terminal: TerminalView
    private let reader: AutomationOutputReader
    private let sizeURL: URL?
    private var timer: Timer?
    private var active = false
    private var lastSize = ""

    init(outputURL: URL, offset: UInt64, sizeURL: URL?) {
        reader = AutomationOutputReader(url: outputURL, offset: offset)
        self.sizeURL = sizeURL
        terminal = PlaybackTerminal(frame: NSRect(x: 0, y: 0, width: 860, height: 360))
        super.init()
        terminal.font = terminalFont(size: 14)
        terminal.lineSpacing = 1.15
        terminal.nativeBackgroundColor = shellSurface
        terminal.nativeForegroundColor = NSColor(white: 0.93, alpha: 1)
        terminal.allowMouseReporting = false
        terminal.terminalDelegate = self
        terminal.setAccessibilityLabel("Automation terminal output")
    }

    func start(active: Bool) {
        stop()
        self.active = active
        readOutput()
        publishSize()
        let timer = Timer(timeInterval: active ? 0.1 : 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.readOutput() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stop() { timer?.invalidate(); timer = nil }
    deinit { timer?.invalidate() }

    func readOutput() {
        do {
            let chunk = try reader.read()
            if chunk.reset { terminal.feed(text: "\u{1b}c") }
            if chunk.omitted { terminal.feed(text: "Earlier output omitted.\r\n") }
            if !chunk.bytes.isEmpty { terminal.feed(byteArray: Array(chunk.bytes)[...]) }
            failure = nil
        } catch { failure = error.localizedDescription }
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
    func send(source: TerminalView, data: ArraySlice<UInt8>) {}
    func clipboardCopy(source: TerminalView, content: Data) {}
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
}

struct AutomationConsole: View {
    @StateObject private var session: AutomationTerminalSession
    let active: Bool

    init(outputURL: URL, offset: UInt64, sizeURL: URL?, active: Bool) {
        _session = StateObject(wrappedValue: AutomationTerminalSession(outputURL: outputURL, offset: offset, sizeURL: sizeURL))
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
