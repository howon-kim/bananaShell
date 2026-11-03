import Combine
import SwiftUI
import AppKit

private enum ProgramLogos {
    static let images: [String: NSImage] = {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        var images: [String: NSImage] = [:]
        for url in bundle.urls(forResourcesWithExtension: "svg", subdirectory: "ProgramLogos") ?? [] {
            if let image = NSImage(contentsOf: url) {
                image.isTemplate = true
                images[url.deletingPathExtension().lastPathComponent] = image
            }
        }
        return images
    }()
}

enum ClaudeLimits {
    static func compactSummary(_ rows: [String]) -> String {
        rows.compactMap { row in
            guard let separator = row.range(of: ": ") else { return nil }
            let label = String(row[..<separator.lowerBound])
            let period = label == "5-hour" ? "5h" : label == "Weekly" ? "7d" : label
            let detail = row[separator.upperBound...]
            let usage = detail.components(separatedBy: " · ").first { $0.hasSuffix("% used") }
            return period + " " + (usage.map { String($0.dropLast(5)) } ?? "—")
        }.joined(separator: " · ")
    }


    static func rows(at file: URL, now: Date = Date()) -> [String] {
        guard let data = try? Data(contentsOf: file),
              let windows = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }
        return [("five_hour", "5-hour"), ("seven_day", "Weekly")].compactMap { key, label in
            guard let window = windows[key] as? [String: Any] else { return nil }
            func number(_ field: String) -> Double? {
                guard let value = window[field] as? NSNumber,
                      CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else { return nil }
                return value.doubleValue
            }
            var parts: [String] = []
            if let reset = number("resets_at"), reset > 0 {
                let remaining = reset - now.timeIntervalSince1970
                guard remaining > 0 else { return nil } // The snapshot describes an expired window.
                let formatter = DateComponentsFormatter()
                formatter.allowedUnits = remaining >= 86400 ? [.day, .hour] : [.hour, .minute]
                formatter.unitsStyle = .abbreviated
                if let duration = formatter.string(from: ceil(remaining / 60) * 60) {
                    parts.append("resets in " + duration)
                }
            }
            if let used = number("used_percentage"), (0...100).contains(used) {
                parts.insert(used.formatted(.number.precision(.fractionLength(0...1))) + "% used", at: 0)
            }
            return parts.isEmpty ? nil : label + ": " + parts.joined(separator: " · ")
        }
    }
}

struct TabActivity: Identifiable, Equatable {
    let id: Int
    let shortcutSlot: Int
    let programIcon: String?
    let name: String
    let status: String
    let directory: String
    @ViewBuilder func icon(fallback: String, size: CGFloat) -> some View {
        if let programIcon, let image = ProgramLogos.images[programIcon] {
            Image(nsImage: image).renderingMode(.template).resizable().scaledToFit()
                .frame(width: size, height: size)
        } else {
            Image(systemName: programIcon == "network" || programIcon == "pencil" ? programIcon! : fallback)
        }
    }

    var compactTitle: String {
        var path = name[...]
        if let colon = path.firstIndex(of: ":"), path[..<colon].contains("@") {
            path = path[path.index(after: colon)...]
        }
        guard path == "~" || path.hasPrefix("~/") || path.hasPrefix("/") else { return name }
        return path.split(separator: "/").last.map(String.init) ?? "/"
    }
    let busy: Bool
    let limits: [String]
    var preview = ""
}

final class WorkspaceState: ObservableObject {
    @Published var tabColor = shellSurface
    let addAutomation = PassthroughSubject<Void, Never>()
    let generateKey = PassthroughSubject<Void, Never>()
    let importKey = PassthroughSubject<Void, Never>()
    let focusActivityTerminal = PassthroughSubject<Int, Never>()
    @Published var activityPaneSizes: [Int: ActivityPaneSize] = [:]
    @Published var expandedActivityTerminals: Set<Int> = []
    @Published var activityTerminal: Int?

    func expandActivityTerminal(_ id: Int) {
        expandedActivityTerminals.insert(id)
        activityTerminal = id
    }

    func collapseActivityTerminal(_ id: Int) {
        expandedActivityTerminals.remove(id)
        if activityTerminal == id { activityTerminal = nil }
    }

    func toggleActivityTerminal(_ id: Int) {
        if activityTerminal == id && expandedActivityTerminals.contains(id) {
            collapseActivityTerminal(id)
        } else {
            expandActivityTerminal(id)
        }
    }

    @Published var selected: WorkspaceTab = .keys
    @Published var tabs: [TabActivity] = []
}

