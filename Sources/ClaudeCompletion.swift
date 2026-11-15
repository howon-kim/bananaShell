import AppKit
import SwiftUI
import CoreText
import QuartzCore

struct ClaudeCompletion: Decodable {
    enum Source: String, Decodable {
        case claude, test
        var name: String { self == .claude ? "Claude" : "bananaShell Test" }
        var status: String { self == .claude ? "Response complete" : "Test complete" }
        var announcement: String { name + " · " + status }
    }
    let source: Source?
    var sender: Source { source ?? .claude }
    let pane: UUID
    let timestamp: TimeInterval
    /// Plain-text preview of Claude's final reply, already trimmed by the hook.
    let summary: String?

    static func drain(_ directory: URL, now: Date = Date()) -> [ClaudeCompletion] {
        let manager = FileManager.default
        let files = (try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { file in
            defer { try? manager.removeItem(at: file) }
            guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 4096,
                  let data = try? Data(contentsOf: file),
                  let event = try? JSONDecoder().decode(Self.self, from: data),
                  (0...60).contains(now.timeIntervalSince1970 - event.timestamp) else { return nil }
            return event
        }.sorted { $0.timestamp < $1.timestamp }
    }
}

/// The small label row of a notch card: who is speaking and what happened.
struct IslandHeader {
    let name: String
    let status: String
    let icon: String
    var announcement: String { name + " · " + status }
    init(name: String, status: String, icon: String = "bell.fill") {
        self.name = name; self.status = status; self.icon = icon
    }
    init(_ source: ClaudeCompletion.Source) { self.init(name: source.name, status: source.status) }
    static let automation = IslandHeader(name: "Automation", status: "Needs input", icon: "gearshape.2.fill")
}

// Visual components below are ported from BananaCal's ToolsIslandController.swift.
// Keep its metrics, surface, tracking, glass and button styles in sync; only the
// notification data and terminal action differ. ObservableObject preserves macOS 13 support.
@MainActor final class ClaudeCompletionNotch {
    private struct Alert {
        /// Set for alerts that can be withdrawn, such as automation questions.
        var id: String? = nil
        let title: String
        let summary: String?
        let header: IslandHeader
        let screen: NSScreen
        /// Answer buttons; a card with choices stays until answered, closed or withdrawn.
        var choices: [String] = []
        var answer: (Int) -> Void = { _ in }
        let open: () -> Void
        var persistent: Bool { !choices.isEmpty }
    }
    private var queue: [Alert] = []
    private var current: Alert?
    private var panel: CompletionIslandPanel?
    private var hideTask: Task<Void, Never>?
    private var screenObserver: NSObjectProtocol?
    private var alertWasHovered = false

