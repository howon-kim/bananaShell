import Combine
import SwiftUI
import AppKit

struct TabActivity: Identifiable, Equatable {
    let id: Int
    let name: String
    let status: String
    let directory: String
    var compactTitle: String {
        var path = name[...]
        if let colon = path.firstIndex(of: ":"), path[..<colon].contains("@") {
            path = path[path.index(after: colon)...]
        }
        guard path == "~" || path.hasPrefix("~/") || path.hasPrefix("/") else { return name }
        return path.split(separator: "/").last.map(String.init) ?? "/"
    }
    let busy: Bool
}

final class WorkspaceState: ObservableObject {
    @Published var tabColor = shellSurface
    let addAutomation = PassthroughSubject<Void, Never>()
    let generateKey = PassthroughSubject<Void, Never>()
    let importKey = PassthroughSubject<Void, Never>()
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
                        ForEach(Array(state.tabs.enumerated()), id: \.element.id) { index, tab in
                            HStack(spacing: 0) {
                                HStack(spacing: 6) {
                                    Image(systemName: "terminal.fill")
                                        .font(.system(size: 12))
                                        .foregroundStyle(state.selected == .shell(tab.id) ? sessionAccent : Color.secondary)
                                        .accessibilityHidden(true)
                                    Text(tab.compactTitle).font(.system(size: 12, weight: .medium))
                                        .frame(maxWidth: 150, alignment: .leading)
                                        .fixedSize(horizontal: true, vertical: false)
                                    if ShellTabShortcuts.keys.indices.contains(index) {
                                        Text(verbatim: "⌘\(ShellTabShortcuts.keys[index])")
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
                                    .help(tab.name + ShellTabShortcuts.hint(at: index))
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

struct ActivityPanel: View {
    @ObservedObject var state: WorkspaceState
    let current: Int
    let activate: (Int) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Activity").font(.title2.bold())
            Text("Open Terminals (\(state.tabs.count))").font(.headline)
            terminalList
        }.padding(14)
    }
    private var terminalList: some View {
            ScrollView {
                VStack(spacing: 7) {
                    ForEach(state.tabs) { tab in
                        Button { activate(tab.id) } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                HStack { Image(systemName: tab.busy ? "waveform" : "terminal"); Text(tab.name).lineLimit(1) }
                                Text(tab.status).font(.callout).foregroundStyle(tab.busy ? Color.mint : .secondary)
                                Text(tab.directory).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
                             .background(Color.white.opacity(current == tab.id ? 0.11 : 0.035), in: RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.plain)
                    }
                }
            }
    }
}