enum WorkspaceTab: Hashable { case keys, activity, automations, settings, shell(Int) }

private struct ShellTabFramesKey: PreferenceKey {
    static let defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

private let sessionAccent = Color(red: 0.46, green: 0.87, blue: 0.76)

private extension View {
    func tabFace(selected: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        return self
            .foregroundStyle(selected ? Color.white : Color(white: 0.70))
            .background(selected ? Color.white.opacity(0.12) : .clear, in: shape)
            .overlay(shape.strokeBorder(selected ? Color.white.opacity(0.11) : .clear)
                .allowsHitTesting(false))
    }
}

struct FavoriteTabs: View {
    @ObservedObject var state: WorkspaceState
    let select: (WorkspaceTab) -> Void
    let create: () -> Void
    let close: (Int) -> Void
    let move: (Int, Int) -> Void
    @State private var dropTarget: Int?
    @State private var tabFrames: [Int: CGRect] = [:]
    @GestureState private var draggedTab: Int?

    private func tabBadge(_ icon: String, title: String?) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
            if let title { Text(verbatim: title).font(TabTypography.favoriteLabel).lineLimit(1) }
        }
        .padding(.horizontal, title == nil ? 0 : 8)
        .frame(minWidth: 30, maxWidth: title == nil ? 30 : 148, minHeight: 28)
        .fixedSize(horizontal: true, vertical: false)
        .contentShape(Rectangle())
        .tabFace(selected: title != nil)
    }
    private func favorite(_ tab: WorkspaceTab, _ icon: String, _ label: String) -> some View {
        Button { select(tab) } label: {
            tabBadge(icon, title: state.selected == tab ? label : nil)
        }.help(label).accessibilityLabel(label)
         .accessibilityAddTraits(state.selected == tab ? .isSelected : [])
    }
    private func dragTarget(at point: CGPoint) -> Int? {
        guard let row = tabFrames.values.first,
              (row.minY - 14 ... row.maxY + 14).contains(point.y) else { return nil }
        return tabFrames.min { abs($0.value.midX - point.x) < abs($1.value.midX - point.x) }?.key
    }
    var body: some View {
        HStack(spacing: 5) {
            favorite(.keys, "key", "SSH Keys")
            favorite(.activity, "waveform.path.ecg", "Activity")
            favorite(.automations, "clock.arrow.circlepath", "Automations")
            Divider().frame(height: 20)
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(state.tabs) { tab in
                            HStack(spacing: 0) {
                                HStack(spacing: 6) {
                                    tab.icon(fallback: "terminal.fill", size: 16)
                                        .font(.system(size: 12))
                                        .foregroundStyle(state.selected == .shell(tab.id) ? sessionAccent : Color.secondary)
                                        .accessibilityHidden(true)
                                    Text(tab.compactTitle).font(.system(size: 12, weight: .medium))
                                        .frame(maxWidth: 150, alignment: .leading)
                                        .fixedSize(horizontal: true, vertical: false)
                                    if ShellTabShortcuts.keys.indices.contains(tab.shortcutSlot) {
                                        Text(verbatim: "⌘\(ShellTabShortcuts.keys[tab.shortcutSlot])")
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                    .lineLimit(1).padding(.horizontal, 9).frame(height: 28)
                                    .contentShape(Rectangle())
                                    .onTapGesture { select(.shell(tab.id)) }
                                    .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .named("shellTabs"))
                                        .updating($draggedTab) { _, dragged, _ in dragged = tab.id }
                                        .onChanged { dropTarget = dragTarget(at: $0.location) }
                                        .onEnded { value in
                                            if let target = dragTarget(at: value.location) {
                                                withAnimation(.easeInOut(duration: 0.15)) { move(tab.id, target) }
                                            }
                                        })
                                    .accessibilityAddTraits(.isButton)
                                    .accessibilityAction { select(.shell(tab.id)) }
                                    .help(tab.name + ShellTabShortcuts.hint(at: tab.shortcutSlot))
                                 .accessibilityAddTraits(state.selected == .shell(tab.id) ? .isSelected : [])
                                Button { close(tab.id) } label: { Image(systemName: "xmark").font(.caption2).padding(6) }
                                    .help("Close tab").accessibilityLabel("Close tab")
                            }.tabFace(selected: state.selected == .shell(tab.id))
                             .background(GeometryReader { geometry in
                                 Color.clear.preference(key: ShellTabFramesKey.self,
                                                        value: [tab.id: geometry.frame(in: .named("shellTabs"))])
                             })
                             .opacity(draggedTab == tab.id ? 0.65 : 1)
                             .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(
                                draggedTab != nil && draggedTab != tab.id && dropTarget == tab.id
                                    ? sessionAccent : .clear, lineWidth: 1.5)
                                .allowsHitTesting(false))
                             .id(tab.id)
                        }
                    }.coordinateSpace(name: "shellTabs")
                     .onPreferenceChange(ShellTabFramesKey.self) { tabFrames = $0 }
                }.frame(minWidth: 80).onChange(of: state.selected) { if case let .shell(id) = $0 { proxy.scrollTo(id) } }
            }
            if state.selected == .keys {
                Menu {
                    Button("Generate New Key…") { state.generateKey.send() }
                    Button("Import Public Key…") { state.importKey.send() }
                } label: { Image(systemName: "plus").frame(width: 30, height: 28) }
                    .menuIndicator(.hidden).menuStyle(.borderlessButton).fixedSize()
                    .help("Add SSH key").accessibilityLabel("Add SSH key")
            } else {
                let automation = state.selected == .automations
                Button { if automation { state.addAutomation.send() } else { create() } } label: {
                    Image(systemName: "plus").frame(width: 30, height: 28)
                }.help(automation ? "Add Automation" : "New terminal (⌘T)")
                 .accessibilityLabel(automation ? "Add Automation" : "New terminal")
            }
            favorite(.settings, "gearshape", "Settings")
        }.buttonStyle(.plain).padding(.horizontal, 10).frame(maxWidth: .infinity, maxHeight: .infinity)
         .background(Color(nsColor: state.tabColor))
         .overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.09)).frame(height: 1).allowsHitTesting(false) }
    }
}