    private static let registerFonts: Void = {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        for name in ["SUITE-Medium", "SUITE-SemiBold"] {
            if let url = bundle.url(forResource: name, withExtension: "ttf") {
                CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            }
        }
        if let url = bundle.url(forResource: "SUITE-Bold", withExtension: "otf") {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }()

    func show(title: String, summary: String? = nil, source: ClaudeCompletion.Source = .claude, screen: NSScreen?, open: @escaping () -> Void) {
        _ = Self.registerFonts
        guard let screen = screen ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let summary = summary?.trimmingCharacters(in: .whitespacesAndNewlines)
        queue.append(Alert(title: title, summary: summary?.isEmpty == false ? summary : nil, header: IslandHeader(source), screen: screen, open: open))
        if panel == nil { presentNext() }
    }

    /// An automation waiting for an answer. It jumps ahead of completion cards,
    /// interrupting one on screen (which returns afterwards), and stays visible.
    func showQuestion(id: String, automation: String, question: String, options: [String], screen: NSScreen?,
                      open: @escaping () -> Void, answer: @escaping (Int) -> Void) {
        _ = Self.registerFonts
        guard !options.isEmpty, current?.id != id, !queue.contains(where: { $0.id == id }),
              let screen = screen ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let alert = Alert(id: id, title: automation, summary: question, header: .automation, screen: screen,
                          choices: options, answer: answer, open: open)
        queue.insert(alert, at: queue.firstIndex(where: { !$0.persistent }) ?? queue.endIndex)
        guard let shown = current else { return presentNext() }
        if !shown.persistent {
            queue.insert(shown, at: queue.firstIndex(where: { !$0.persistent }) ?? queue.endIndex)
            dismiss()
        }
    }

    /// Withdraw an alert that no longer applies, e.g. a question answered elsewhere.
    func retract(id: String) {
        queue.removeAll { $0.id == id }
        if current?.id == id { dismiss() }
    }

    /// Display changes rebuild the panel; unanswered questions survive, brief cards do not.
    private func screensChanged() {
        hideTask?.cancel()
        panel?.collapseTask?.cancel()
        panel?.orderOut(nil)
        panel = nil
        queue = ((current.map { [$0] } ?? []) + queue).filter(\.persistent)
        current = nil
        presentNext()
    }

    func stop() {
        hideTask?.cancel()
        panel?.collapseTask?.cancel()
        panel?.orderOut(nil)
        panel = nil
        current = nil
        queue.removeAll()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
    }

    private func presentNext() {
        guard !queue.isEmpty else { return }
        let alert = queue.removeFirst()
        guard let screen = NSScreen.screens.first(where: { $0 == alert.screen }) ?? NSScreen.main else { return }
        alertWasHovered = false
        current = alert
        let panel = makePanel()
        panel.title = alert.header.announcement
        panel.size = .medium
        let notchHeight = screen.safeAreaInsets.top
        let notchWidth: CGFloat
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            notchWidth = max(0, right.minX - left.maxX)
        } else { notchWidth = 0 }
        let compactWidth = notchHeight > 0 && notchWidth > 0 ? notchWidth : min(180, screen.frame.width - 16)
        let width = min(max(CompletionIslandMetrics.mediumWidth, compactWidth), screen.frame.width - 16)
        typealias M = CompletionIslandMetrics
        let detail = M.lineHeight("SUITE-Medium", 11.5)
        let detailLines = alert.summary == nil ? 1 : CompletionIslandMetrics.summaryLineLimit
        let valueHeight = M.mediumValueHeight(lines: [max(M.lineHeight("SUITE-SemiBold", 11), M.lineHeight("SUITE-Medium", 17)),
                                                      M.lineHeight("SUITE-Bold", 15), detail * CGFloat(detailLines)])
        panel.valueHeight = valueHeight
        panel.topInset = M.topInset(for: notchHeight)
        panel.topEdge = screen.frame.maxY
        let size = NSSize(width: width, height: panel.topInset + M.bodyHeight(isExpanded: false, valueHeight: valueHeight))
        let rootView = CompletionIslandView(title: alert.title, summary: alert.summary, header: alert.header, presentation: panel.presentation,
            valueHeight: valueHeight, notchHeight: notchHeight, choices: alert.choices,
            activate: { [weak self] in self?.dismiss(); alert.open() },
            answer: { [weak self] index in self?.dismiss(); alert.answer(index) },
            close: { [weak self] in self?.dismiss() },
            expansionChanged: { [weak self, weak panel] expanded, animated in
                guard let self, let panel else { return }
                self.requestExpansion(expanded, for: panel, animated: animated)
            })
        panel.contentView = CompletionIslandSurfaceView(frame: NSRect(origin: .zero, size: size), rootView: rootView)
        panel.setFrame(NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height,
                              width: size.width, height: size.height), display: true)
        self.panel = panel
        panel.orderFrontRegardless()
        if !alert.persistent { scheduleHide(seconds: 12) }
        if screenObserver == nil {
            screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.screensChanged() } }
        }
    }

    private func requestExpansion(_ expanded: Bool, for panel: CompletionIslandPanel, animated: Bool) {
        panel.collapseTask?.cancel()
        if expanded {
            alertWasHovered = true
            hideTask?.cancel()
        } else if alertWasHovered, current?.persistent == false {
            scheduleHide(seconds: 4)
        }
        // Answer buttons must stay reachable without hovering.
        let expanded = expanded || current?.persistent == true
        if expanded || !animated {
            setExpanded(expanded, for: panel, animated: animated)
        } else {
            panel.collapseTask = Task { @MainActor [weak self, weak panel] in
                do { try await Task.sleep(for: CompletionIslandMetrics.collapseDelay) } catch { return }
                guard let self, let panel else { return }
                self.setExpanded(false, for: panel, animated: true)
            }
        }
    }

    private func scheduleHide(seconds: UInt64) {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: seconds * 1_000_000_000) } catch { return }
            self?.dismiss()
        }
    }

    private func dismiss() {
        hideTask?.cancel()
        panel?.collapseTask?.cancel()
        panel?.orderOut(nil)
        panel = nil
        current = nil
        presentNext()
    }
    private func makePanel() -> CompletionIslandPanel {
        let panel = CompletionIslandPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.acceptsMouseMovedEvents = true
        panel.animationBehavior = .none
        panel.isMovable = false
        return panel
    }

    private func setExpanded(_ expanded: Bool, for panel: CompletionIslandPanel, animated: Bool) {
        guard self.panel === panel,
              panel.presentation.isExpanded != expanded else { return }
        let animationID = UUID()
        panel.animationID = animationID
        let height = panel.topInset + CompletionIslandMetrics.bodyHeight(isExpanded: expanded, valueHeight: panel.valueHeight)
        var frame = panel.frame
        frame.origin.y = panel.topEdge - height
        frame.size.height = height
        // Grow the transparent canvas before revealing the tray. Never animate the
        // NSWindow as well: two layout clocks made the glass and content shear apart.
        if expanded || !animated {
            panel.setFrame(frame, display: true)
        }
        panel.presentation.isExpanded = expanded
        guard let surface = panel.contentView as? CompletionIslandSurfaceView else { return }
        surface.setVisibleHeight(height, animated: animated) { [weak self, weak panel] in
            guard let self, let panel, self.panel === panel,
                  panel.animationID == animationID, !panel.presentation.isExpanded else { return }
            // Trim the transparent canvas only after the visible surface settles.
            panel.setFrame(frame, display: true)
        }
    }
}
@MainActor
private final class CompletionIslandPanel: NSPanel {
    let presentation = CompletionIslandPresentation()
    var size: CompletionIslandSize = .compact
    var valueHeight: CGFloat = CompletionIslandMetrics.compactValueHeight
    var topInset: CGFloat = 0
    var topEdge: CGFloat = 0
    var animationID = UUID()
    var collapseTask: Task<Void, Never>?
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Liquid Glass renders its subdued (heavily frosted) variant in any window
    /// without key appearance. The island never takes key focus, so claim key
    /// appearance to keep `.clear` glass crisp and refracting over other apps.
    /// Not in the public SDK headers; if AppKit stops consulting it, the island
    /// simply falls back to the frosted look.
    @objc func hasKeyAppearance() -> Bool { true }
}

