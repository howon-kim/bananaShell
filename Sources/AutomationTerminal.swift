import AppKit
import SwiftUI
import SwiftTerm
import Carbon

struct TerminalGrid: Equatable {
    var cols: Int
    var rows: Int
}

/// The replay writes `ESC ] 777 ; bananaShell-size ; <cols> <rows> BEL` to the
/// log whenever its PTY takes a grid. Output after a marker was laid out for
/// that grid: redraws that pad a line to the full width and return to column 0
/// (Homebrew's progress bars) stack into new rows when replayed narrower.
enum TerminalGridMarker {
    static let prefix = Array("\u{1b}]777;bananaShell-size;".utf8)
    private static let maxPayload = 7 // "500 200"

    enum Match: Equatable {
        case none
        /// The bytes up to the end of the buffer could still become a marker.
        case partial
        case grid(TerminalGrid, end: Int)
    }

    static func match(_ bytes: [UInt8], at i: Int) -> Match {
        for k in prefix.indices {
            guard i + k < bytes.count else { return .partial }
            guard bytes[i + k] == prefix[k] else { return .none }
        }
        let start = i + prefix.count
        var j = start
        while j < bytes.count, bytes[j] != 7 {
            guard j - start < maxPayload else { return .none }
            j += 1
        }
        guard j < bytes.count else { return .partial }
        let parts = String(decoding: bytes[start..<j], as: UTF8.self).split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 2, let cols = Int(parts[0]), let rows = Int(parts[1]),
              (1...999).contains(cols), (1...999).contains(rows) else { return .none }
        return .grid(TerminalGrid(cols: cols, rows: rows), end: j + 1)
    }

    /// The last grid announced in `bytes`, if any.
    static func last(in bytes: [UInt8]) -> TerminalGrid? {
        var found: TerminalGrid?, i = 0
        while let k = bytes[i...].firstIndex(of: 0x1b) {
            if case .grid(let grid, let end) = match(bytes, at: k) { found = grid; i = end } else { i = k + 1 }
        }
        return found
    }
}

/// Separates grid markers from terminal output. A marker split across reads is
/// held back until the rest arrives.
struct TerminalGridMarkerSplitter {
    enum Piece: Equatable {
        case output([UInt8])
        case grid(TerminalGrid)
    }
    private var carry: [UInt8] = []

    mutating func split(_ data: Data) -> [Piece] {
        let bytes = carry + [UInt8](data)
        carry = []
        var pieces: [Piece] = [], start = 0, i = 0
        func flush(_ end: Int) { if end > start { pieces.append(.output(Array(bytes[start..<end]))) } }
        while let k = bytes[i...].firstIndex(of: 0x1b) {
            switch TerminalGridMarker.match(bytes, at: k) {
            case .none: i = k + 1
            case .partial:
                flush(k); carry = Array(bytes[k...]); return pieces
            case .grid(let grid, let end):
                flush(k); pieces.append(.grid(grid)); start = end; i = end
            }
        }
        flush(bytes.count)
        return pieces
    }

    /// Held-back bytes that never became a marker (no more output arrived).
    mutating func drain() -> [UInt8] { defer { carry = [] }; return carry }
    mutating func reset() { carry = [] }
}

/// Read only appended bytes. UTF-8 and escape sequences may span reads; the
/// terminal parser, rather than a String conversion, retains that state.
final class AutomationOutputReader {
    struct Chunk {
        var bytes = Data()
        var reset = false
        var omitted = false
        /// The PTY grid in effect where omitted history ends.
        var grid: TerminalGrid?
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
                chunk.grid = try Self.lastGrid(in: handle, before: position)
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

    /// Scans backwards from `end` for the latest grid marker, so a viewer that
    /// skips old history still starts at the grid the remaining output used.
    static func lastGrid(in handle: FileHandle, before end: UInt64) throws -> TerminalGrid? {
        let block: UInt64 = 64 * 1024, overlap = UInt64(TerminalGridMarker.prefix.count + 8)
        var upper = end, scanned: UInt64 = 0
        while upper > 0, scanned < 32 * 1024 * 1024 {
            let lower = upper > block ? upper - block : 0
            try handle.seek(toOffset: lower)
            let data = try handle.read(upToCount: Int(min(upper + overlap, end) - lower)) ?? Data()
            if let grid = TerminalGridMarker.last(in: [UInt8](data)) { return grid }
            scanned += upper - lower
            upper = lower
        }
        return nil
    }
}

/// Shows the playback terminal at the width of the PTY that produced the
/// output, clipped or padded inside the space SwiftUI gives it, and reports the
/// grid that space fits so the PTY can follow. Width decides how lines wrap;
/// rows keep the console's height so the newest output stays in view (the
/// PTY adopts them while someone watches). Without a marker (plain commands,
/// older logs) the terminal simply fills the space.
final class AutomationTerminalHost: NSView {
    let terminal: TerminalView
    /// Never shown or fed; measures how many cells fit and what frame a grid needs.
    private let gauge: TerminalView
    var onFit: ((TerminalGrid) -> Void)?
    var onReady: (() -> Void)?
    private(set) var ready = false
    private(set) var fit: TerminalGrid?
    var grid: TerminalGrid? {
        didSet { if grid != oldValue { layoutTerminal() } }
    }