enum ActivityPreviewText {
    static func tail(_ rows: [String]) -> String {
        guard let last = rows.lastIndex(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { return "" }
        return rows[max(0, last - 2)...last].joined(separator: "\n")
    }
}

private struct ExpandedActivityCardKey: LayoutValueKey {
    static let defaultValue = false
}

private struct ActivityCardWidthKey: LayoutValueKey {
    static let defaultValue: CGFloat? = nil
}

/// Pack independently sized cards without remounting their borrowed terminal views.
private struct ActivityCardLayout: Layout {
    private let spacing: CGFloat = 12
    private let minimumWidth: CGFloat = 320

    private func positions(_ subviews: Subviews, width: CGFloat) -> (rects: [CGRect], height: CGFloat) {
        guard !subviews.isEmpty else { return ([], 0) }
        let columns = max(1, min(subviews.count, Int((width + spacing) / (minimumWidth + spacing))))
        let cardWidth = (width - CGFloat(columns - 1) * spacing) / CGFloat(columns)
        var rects: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for view in subviews {
            let requestedWidth = view[ActivityCardWidthKey.self]
                ?? (view[ExpandedActivityCardKey.self] ? ActivityPaneSize.defaultWidth(available: width) : cardWidth)
            let itemWidth = ActivityPaneSize.clampedWidth(requestedWidth, available: width)
            if x > 0 && x + itemWidth > width + 0.5 {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            let height = view.sizeThatFits(ProposedViewSize(width: itemWidth, height: nil)).height
            rects.append(CGRect(x: x, y: y, width: itemWidth, height: height))
            rowHeight = max(rowHeight, height)
            x += itemWidth + spacing
        }
        return (rects, y + rowHeight)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = max(1, proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 400)
        return CGSize(width: width, height: positions(subviews, width: width).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (view, rect) in zip(subviews, positions(subviews, width: bounds.width).rects) {
            view.place(at: CGPoint(x: bounds.minX + rect.minX, y: bounds.minY + rect.minY),
                       anchor: .topLeading, proposal: ProposedViewSize(rect.size))
        }
    }
}

struct ActivityPanel: View {
    @ObservedObject var state: WorkspaceState
    let terminalView: (Int) -> NSView?
    let close: (Int) -> Void
    @State private var focusRequest: UInt = 0

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    ActivityCardLayout {
                        ForEach(state.tabs) { tab in
                            let available = max(1, geometry.size.width - 40)
                            let fallback = CGSize(width: ActivityPaneSize.defaultWidth(available: available), height: max(220, min(420, geometry.size.height * 0.65)))
                            let size = state.activityPaneSizes[tab.id]?.fitting(available: available) ?? fallback
                            terminalCard(tab, size: size, available: available)
                                .layoutValue(key: ExpandedActivityCardKey.self, value: state.expandedActivityTerminals.contains(tab.id))
                                .layoutValue(key: ActivityCardWidthKey.self, value: state.expandedActivityTerminals.contains(tab.id) ? state.activityPaneSizes[tab.id]?.width : nil)
                                .id(tab.id)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                .onReceive(state.focusActivityTerminal) { id in
                    guard state.selected == .activity, state.tabs.contains(where: { $0.id == id }) else { return }
                    state.toggleActivityTerminal(id)
                    if state.activityTerminal != nil {
                        focusRequest &+= 1
                        proxy.scrollTo(id, anchor: .top)
                    }
                }
                .onChange(of: state.activityTerminal) { id in
                    if let id { proxy.scrollTo(id, anchor: .top) }
                }
            }.padding(20)
        }
        .onChange(of: state.tabs.map(\.id)) { ids in
            state.expandedActivityTerminals.formIntersection(ids)
            if let active = state.activityTerminal, !ids.contains(active) { state.activityTerminal = nil }
        }
    }

    private func terminalCard(_ tab: TabActivity, size: CGSize, available: CGFloat) -> some View {
        let open = state.expandedActivityTerminals.contains(tab.id)
        let focused = state.activityTerminal == tab.id
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Button {
                    if open { state.collapseActivityTerminal(tab.id) }
                    else { state.expandActivityTerminal(tab.id); focusRequest &+= 1 }
                } label: {
                HStack(spacing: 10) {
                    tab.icon(fallback: tab.busy ? "waveform" : "terminal", size: 20)
                        .foregroundStyle(tab.busy ? sessionAccent : .secondary)
                        .frame(width: 24)
                    HStack(spacing: 8) {
                        Text(tab.name).font(.system(size: 13, weight: .semibold))
                            .lineLimit(1).layoutPriority(1)
                        Text(tab.directory).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle).help(tab.directory)
                    }
                    Spacer(minLength: 4)
                    if !tab.limits.isEmpty {
                        Text(ClaudeLimits.compactSummary(tab.limits))
                            .font(.system(size: 11, weight: .medium)).monospacedDigit()
                            .foregroundStyle(.secondary).lineLimit(1).fixedSize()
                            .help(tab.limits.joined(separator: "\n") + "\n" + tab.status)
                            .accessibilityLabel(tab.limits.joined(separator: ". "))
                    }
                    if ShellTabShortcuts.keys.indices.contains(tab.shortcutSlot) {
                        Text(verbatim: "⌘" + ShellTabShortcuts.keys[tab.shortcutSlot])
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(focused ? sessionAccent : .secondary)
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
                            .help("Toggle terminal in Activity" + ShellTabShortcuts.hint(at: tab.shortcutSlot))
                    }
                    if tab.limits.isEmpty {
                        Text(tab.status).font(.caption)
                            .foregroundStyle(tab.busy ? sessionAccent : .secondary).lineLimit(1)
                    }
                    Image(systemName: open ? "chevron.up" : "chevron.down")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(12).contentShape(Rectangle())
            }.buttonStyle(.plain)
             .help(open ? "Collapse terminal" : "Show terminal in Activity")
             .accessibilityLabel((open ? "Collapse " : "Show ") + tab.name)
             .accessibilityAddTraits(open ? .isSelected : [])
                Button { close(tab.id) } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .medium))
                        .frame(width: 28, height: 28).contentShape(Rectangle())
                }.buttonStyle(.plain)
                 .help("Close terminal").accessibilityLabel("Close " + tab.name)
                 .padding(.trailing, 8)
            }

            if open && state.selected == .activity, let terminal = terminalView(tab.id) {
                Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
                ActivityTerminal(terminal: terminal, focusRequest: focusRequest, isVisible: {
                    state.selected == .activity && state.expandedActivityTerminals.contains(tab.id) && state.tabs.contains { $0.id == tab.id }
                }, wantsFocus: {
                    state.selected == .activity && state.activityTerminal == tab.id && state.expandedActivityTerminals.contains(tab.id)
                })
                    .frame(height: size.height).padding(10)
                    .background(Color(nsColor: state.tabColor))
                    .id(tab.id)
                HStack(spacing: 8) {
                    Button { state.activityPaneSizes.removeValue(forKey: tab.id) } label: {
                        Image(systemName: "arrow.uturn.backward").font(.system(size: 10))
                            .frame(width: 24, height: 22)
                    }.buttonStyle(.plain)
                     .help("Reset terminal size").accessibilityLabel("Reset terminal size")
                    Spacer(minLength: 0)
                    Text("Drag corner to resize").font(.system(size: 10)).foregroundStyle(.secondary)
                    ActivityResizeHandle(size: size, available: available) { newSize in
                        state.activityPaneSizes[tab.id] = newSize
                    }
                }.padding(.leading, 6)
                 .background(Color(nsColor: state.tabColor))

            } else if !open {
                Button { state.expandActivityTerminal(tab.id); focusRequest &+= 1 } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array((tab.preview.isEmpty ? "No output yet." : tab.preview)
                            .components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                            Text(verbatim: line.isEmpty ? " " : line)
                                .lineLimit(1).truncationMode(.tail)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .font(Font(terminalFont(size: 11)))
                    .foregroundStyle(.primary.opacity(0.7))
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading)
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .background(.black.opacity(0.12))
                    .contentShape(Rectangle())
                }.buttonStyle(.plain).help("Show terminal in Activity")
                 .accessibilityLabel("Show " + tab.name)
            }
        }
        .background(Color.white.opacity(open ? 0.055 : 0.025))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(focused ? sessionAccent.opacity(0.6) : open ? .white.opacity(0.2) : .white.opacity(0.08)))
    }
}