@MainActor
private final class CompletionIslandPresentation: ObservableObject {
    @Published var isExpanded = false
}

/// Compact islands show one value; the medium island is the next-event card.
private enum CompletionIslandSize { case compact, medium }

private enum CompletionIslandMetrics {
    static let bezelOverflow: CGFloat = 20
    static let mediumWidth: CGFloat = 340
    /// Reply previews wrap to this many lines; the card height reserves them up front.
    static let summaryLineLimit = 3

    static let compactValueHeight: CGFloat = 44
    /// Medium cards: padding above the first line, spacing between lines, and the
    /// gap kept between the last line and the black-to-glass fade / hover tray.
    static let mediumTopPadding: CGFloat = 4
    static let mediumLineSpacing: CGFloat = 5
    static let mediumBottomGap: CGFloat = 10
    static let progressRowHeight: CGFloat = 5  // 3 pt bar + 2 pt top padding

    private static var lineHeights: [String: CGFloat] = [:]

    /// Single-line height of a bundled font, so card heights are known before
    /// layout and the panel never resizes (flickers) after it appears.
    @MainActor
    static func lineHeight(_ name: String, _ size: CGFloat) -> CGFloat {
        let key = "\(name)-\(size)"
        if let cached = lineHeights[key] { return cached }
        let height = NSFont(name: name, size: size)
            .map { ceil(NSLayoutManager().defaultLineHeight(for: $0)) } ?? ceil(size * 1.25)
        lineHeights[key] = height
        return height
    }