    init(terminal: TerminalView) {
        self.terminal = terminal
        gauge = TerminalView(frame: terminal.frame)
        // Zero until SwiftUI lays it out: nothing is replayed at a placeholder width.
        super.init(frame: .zero)
        gauge.font = terminal.font
        gauge.lineSpacing = terminal.lineSpacing
        gauge.isHidden = true
        gauge.setAccessibilityElement(false)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.backgroundColor = terminal.nativeBackgroundColor.cgColor
        terminal.autoresizingMask = []
        addSubview(gauge)
        addSubview(terminal)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); layoutTerminal() }
    override func layout() { super.layout(); layoutTerminal() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); layoutTerminal() }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); layoutTerminal() }

    private func layoutTerminal() {
        guard window != nil, bounds.width > 0, bounds.height > 0 else { return }
        gauge.setFrameSize(bounds.size)
        let dims = gauge.terminalDimensions
        let fits = TerminalGrid(cols: dims.cols, rows: dims.rows)
        // A grid wider than the space is clipped on the right.
        let width = grid.map { frameWidth(cols: $0.cols, rows: fits.rows) } ?? bounds.width
        let frame = NSRect(x: 0, y: 0, width: width, height: bounds.height)
        if terminal.frame != frame { terminal.frame = frame }
        if fit != fits { fit = fits; onFit?(fits) }
        if !ready { ready = true; onReady?() }
    }

    private func frameWidth(cols: Int, rows: Int) -> CGFloat {
        gauge.resize(cols: cols, rows: rows)
        let optimal = gauge.getOptimalFrameSize()
        gauge.setFrameSize(bounds.size)
        // Half a point of slack so the cell count never rounds down.
        return optimal.width + 0.5
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
    private var markers = TerminalGridMarkerSplitter()
    /// The view the console mounts. Sessions created with `hosted: false`
    /// (checks that use `terminal` directly) follow the terminal's own frame.
    private(set) lazy var host: AutomationTerminalHost = {
        hosted = true
        let host = AutomationTerminalHost(terminal: terminal)
        host.onFit = { [weak self] _ in self?.publishSize() }
        host.onReady = { [weak self] in
            guard let self, self.timer != nil else { return }
            self.publishSize()
            self.readOutput()
        }
        return host
    }()
    private var hosted = false

    private let inputURL: URL?
    private var inputSequence = 0

    /// `inputURL` is the replay script; typed keys are written beside it as `<script>.input.<n>`.
    init(outputURL: URL, offset: UInt64, sizeURL: URL?, inputURL: URL? = nil, hosted: Bool = false) {
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
        // Before any read, so no output is replayed outside the PTY's grid.
        if hosted { _ = host }
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
        publishSize()
        readOutput()
        let timer = Timer(timeInterval: active ? 0.1 : 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.readOutput() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /// Withdraws the published size so the next unattended run starts at the
    /// replay's default grid instead of a width left over from an old window.
    func stop() {
        timer?.invalidate(); timer = nil
        if !lastSize.isEmpty, let sizeURL {
            try? FileManager.default.removeItem(at: sizeURL)
            lastSize = ""
        }
    }
    deinit {
        timer?.invalidate()
        if let copyMonitor { NSEvent.removeMonitor(copyMonitor) }
    }

    func readOutput() {
        // Nothing is replayed before the console has its real size.
        if hosted && !host.ready { return }
        do {
            let chunk = try reader.read()
            if chunk.reset {
                markers.reset()
                if hosted { host.grid = nil }
                terminal.feed(text: "\u{1b}c")
            }
            if hosted, let grid = chunk.grid { host.grid = grid }
            if chunk.omitted { terminal.feed(text: "Earlier output omitted.\r\n") }
            if chunk.bytes.isEmpty {
                let held = markers.drain()
                if !held.isEmpty { terminal.feed(byteArray: held[...]) }
            }
            for piece in markers.split(chunk.bytes) {
                switch piece {
                case .output(let bytes): terminal.feed(byteArray: bytes[...])
                // Resize between the bytes: what follows was laid out for this grid.
                case .grid(let grid): if hosted { host.grid = grid }
                }
            }
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

    /// Asks the PTY for the grid the console fits. Hosted, the terminal itself
    /// follows the PTY's grid, so the fit comes from the host's measurement.
    private func publishSize() {
        guard active, let sizeURL else { return }
        let size: TerminalGrid
        if hosted {
            guard let fit = host.fit else { return }
            size = fit
        } else {
            let dims = terminal.terminalDimensions
            size = TerminalGrid(cols: dims.cols, rows: dims.rows)
        }
        let value = "\(min(500, max(20, size.cols))) \(min(200, max(5, size.rows)))"
        guard lastSize != value else { return }
        do {
            try Data(value.utf8).write(to: sizeURL, options: .atomic)
            lastSize = value
        } catch { /* The replay can still use its default grid. */ }
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) { if !hosted { publishSize() } }
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
        _session = StateObject(wrappedValue: AutomationTerminalSession(outputURL: outputURL, offset: offset, sizeURL: sizeURL, inputURL: inputURL, hosted: true))
        self.active = active
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Surface(host: session.host)
            if let failure = session.failure {
                Text(failure).font(.caption).foregroundStyle(.red).padding(10)
            }
        }
        .onAppear { session.start(active: active) }
        .onChange(of: active) { session.start(active: $0) }
        .onDisappear { session.stop() }
    }

    private struct Surface: NSViewRepresentable {
        let host: AutomationTerminalHost
        func makeNSView(context: Context) -> AutomationTerminalHost { host }
        func updateNSView(_ view: AutomationTerminalHost, context: Context) {}
    }
}