/// Keep the gesture origin stable while SwiftUI lays out the resized terminal.
private struct ActivityResizeHandle: View {
    let size: CGSize
    let available: CGFloat
    let resize: (ActivityPaneSize) -> Void
    @State private var dragStart: CGSize?

    var body: some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            .frame(width: 28, height: 24).contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    if dragStart == nil { dragStart = size }
                    resize(ActivityPaneSize.resized(from: dragStart ?? size, translation: value.translation, available: available))
                }
                .onEnded { _ in dragStart = nil })
            .help("Drag to resize terminal width and height")
            .accessibilityLabel("Resize terminal")
            .accessibilityValue("\(Int(size.width)) by \(Int(size.height)) points")
            .accessibilityAdjustableAction { direction in
                let delta: CGFloat = direction == .increment ? 40 : -40
                resize(ActivityPaneSize.resized(from: size, translation: CGSize(width: 0, height: delta), available: available))
            }
    }
}

/// Borrow the existing terminal view so input, scrollback and the PTY stay in the same session.
private struct ActivityTerminal: NSViewRepresentable {
    let terminal: NSView
    let focusRequest: UInt
    let isVisible: () -> Bool
    let wantsFocus: () -> Bool

    final class Container: NSView {
        private var terminal: NSView?
        private var lastFocusRequest: UInt?
        private var pendingFocus: (() -> Bool)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            focusWhenAttached()
        }