    /// Height of a medium card from its line heights, top to bottom.
    static func mediumValueHeight(lines: [CGFloat]) -> CGFloat {
        mediumTopPadding + lines.reduce(0, +)
            + mediumLineSpacing * CGFloat(max(0, lines.count - 1)) + mediumBottomGap
    }
    static let collapsedTrayHeight: CGFloat = 0
    /// The 34 pt buttons sit at the bottom of this band, leaving a 10 pt gap
    /// between the content and the controls.
    static let expandedTrayHeight: CGFloat = 44
    static let expansionDuration: TimeInterval = 0.28
    static let collapseDelay: Duration = .milliseconds(160)
    /// Glass band at the very bottom, collapsed or expanded. Kept short so the
    /// island fits its content; the fade doesn't need to cover the whole band.
    static let glassRimHeight: CGFloat = 16
    /// The black starts fading this far above the end of the content and keeps
    /// fading all the way to the bottom edge, so the tray sits on a long, gentle
    /// gradient rather than on bare glass.
    static let fadeOverlap: CGFloat = 12
    /// A faint tint left at the very bottom so the glass never reads as a hard cut.
    static let fadeEndOpacity: Double = 0.1
    static let cornerRadius: CGFloat = 20

    static func bodyHeight(isExpanded: Bool, valueHeight: CGFloat) -> CGFloat {
        valueHeight + (isExpanded ? expandedTrayHeight : collapsedTrayHeight) + glassRimHeight
    }

    static func topInset(for notchHeight: CGFloat) -> CGFloat {
        notchHeight > 0 ? notchHeight : 16
    }
}

private struct CompletionIslandView: View {
    let title: String
    let summary: String?
    let header: IslandHeader
    @ObservedObject var presentation: CompletionIslandPresentation
    let valueHeight: CGFloat
    let notchHeight: CGFloat
    let choices: [String]
    let activate: () -> Void
    let answer: (Int) -> Void
    let close: () -> Void
    let expansionChanged: (Bool, Bool) -> Void

    @State private var isHovered = false
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var showsControls: Bool { presentation.isExpanded }

    var body: some View {
        VStack(spacing: 0) {
            Button(action: activate) {
                CompletionAlertIslandCard(title: title, summary: summary, header: header)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(header.announcement)
            .accessibilityValue(summary.map { title + ", " + $0 } ?? title)
            .accessibilityHint(choices.isEmpty ? "Open terminal" : "Open automation")
            .help(choices.isEmpty ? "Open terminal" : "Open automation")
            .frame(height: valueHeight, alignment: .top)

            trayControls
            .frame(maxWidth: .infinity)
            .frame(height: CompletionIslandMetrics.expandedTrayHeight, alignment: .bottom)
            .opacity(showsControls ? 1 : 0)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.14), value: showsControls)
            .allowsHitTesting(showsControls)
            .accessibilityHidden(!showsControls)
        }
        .padding(.top, CompletionIslandMetrics.bezelOverflow + CompletionIslandMetrics.topInset(for: notchHeight))
        .frame(maxWidth: .infinity)
        .frame(height: CompletionIslandMetrics.bezelOverflow + CompletionIslandMetrics.topInset(for: notchHeight) + CompletionIslandMetrics.bodyHeight(isExpanded: true, valueHeight: valueHeight), alignment: .top)
        .contentShape(Rectangle())
        .background {
            IslandHoverTracker { hovered in
                isHovered = hovered
                expansionChanged(hovered || voiceOverEnabled, !reduceMotion)
            }
        }
        .onAppear {
            DispatchQueue.main.async { expansionChanged(isHovered || voiceOverEnabled, !reduceMotion) }
        }
        .onChange(of: voiceOverEnabled) { enabled in
            DispatchQueue.main.async { expansionChanged(isHovered || enabled, !reduceMotion) }
        }
        .background(alignment: .top) {
            notchBlend
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .background(alignment: .top) {
            islandGlass
                .accessibilityHidden(true)
        }
    }

    private var visibleHeight: CGFloat {
        CompletionIslandMetrics.bezelOverflow + CompletionIslandMetrics.topInset(for: notchHeight)
            + CompletionIslandMetrics.bodyHeight(isExpanded: presentation.isExpanded, valueHeight: valueHeight)
    }

    /// The official SwiftUI Liquid Glass, sized to the visible island so its
    /// refracting edge sits on the actual bottom rim and follows the tray reveal.
    @ViewBuilder
    private var islandGlass: some View {
        let shape = RoundedRectangle(cornerRadius: CompletionIslandMetrics.cornerRadius, style: .continuous)
        Group {
            if #available(macOS 26.0, *) {
                Color.clear.glassEffect(.clear, in: shape)
            } else {
                shape.fill(.ultraThinMaterial)
            }
        }
        .frame(height: visibleHeight)
        .animation(reduceMotion ? nil : .easeInOut(duration: CompletionIslandMetrics.expansionDuration),
                   value: presentation.isExpanded)
    }

    /// Solid black where the panel meets the hardware notch, melting into the
    /// clear glass so only the lower rim reads as glass. Tracks the tray reveal.
    private var notchBlend: some View {
        let solid = CompletionIslandMetrics.bezelOverflow + CompletionIslandMetrics.topInset(for: notchHeight)
        let height = solid + CompletionIslandMetrics.bodyHeight(isExpanded: presentation.isExpanded, valueHeight: valueHeight)
        // Solid black behind the content, then one long, gentle fade from just
        // above the last line to the bottom edge. The hover tray sits inside the
        // fade (partly dark, so its glyphs stay legible) and the bottom keeps a
        // faint tint. Smoothstep keeps both ends flat, avoiding visible bands.
        let fadeStart = max(solid, solid + valueHeight - CompletionIslandMetrics.fadeOverlap) / height
        let floor = CompletionIslandMetrics.fadeEndOpacity
        let samples = 32
        let stops: [Gradient.Stop] = [.init(color: .black, location: 0)]
            + (0...samples).map { step in
                let u = Double(step) / Double(samples)
                // Half linear, half smoothstep: flat where it leaves the black, but a
                // gentler middle than pure smoothstep (peak slope 1.25 instead of 1.5).
                let eased = 0.5 * u + 0.5 * u * u * (3 - 2 * u)
                return .init(color: .black.opacity(1 - (1 - floor) * eased),
                             location: fadeStart + (1 - fadeStart) * u)
            }
        return LinearGradient(stops: stops, startPoint: .top, endPoint: .bottom)
        .frame(height: height)
        // Match the glass outline; a bare rectangle shows square corners past the rounded rim.
        .clipShape(RoundedRectangle(cornerRadius: CompletionIslandMetrics.cornerRadius, style: .continuous))
        .animation(reduceMotion ? nil : .easeInOut(duration: CompletionIslandMetrics.expansionDuration),
                   value: presentation.isExpanded)
    }

    private var trayControls: some View {
        HStack(spacing: choices.isEmpty ? 18 : 10) {
            ForEach(Array(choices.enumerated()), id: \.offset) { index, choice in
                Button { answer(index) } label: {
                    Text(verbatim: choice)
                        .font(.custom("SUITE-SemiBold", size: 13))
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 14)
                }
                .buttonStyle(IslandTrayButtonStyle(prominent: index == 0))
                .accessibilityLabel(choice)
            }
            if !choices.isEmpty { Spacer(minLength: 0) }
            Button(action: activate) { Image(systemName: choices.isEmpty ? "terminal" : "arrow.up.forward.app") }
                .buttonStyle(IslandTrayButtonStyle(prominent: choices.isEmpty, title: choices.isEmpty ? "Terminal" : "Open"))
                .help(choices.isEmpty ? "Open terminal" : "Open automation")
                .accessibilityLabel(choices.isEmpty ? "Open terminal" : "Open automation")
            Button(action: close) { Image(systemName: "xmark") }
                .buttonStyle(IslandTrayButtonStyle(title: "Close"))
                .help("Dismiss alert")
                .accessibilityLabel("Dismiss alert")
        }
        .padding(.horizontal, 16)
    }
}