        func attach(_ view: NSView, focusRequest: UInt = 0, isVisible: @escaping () -> Bool, wantsFocus: @escaping () -> Bool) {
            guard isVisible() else { detach(); return }
            let attaching = view.superview !== self
            if attaching {
                detach()
                terminal = view
                view.removeFromSuperview()
                view.frame = bounds
                view.autoresizingMask = [.width, .height]
                addSubview(view)
            }
            guard wantsFocus() else {
                lastFocusRequest = nil
                pendingFocus = nil
                return
            }
            guard attaching || lastFocusRequest != focusRequest else { return }
            lastFocusRequest = focusRequest
            pendingFocus = wantsFocus
            focusWhenAttached()
        }

        private func focusWhenAttached() {
            DispatchQueue.main.async { [weak self] in
                guard let self, let requested = self.pendingFocus else { return }
                guard requested(), let terminal = self.terminal, terminal.superview === self else {
                    self.pendingFocus = nil
                    return
                }
                guard let window = self.window else { return }
                if window.makeFirstResponder(terminal) { self.pendingFocus = nil }
            }
        }

        func detach() {
            // Tab navigation may already have moved the view to the main content area.
            if let terminal, terminal.superview === self {
                if let responder = window?.firstResponder as? NSView,
                   responder === terminal || responder.isDescendant(of: terminal) {
                    window?.makeFirstResponder(nil)
                }
                terminal.removeFromSuperview()
            }
            terminal = nil
            lastFocusRequest = nil
            pendingFocus = nil
        }
    }

    func makeNSView(context: Context) -> Container {
        let container = Container()
        container.attach(terminal, focusRequest: focusRequest, isVisible: isVisible, wantsFocus: wantsFocus)
        return container
    }
    func updateNSView(_ view: Container, context: Context) { view.attach(terminal, focusRequest: focusRequest, isVisible: isVisible, wantsFocus: wantsFocus) }
    static func dismantleNSView(_ view: Container, coordinator: ()) { view.detach() }
}