private struct CompletionAlertIslandCard: View {
    let title: String
    let summary: String?
    let header: IslandHeader
    var body: some View {
        VStack(alignment: .leading, spacing: CompletionIslandMetrics.mediumLineSpacing) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: header.icon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.orange)
                Text(verbatim: header.name)
                    .font(.custom("SUITE-SemiBold", size: 11))
                    .foregroundStyle(.white.opacity(0.6))
                Spacer(minLength: 8)
                Text(verbatim: header.status)
                    .font(.custom("SUITE-Medium", size: 17))
                    .monospacedDigit()
                    .foregroundStyle(.orange)
            }
            Text(verbatim: title)
                .font(.custom("SUITE-Bold", size: 15))
                .foregroundStyle(.white)
                .lineLimit(1)
            Text(verbatim: summary ?? "Check the terminal for the result")
                .font(.custom("SUITE-Medium", size: 11.5))
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(summary == nil ? 1 : CompletionIslandMetrics.summaryLineLimit)
                .fixedSize(horizontal: false, vertical: true)
        }
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(.horizontal, 18)
        .padding(.top, CompletionIslandMetrics.mediumTopPadding)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// Icon-only controls on the bare-glass tray. Every glyph sits on a translucent
/// dark circle so it reads over any wallpaper, including white; the primary
/// action's circle is a little stronger, and hover brightens it.
private struct IslandTrayButtonStyle: ButtonStyle {
    var prominent = false
    /// Shown beside the icon while hovered, since tooltips don't appear on
    /// the non-key island.
    var title: String? = nil

    func makeBody(configuration: Configuration) -> some View {
        IslandTrayButton(configuration: configuration, prominent: prominent, title: title)
    }
}

/// Hover state lives in a real view; ButtonStyle itself is not a stable state host.
private struct IslandTrayButton: View {
    let configuration: ButtonStyleConfiguration
    let prominent: Bool
    let title: String?
    @State private var isHovered = false

    private var circleOpacity: Double {
        if prominent { return isHovered ? 0.62 : 0.45 }
        return isHovered ? 0.55 : 0.30
    }

    private var showsTitle: Bool { isHovered && title?.isEmpty == false }

    var body: some View {
        let pressed = configuration.isPressed
        // Hovering widens the circle into a pill that names the button.
        return HStack(spacing: 6) {
            configuration.label
                .font(.system(size: prominent ? 16 : 14, weight: .semibold))
            if showsTitle, let title {
                Text(title)
                    .font(.custom("SUITE-SemiBold", size: 12))
                    .lineLimit(1)
                    .fixedSize()
                    .transition(.opacity.combined(with: .move(edge: .leading)))
            }
        }
        .foregroundStyle(Color.white.opacity(prominent || isHovered ? 1 : 0.85))
        .padding(.horizontal, showsTitle ? 12 : 0)
        .frame(minWidth: 34)
        .frame(height: 34)
        .background {
            Capsule(style: .circular)
                .fill(Color.black.opacity(circleOpacity))
                // Hover: a soft white wash inside and a brighter rim.
                .overlay { Capsule(style: .circular).fill(Color.white.opacity(isHovered ? 0.12 : 0)) }
                .overlay {
                    Capsule(style: .circular).strokeBorder(Color.white.opacity(isHovered ? 0.45 : prominent ? 0.22 : 0.12),
                                                           lineWidth: isHovered ? 1 : 0.5)
                }
                .shadow(color: .white.opacity(isHovered ? 0.18 : 0), radius: 6)
        }
        .contentShape(Capsule(style: .circular))
        .scaleEffect(pressed ? 0.92 : isHovered ? 1.05 : 1)
        .opacity(pressed ? 0.8 : 1)
        .animation(.spring(response: 0.25, dampingFraction: 0.78), value: isHovered)
        .animation(.easeOut(duration: 0.12), value: pressed)
        // The island never becomes key, so SwiftUI's onHover can stay silent;
        // the always-active tracking area used for the island itself works here.
        .background { IslandButtonHoverTracker { isHovered = $0 } }
    }
}

/// Per-button hover for the non-key island. Unlike the island's tracker it
/// decides the initial state only after layout, from the real bounds, so a
/// freshly shown tray doesn't start with every button "hovered".
/// Hover that works in panels of an inactive app (the notch views never make the app active).
struct IslandButtonHoverTracker: NSViewRepresentable {
    let changed: (Bool) -> Void

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.changed = changed
        return view
    }

    func updateNSView(_ nsView: TrackingView, context: Context) { nsView.changed = changed }

    final class TrackingView: NSView {
        var changed: (Bool) -> Void = { _ in }
        private var area: NSTrackingArea?
        private var isInside = false

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let area { removeTrackingArea(area) }
            let area = NSTrackingArea(rect: .zero,
                                      options: [.inVisibleRect, .activeAlways, .mouseEnteredAndExited, .mouseMoved],
                                      owner: self, userInfo: nil)
            addTrackingArea(area)
            self.area = area
            DispatchQueue.main.async { [weak self] in self?.syncWithPointer() }
        }

        private func syncWithPointer() {
            guard let window, !bounds.isEmpty else { return set(false) }
            let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            set(bounds.contains(point))
        }

        private func set(_ inside: Bool) {
            guard inside != isInside else { return }
            isInside = inside
            changed(inside)
        }

        override func mouseEntered(with event: NSEvent) { set(true) }
        override func mouseExited(with event: NSEvent) { set(false) }
        override func mouseMoved(with event: NSEvent) { syncWithPointer() }
    }
}

/// Track non-key panels on every display, including while another app is active.
private struct IslandHoverTracker: NSViewRepresentable {
    let changed: (Bool) -> Void

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.changed = changed
        return view
    }

    func updateNSView(_ nsView: TrackingView, context: Context) {
        nsView.changed = changed
    }

    final class TrackingView: NSView {
        var changed: (Bool) -> Void = { _ in }
        private var area: NSTrackingArea?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let area { removeTrackingArea(area) }
            let area = NSTrackingArea(
                rect: .zero,
                options: [.inVisibleRect, .activeAlways, .mouseEnteredAndExited, .enabledDuringMouseDrag],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(area)
            self.area = area
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // A newly presented panel may already be underneath the pointer.
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }
                let point = self.convert(window.mouseLocationOutsideOfEventStream, from: nil)
                self.changed(self.visibleRect.contains(point))
            }
        }

        override func mouseEntered(with event: NSEvent) { changed(true) }
        override func mouseExited(with event: NSEvent) { changed(false) }
    }
}

/// Keep the clipping surface outside the SwiftUI hosting tree so only its frame
/// animates and the foreground is revealed by it, never resized. The glass itself
/// is SwiftUI's `glassEffect`, drawn inside the hosted view.
@MainActor
private final class CompletionIslandSurfaceView: NSView {
    private let surface: NSView
    override var isFlipped: Bool { true }

    init(frame: NSRect, rootView: CompletionIslandView) {
        let content = IslandGlassContentView()
        content.clipsToBounds = true
        let host = NSHostingView(rootView: rootView)
        host.sizingOptions = []
        host.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            host.topAnchor.constraint(equalTo: content.topAnchor),
            host.heightAnchor.constraint(equalToConstant: CompletionIslandMetrics.bezelOverflow
                + CompletionIslandMetrics.topInset(for: rootView.notchHeight)
                + CompletionIslandMetrics.bodyHeight(isExpanded: true, valueHeight: rootView.valueHeight))
        ])
        surface = content
        super.init(frame: frame)
        clipsToBounds = true
        surface.autoresizingMask = [.width]
        surface.frame = surfaceFrame(height: frame.height)
        addSubview(surface)
    }

    required init?(coder: NSCoder) { nil }

    func setVisibleHeight(_ height: CGFloat, animated: Bool, completion: @escaping () -> Void) {
        // Reserve window space separately; the clip follows the glass on the same curve.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animated ? CompletionIslandMetrics.expansionDuration : 0
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            surface.animator().frame = surfaceFrame(height: height)
        } completionHandler: {
            completion()
        }
    }

    private func surfaceFrame(height: CGFloat) -> NSRect {
        NSRect(x: 0, y: -CompletionIslandMetrics.bezelOverflow, width: bounds.width,
               height: height + CompletionIslandMetrics.bezelOverflow)
    }
}

private final class IslandGlassContentView: NSView {
    override var isFlipped: Bool { true }
}
