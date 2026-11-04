import AppKit
import SwiftUI

private enum Palette: String, CaseIterable {
    case violet = "\u{bc14}\u{c774}\u{c62c}\u{b81b}", mint = "\u{bbfc}\u{d2b8}", ocean = "\u{c624}\u{c158}"
    var code: Int { switch self { case .violet: return 99; case .mint: return 79; case .ocean: return 75 } }
    var color: Color { switch self { case .violet: return Color(red: 0.53, green: 0.37, blue: 1); case .mint: return .mint; case .ocean: return .cyan } }
}

private enum ThemeLibrary: String, CaseIterable {
    case builtin = "Built-in", posh = "Oh My Posh", starship = "Starship"
    var engine: String { self == .posh ? "oh-my-posh" : "starship" }
    var files: [URL] {
        guard self != .builtin, let folder = PromptSetup.folder else { return [] }
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder.appendingPathComponent(rawValue), includingPropertiesForKeys: nil)) ?? []
        return urls.filter { ["json", "yaml", "toml"].contains($0.pathExtension) }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
    func title(_ url: URL) -> String { url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: ".omp", with: "") }
}

private struct RGB {
    let value: Int
    init?(_ input: String) {
        let digits = input.hasPrefix("#") ? String(input.dropFirst()) : input
        guard digits.utf8.count == 6, digits.allSatisfy({ $0.isHexDigit }), let n = Int(digits, radix: 16) else { return nil }
        value = n
    }
    var hex: String { String(format: "#%06X", value) }
    var color: Color { Color(.sRGB, red: Double(value >> 16) / 255, green: Double(value >> 8 & 255) / 255, blue: Double(value & 255) / 255) }
}

private enum PromptDesign: String, CaseIterable {
    case classic = "Classic", minimal = "Minimal", stacked = "Stacked", ribbon = "Ribbon"

    func prompt(color: String, identity: Bool) -> String {
        let accent = "%F{\(color)}"
        switch self {
        case .classic:
            let prefix = identity ? "%K{0}%F{15} %n@%m %K{\(color)}%F{0}▶" : "%K{\(color)}"
            return prefix + "%F{0} %~ %k" + accent + "▶%f "
        case .ribbon:
            let shade = color == "99" ? "57" : color
            let prefix = identity ? "%K{0}%F{15} %n@%m %K{\(shade)}%F{0}\u{E0B0}" : "%K{\(shade)}"
            return prefix + "%F{0} %~ %k%F{\(shade)}\u{E0B0}%f "
        case .minimal:
            return (identity ? "%F{7}%n@%m · %f" : "") + accent + "%~ ❯%f "
        case .stacked:
            return accent + "╭─ %f" + (identity ? "%F{7}%n@%m %f" : "") + accent + "%~\n╰─❯%f "
        }
    }
}

enum PromptSetup {
    static var folder: URL? {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        return bundle.url(forResource: "PromptSupport", withExtension: nil)
    }

    private static let backgrounds: [String: String] = {
        guard let url = folder?.appendingPathComponent("theme-backgrounds.json"),
              let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }()

    static func background(file: URL?, follow: Bool, accent: NSColor) -> NSColor {
        guard follow else { return shellSurface }
        if let file, let hex = backgrounds[file.lastPathComponent], let rgb = RGB(hex) { return NSColor(rgb.color) }
        let color = accent.usingColorSpace(.sRGB) ?? .systemPurple
        return NSColor(calibratedHue: color.hueComponent, saturation: color.saturationComponent * 0.55,
                       brightness: 0.18, alpha: 1)
    }

    static func background(forShell shell: String) -> NSColor {
        let prefs = UserDefaults.standard
        guard URL(fileURLWithPath: shell).lastPathComponent == "zsh", prefs.bool(forKey: "powerline") else { return shellSurface }
        let library = ThemeLibrary(rawValue: prefs.string(forKey: "themeLibrary") ?? "") ?? .builtin
        let files = library.files
        let file = files.first { $0.lastPathComponent == prefs.string(forKey: "themeFile." + library.rawValue) } ?? files.first
        let palette = Palette(rawValue: prefs.string(forKey: "promptPalette") ?? "") ?? .violet
        let accent = RGB(prefs.string(forKey: "customAccent") ?? "")?.color ?? palette.color
        return background(file: file, follow: prefs.object(forKey: "followThemeBackground") as? Bool ?? true, accent: NSColor(accent))
    }

    static func liveConfiguration() -> String {
        let prefs = UserDefaults.standard
        guard prefs.bool(forKey: "powerline") else { return "off\n" }
        let library = ThemeLibrary(rawValue: prefs.string(forKey: "themeLibrary") ?? "") ?? .builtin
        if library != .builtin {
            let files = library.files
            guard let file = files.first(where: { $0.lastPathComponent == prefs.string(forKey: "themeFile." + library.rawValue) }) ?? files.first else { return "off\n" }
            return library.engine + "\n" + file.path
        }
        let color = Palette(rawValue: prefs.string(forKey: "promptPalette") ?? "") ?? .violet
        let identity = prefs.object(forKey: "promptIdentity") as? Bool ?? true
        let design = PromptDesign(rawValue: prefs.string(forKey: "promptDesign") ?? "") ?? .classic
        let prompt = design.prompt(color: RGB(prefs.string(forKey: "customAccent") ?? "")?.hex ?? String(color.code), identity: identity)
        return design.rawValue + "\n" + prompt
    }
}

struct PromptSettings: View {
    let didChange: () -> Void
    @AppStorage("restoreLastWindow") private var restoreLastWindow = false
    @AppStorage("powerline") private var enabled = false
    @AppStorage("promptPalette") private var palette = Palette.violet.rawValue
    @AppStorage("promptIdentity") private var identity = true
    @AppStorage("promptDesign") private var design = PromptDesign.classic
    @AppStorage("themeLibrary") private var library = ThemeLibrary.builtin
    @AppStorage("customAccent") private var customAccent = ""
    @AppStorage("themeFile.Oh My Posh") private var poshFile = ""
    @AppStorage("themeFile.Starship") private var starshipFile = ""
    @AppStorage("followThemeAccent") private var followThemeAccent = true
    @AppStorage("followThemeBackground") private var followBackground = true
    @State private var search = ""
    @State private var hexDraft = ""

    private let accent = Color.accentColor
    private var tint: Color { RGB(customAccent)?.color ?? (Palette(rawValue: palette) ?? .violet).color }
    private var files: [URL] { library.files }
    private var selectedFile: URL? {
        let name = library == .posh ? poshFile : starshipFile
        return files.first { $0.lastPathComponent == name } ?? files.first
    }
    private var previewName: String {
        guard enabled else { return "Default shell" }
        return selectedFile.map { library.title($0) } ?? design.rawValue
    }
    private var previewSample: String {
        guard enabled else { return "user@mac ~/work % " }
        guard library != .builtin else { return builtInSample(design) }
        return selectedFile.flatMap { ThemeSampleView.samples[$0.lastPathComponent] } ?? "No preview available"
    }
    private var previewBackground: NSColor {
        PromptSetup.background(file: selectedFile, follow: enabled && followBackground, accent: NSColor(tint))
    }

    var body: some View {
        GeometryReader { geometry in
            if geometry.size.width >= 1100 && enabled {
                let inspectorWidth = min(520, max(380, (geometry.size.width - 64) * 0.34))
                VStack(alignment: .leading, spacing: 24) {
                    header
                    HStack(alignment: .top, spacing: 24) {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 24) {
                                preview
                                libraryPicker
                                preferences
                                startup
                                ShortcutSettings()
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.frame(width: inspectorWidth)
                        ScrollView {
                            if library == .builtin {
                                layoutPicker(columns: 2)
                            } else {
                                themeGallery
                            }
                        }.frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                }.padding(20)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        header
                        startup
                        ShortcutSettings()
                        preview
                        if enabled {
                            libraryPicker
                            if library == .builtin {
                                layoutPicker(columns: geometry.size.width >= 760 ? 4 : 2)
                                preferences
                            } else {
                                preferences
                                themeGallery
                            }
                        } else {
                            HStack(spacing: 8) {
                                Image(systemName: "terminal")
                                Text("Enable Custom prompt to choose a layout or explore themes.")
                            }.font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
                }
            }
        }
        .onAppear { hexDraft = customAccent }
        .onChange(of: library) { _ in search = "" }
        .onChange(of: [String(enabled), palette, String(identity), design.rawValue, library.rawValue,
                       customAccent, poshFile, starshipFile, String(followBackground)]) { _ in didChange() }
    }

    private var startup: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Startup")
            preferenceRow("Reopen last window on launch",
                          detail: "Restore window size, tabs, and folders with fresh shells.",
                          value: $restoreLastWindow)
                .settingsSurface(accent: accent)
        }
        .onChange(of: restoreLastWindow) { enabled in
            if !enabled { UserDefaults.standard.removeObject(forKey: "lastWindowSnapshot") }
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Settings").font(.title.bold())
                Text("Startup, shortcuts, appearance & shell prompt").font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Toggle("Custom prompt", isOn: $enabled)
                .font(.callout).toggleStyle(.switch).controlSize(.small).fixedSize()
        }
    }

    private var preview: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "terminal").foregroundStyle(.secondary)
                Text(previewName).font(.system(size: 12, weight: .medium)).lineLimit(1)
                if enabled {
                    Text(library.rawValue).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                Circle().fill(accent).frame(width: 5, height: 5)
                Text("Preview").font(.caption).foregroundStyle(.secondary)
            }.padding(.horizontal, 16).padding(.vertical, 11)
             .background(Color.white.opacity(0.035))
            Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
            let sample = ThemeSampleView(sample: previewSample, background: previewBackground)
            let height = CGFloat(max(4, previewSample.components(separatedBy: "\n").count + 1)) * 18
            GeometryReader { geometry in
                ScrollView(.horizontal) {
                    sample.frame(width: max(geometry.size.width, sample.fittingWidth), height: height)
                        .allowsHitTesting(false)
                }
            }.frame(height: height)
                .padding(18)
                .background(Color(nsColor: previewBackground))
                .accessibilityLabel("Prompt preview: " + previewName)
        }
        .clipShape(RoundedRectangle(cornerRadius: SurfaceRadius.panel))
        .overlay(RoundedRectangle(cornerRadius: SurfaceRadius.panel).strokeBorder(.white.opacity(0.1)))
    }

    private var libraryPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Theme library")
            HStack(spacing: 8) {
                ForEach(ThemeLibrary.allCases, id: \.self) { item in
                    Button { library = item } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Image(systemName: item == .builtin ? "slider.horizontal.3" : item == .posh ? "sparkles" : "star")
                                Spacer(minLength: 0)
                                if library == item { Image(systemName: "checkmark.circle.fill") }
                            }.font(.system(size: 13)).foregroundStyle(library == item ? accent : .secondary)
                            Text(item.rawValue).font(.system(size: 12, weight: .semibold))
                                .lineLimit(1).minimumScaleFactor(0.8)
                            Text(item == .builtin ? "4 layouts" : "\(item.files.count) themes")
                                .font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                         .contentShape(RoundedRectangle(cornerRadius: SurfaceRadius.tile))
                    }.buttonStyle(HoverButtonStyle(cornerRadius: SurfaceRadius.tile))
                     .settingsSurface(selected: library == item, accent: accent)
                     .accessibilityAddTraits(library == item ? .isSelected : [])
                }
            }
        }
    }

    private func layoutPicker(columns: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Prompt layout")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: columns), spacing: 10) {
                ForEach(PromptDesign.allCases, id: \.self) { item in
                    Button { design = item } label: {
                        VStack(alignment: .leading, spacing: 0) {
                            ThemeSampleView(sample: builtInSample(item, compact: columns > 2), background: shellSurface, fontSize: 11)
                                .frame(height: 44).padding(12).background(Color(nsColor: shellSurface))
                                .allowsHitTesting(false).accessibilityHidden(true)
                            HStack {
                                Text(item.rawValue).font(.system(size: 12, weight: .medium))
                                Spacer()
                                if item == design { Image(systemName: "checkmark.circle.fill").foregroundStyle(accent) }
                            }.padding(.horizontal, 12).padding(.vertical, 10)
                        }.contentShape(RoundedRectangle(cornerRadius: SurfaceRadius.tile))
                    }.buttonStyle(HoverButtonStyle(cornerRadius: SurfaceRadius.tile)).settingsSurface(selected: item == design, accent: accent)
                     .accessibilityAddTraits(item == design ? .isSelected : [])
                }
            }
        }
    }

    private var preferences: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle(library == .builtin ? "Personalize" : "Appearance")
            VStack(spacing: 0) {
                if library == .builtin {
                    accentRow
                    Divider().padding(.horizontal, 16)
                    preferenceRow("Show identity", detail: "User and computer name", value: $identity)
                    Divider().padding(.horizontal, 16)
                }
                preferenceRow("Match interface accent", detail: "Use the applied prompt theme’s color for tabs, buttons, and selections.", value: $followThemeAccent)
                Divider().padding(.horizontal, 16)
                preferenceRow("Theme background", detail: "Match the terminal to your prompt", value: $followBackground)
            }.settingsSurface(accent: accent)
        }
    }

    private var accentRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                Text("Accent color").font(.callout)
                Spacer(minLength: 16)
                colorControls
            }
            VStack(alignment: .leading, spacing: 12) {
                Text("Accent color").font(.callout)
                colorControls
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
    }

    private var colorControls: some View {
        HStack(spacing: 10) {
            ForEach(Palette.allCases, id: \.rawValue) { item in
                let selected = customAccent.isEmpty && palette == item.rawValue
                Button { palette = item.rawValue; customAccent = ""; hexDraft = "" } label: {
                    Circle().fill(item.color).frame(width: 22, height: 22)
                        .overlay { if selected { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.black) } }
                        .padding(3).overlay(Circle().strokeBorder(selected ? item.color.opacity(0.65) : .clear))
                }.buttonStyle(HoverButtonStyle(cornerRadius: 14)).help(String(describing: item).capitalized)
                 .accessibilityLabel(String(describing: item).capitalized)
                 .accessibilityAddTraits(selected ? .isSelected : [])
            }
            Divider().frame(height: 18)
            ColorPicker("Custom accent", selection: Binding(get: { tint }, set: { next in
                guard let c = NSColor(next).usingColorSpace(.sRGB) else { return }
                customAccent = String(format: "#%02X%02X%02X", Int((c.redComponent * 255).rounded()),
                                      Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()))
                hexDraft = customAccent
            }), supportsOpacity: false).labelsHidden()
            TextField("#RRGGBB", text: $hexDraft)
                .font(.system(size: 12, design: .monospaced)).textFieldStyle(.roundedBorder).frame(width: 88)
                .accessibilityLabel("Accent hex color")
                .onChange(of: hexDraft) { if let rgb = RGB($0) { customAccent = rgb.hex } }
                .onChange(of: customAccent) { if hexDraft != $0 { hexDraft = $0 } }
        }
    }

    private func preferenceRow(_ title: String, detail: String, value: Binding<Bool>) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Toggle(title, isOn: value).labelsHidden().toggleStyle(.switch).controlSize(.small)
        }.padding(.horizontal, 16).padding(.vertical, 13)
    }

    private var themeGallery: some View {
        let matches = files.filter { search.isEmpty || library.title($0).localizedCaseInsensitiveContains(search) }
        return VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    sectionTitle("Themes")
                    Spacer()
                    themeSearch.frame(width: 220)
                }
                VStack(alignment: .leading, spacing: 10) {
                    sectionTitle("Themes")
                    themeSearch
                }
            }
            Text("Requires " + library.engine + " · Colors and layout are defined by each theme.")
                .font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 12)], spacing: 12) {
                ForEach(matches, id: \.self) { file in themeCard(file) }
            }
            if matches.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").font(.title2)
                    Text("No matching themes").font(.callout)
                    Button("Clear search") { search = "" }.buttonStyle(.borderless)
                }.foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(32)
            }
        }
    }

    private var themeSearch: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search themes", text: $search).textFieldStyle(.plain)
            if !search.isEmpty {
                Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(HoverButtonStyle()).accessibilityLabel("Clear search")
            }
        }.font(.callout).padding(8)
         .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: SurfaceRadius.tab))
         .overlay(RoundedRectangle(cornerRadius: SurfaceRadius.tab).strokeBorder(.white.opacity(0.08)))
    }

    private func themeCard(_ file: URL) -> some View {
        let selected = selectedFile == file
        let background = PromptSetup.background(file: file, follow: followBackground, accent: NSColor(tint))
        return Button {
            if library == .posh { poshFile = file.lastPathComponent }
            else { starshipFile = file.lastPathComponent }
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                Group {
                    if let sample = ThemeSampleView.samples[file.lastPathComponent] {
                        ThemeSampleView(sample: sample, background: background, fontSize: 11)
                            .allowsHitTesting(false).accessibilityHidden(true)
                    } else {
                        Text("No preview available").font(.caption).foregroundStyle(.secondary)
                    }
                }.frame(height: 76).padding(12).frame(maxWidth: .infinity, alignment: .leading)
                 .background(Color(nsColor: background)).clipped()
                HStack {
                    Text(library.title(file)).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Spacer(minLength: 4)
                    if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(accent) }
                }.padding(12)
            }.contentShape(RoundedRectangle(cornerRadius: SurfaceRadius.tile))
        }.buttonStyle(HoverButtonStyle(cornerRadius: SurfaceRadius.tile)).settingsSurface(selected: selected, accent: accent)
         .accessibilityLabel(library.title(file)).accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title).settingsSectionTitle()
    }

    private func builtInSample(_ layout: PromptDesign, compact: Bool = false) -> String {
        let reset = "\u{1b}[0m"
        let name = compact ? "mac" : "user@mac"
        let path = compact ? "~" : "~/work"
        let code = (Palette(rawValue: palette) ?? .violet).code
        let color = RGB(customAccent)
        let fg = color.map { "38;2;\($0.value >> 16);\($0.value >> 8 & 255);\($0.value & 255)" } ?? "38;5;\(code)"
        let bg = color.map { "48;2;\($0.value >> 16);\($0.value >> 8 & 255);\($0.value & 255)" } ?? "48;5;\(layout == .ribbon && code == 99 ? 57 : code)"
        let foreground = "\u{1b}[\(fg)m"
        let background = "\u{1b}[\(bg)m"
        let user = identity ? "\u{1b}[37m\(name) " : ""
        switch layout {
        case .minimal: return (identity ? "\u{1b}[37m\(name) · " : "") + foreground + path + " ❯ " + reset
        case .stacked: return foreground + "╭─ " + user + foreground + path + "\r\n╰─❯ " + reset
        case .classic, .ribbon:
            let tip = layout == .ribbon ? "\u{E0B0}" : "▶"
            let prefix = identity ? "\u{1b}[40;97m \(name) " + background + "\u{1b}[30m" + tip : background
            let end = layout == .ribbon && color == nil && code == 99 ? "\u{1b}[38;5;57m" : foreground
            return prefix + "\u{1b}[30m \(path) " + reset + end + tip + reset + " "
        }
    }
}

// Every AppKit hosting view is a separate SwiftUI root, including the title bar.
struct ThemedRoot<Content: View>: View {
    let content: Content
    @AppStorage("powerline") private var enabled = false
    @AppStorage("followThemeAccent") private var follow = true
    @AppStorage("themeLibrary") private var library = ThemeLibrary.builtin
    @AppStorage("themeFile.Oh My Posh") private var poshFile = ""
    @AppStorage("themeFile.Starship") private var starshipFile = ""
    @AppStorage("promptPalette") private var palette = Palette.violet.rawValue
    @AppStorage("customAccent") private var custom = ""

    private var color: Color {
        guard enabled && follow else { return InterfaceAccent.mint }
        if library == .builtin {
            return RGB(custom)?.color ?? (Palette(rawValue: palette) ?? .violet).color
        }
        let name = library == .posh ? poshFile : starshipFile
        let applied = InterfaceAccent.catalog[name] != nil ? name : library.files.first?.lastPathComponent ?? ""
        return InterfaceAccent.catalog[applied].flatMap(RGB.init)?.color ?? InterfaceAccent.mint
    }

    var body: some View {
        let accent = color
        content.accentColor(accent).tint(accent)
    }
}

private enum InterfaceAccent {
    static let mint = Color(red: 0.46, green: 0.87, blue: 0.76)
    static let catalog: [String: String] = {
        guard let url = PromptSetup.folder?.appendingPathComponent("theme-accents.json"),
              let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }()
}

extension View {
    func settingsSectionTitle() -> some View {
        self.font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
    }

    func settingsSurface(selected: Bool = false, accent: Color = Color.accentColor) -> some View {
        self.background(selected ? accent.opacity(0.065) : Color.white.opacity(0.025))
            .clipShape(RoundedRectangle(cornerRadius: SurfaceRadius.tile))
            .overlay(RoundedRectangle(cornerRadius: SurfaceRadius.tile).strokeBorder(selected ? accent.opacity(0.65) : .white.opacity(0.09)))
    }
}

/// Static ANSI previews keep theme galleries lightweight and never start a shell.
private struct ThemeSampleView: NSViewRepresentable {
    let sample: String
    let background: NSColor
    var fontSize: CGFloat = 13
    static let samples: [String: String] = {
        guard let url = PromptSetup.folder?.appendingPathComponent("preview-samples.json"),
              let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }()

    final class SampleView: NSView {
        var rendered = NSAttributedString()
        var backdrop = NSColor.black
        var previousSample = ""
        var previousSize: CGFloat = 0
        var previousBackground: NSColor?
        override var isFlipped: Bool { true }
        override func draw(_ dirtyRect: NSRect) {
            backdrop.setFill()
            bounds.fill()
            NSGraphicsContext.saveGraphicsState()
            bounds.clip()
            rendered.draw(in: bounds)
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    func makeNSView(context: Context) -> SampleView { SampleView() }
    func updateNSView(_ view: SampleView, context: Context) {
        guard view.previousSample != sample || view.previousSize != fontSize || view.previousBackground != background else { return }
        view.previousSample = sample
        view.previousSize = fontSize
        view.previousBackground = background
        view.backdrop = background
        view.rendered = attributedSample
        view.needsDisplay = true
    }

    var fittingWidth: CGFloat { ceil(attributedSample.size().width) }

    private var attributedSample: NSAttributedString {
        let text = sample.replacingOccurrences(of: "\r\n", with: "\n")
        let raw = text as NSString
        let result = NSMutableAttributedString()
        let sgr = try! NSRegularExpression(pattern: #"\x1b\[([0-9;]*)m"#)
        var foreground = NSColor.white, fill = background
        var bold = false, italic = false, underline = false, inverse = false, dim = false
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byClipping
        paragraph.lineSpacing = 2
        func append(_ range: NSRange) {
            guard range.length > 0 else { return }
            var font = terminalFont(size: fontSize)
            if bold { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
            if italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
            let ink = inverse ? fill : foreground
            result.append(NSAttributedString(string: raw.substring(with: range), attributes: [
                .font: font, .foregroundColor: dim ? ink.withAlphaComponent(0.6) : ink,
                .backgroundColor: inverse ? foreground : fill,
                .underlineStyle: underline ? NSUnderlineStyle.single.rawValue : 0,
                .paragraphStyle: paragraph
            ]))
        }
        var offset = 0
        for match in sgr.matches(in: text, range: NSRange(location: 0, length: raw.length)) {
            append(NSRange(location: offset, length: match.range.location - offset))
            let values = raw.substring(with: match.range(at: 1)).split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
            var index = 0
            while index < values.count {
                let code = values[index]
                switch code {
                case 0: foreground = .white; fill = background; bold = false; italic = false; underline = false; inverse = false; dim = false
                case 1: bold = true
                case 2: dim = true
                case 3: italic = true
                case 4: underline = true
                case 7: inverse = true
                case 22: bold = false; dim = false
                case 23: italic = false
                case 24: underline = false
                case 27: inverse = false
                case 30...37: foreground = ansiColor(code - 30)
                case 40...47: fill = ansiColor(code - 40)
                case 90...97: foreground = ansiColor(code - 90 + 8)
                case 100...107: fill = ansiColor(code - 100 + 8)
                case 39: foreground = .white
                case 49: fill = background
                case 38, 48:
                    var color: NSColor?
                    if index + 2 < values.count, values[index + 1] == 5 {
                        color = ansiColor(values[index + 2]); index += 2
                    } else if index + 4 < values.count, values[index + 1] == 2 {
                        let rgb = values[(index + 2)...(index + 4)].map { CGFloat(max(0, min(255, $0))) / 255 }
                        color = NSColor(srgbRed: rgb[0], green: rgb[1], blue: rgb[2], alpha: 1); index += 4
                    }
                    if let color { if code == 38 { foreground = color } else { fill = color } }
                default: break
                }
                index += 1
            }
            offset = NSMaxRange(match.range)
        }
        append(NSRange(location: offset, length: raw.length - offset))
        return result
    }

    private func ansiColor(_ value: Int) -> NSColor {
        let value = max(0, min(255, value))
        if value < 16 {
            let colors = [0x000000, 0xcd0000, 0x00cd00, 0xcdcd00, 0x0000ee, 0xcd00cd, 0x00cdcd, 0xe5e5e5,
                          0x7f7f7f, 0xff0000, 0x00ff00, 0xffff00, 0x5c5cff, 0xff00ff, 0x00ffff, 0xffffff]
            let rgb = colors[value]
            return NSColor(srgbRed: CGFloat(rgb >> 16) / 255, green: CGFloat(rgb >> 8 & 255) / 255, blue: CGFloat(rgb & 255) / 255, alpha: 1)
        }
        if value >= 232 {
            let gray = CGFloat(8 + (value - 232) * 10) / 255
            return NSColor(srgbRed: gray, green: gray, blue: gray, alpha: 1)
        }
        let levels: [CGFloat] = [0, 95, 135, 175, 215, 255]
        let cube = value - 16
        return NSColor(srgbRed: levels[cube / 36] / 255, green: levels[cube / 6 % 6] / 255, blue: levels[cube % 6] / 255, alpha: 1)
    }
}

// Keep letter preferences from earlier versions; missing modifiers default to Command.
final class CreationKeys: ObservableObject {
    static let shared = CreationKeys()
    static let actions = ["Group", "Page", "Terminal"]
    static let defaults = ["Group": "g", "Page": "p", "Terminal": "t"]
    @Published private var overrides = UserDefaults.standard.dictionary(forKey: "creationCommandLetters") as? [String: String] ?? [:]
    @Published private var modifiers = UserDefaults.standard.dictionary(forKey: "creationCommandModifiers") as? [String: String] ?? [:]

    func key(_ action: String) -> String { overrides[action] ?? Self.defaults[action]! }
    func modifier(_ action: String) -> NavigationModifier { modifiers[action].flatMap(NavigationModifier.init) ?? .command }
    var isDefault: Bool { Self.actions.allSatisfy { key($0) == Self.defaults[$0] && modifier($0) == .command } }
    func set(_ letter: String, modifier: NavigationModifier, for action: String) -> String? {
        if modifier == .command && "acvwxzqhm".contains(letter) { return "That shortcut is reserved for editing or window controls." }
        if Self.actions.contains(where: { $0 != action && key($0) == letter && self.modifier($0) == modifier }) {
            return "Another creation action already uses that shortcut."
        }
        overrides[action] = letter
        modifiers[action] = modifier.rawValue
        apply()
        return nil
    }
    func reset() { overrides = [:]; modifiers = [:]; apply() }
    private func apply() {
        UserDefaults.standard.set(overrides, forKey: "creationCommandLetters")
        UserDefaults.standard.set(modifiers, forKey: "creationCommandModifiers")
        let menu = NSApp.mainMenu?.item(withTitle: "Shell")?.submenu
        for action in Self.actions {
            let item = menu?.item(withTitle: "New " + action)
            item?.keyEquivalent = key(action)
            item?.keyEquivalentModifierMask = modifier(action).flags
        }
    }
}

private struct ShortcutSettings: View {
    @ObservedObject private var creation = CreationKeys.shared
    @ObservedObject private var navigation = NavigationKeys.shared
    private let keyWidth: CGFloat = 80

    private enum Column { case create, select }
    private struct Target: Equatable { let scope: ShortcutScope; let column: Column }
    @State private var recording: Target?
    @State private var monitor: Any?
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Keyboard shortcuts").settingsSectionTitle()
                Spacer()
                Button("Restore defaults") { stop(); creation.reset(); navigation.reset() }
                    .controlSize(.small)
                    .disabled(navigation.isDefault && creation.isDefault)
            }
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Text("Create").frame(width: keyWidth)
                    Text("Select").frame(width: keyWidth)
                }
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.vertical, 8)
                ForEach(ShortcutScope.allCases, id: \.self) { scope in
                    Divider()
                    HStack {
                        Image(systemName: scope.icon).foregroundStyle(Color.accentColor).frame(width: 20)
                        Text(scope.rawValue).font(.callout)
                        Spacer(minLength: 4)
                        let name = scope.rawValue
                        keycap(creation.modifier(name).symbol + creation.key(name).uppercased(), Target(scope: scope, column: .create))
                        keycap(navigation.modifier(scope).symbol + " 1–0", Target(scope: scope, column: .select))
                    }
                    .padding(.horizontal, 12).padding(.vertical, 7)
                }
                Divider()
                Text(message ?? (recording == nil ? "Click a keycap, then press your shortcut." : "Press ⌘, ⌥ or ⌃ with " + (recording?.column == .create ? "a letter." : "a number. Shared modifiers swap rows.") + " Esc cancels."))
                    .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }.settingsSurface()
        }
        .onDisappear { stop() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in stop() }
    }

    private func keycap(_ value: String, _ target: Target) -> some View {
        let active = recording == target
        return Button {
            if active { stop() } else { start(target) }
        } label: {
            Text(verbatim: active ? "Press keys…" : value)
                .font(TabTypography.suite(size: 12, relativeTo: .callout))
                .foregroundStyle(active ? Color.accentColor : Color.primary)
                .frame(width: keyWidth, height: 26, alignment: .center)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: SurfaceRadius.control))
                .overlay(RoundedRectangle(cornerRadius: SurfaceRadius.control).strokeBorder(active ? Color.accentColor : .clear))
        }
        .buttonStyle(HoverButtonStyle())
        .accessibilityLabel((target.column == .create ? "Create " : "Select ") + target.scope.rawValue + " shortcut")
        .accessibilityValue(active ? "Recording" : value)
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = nil
        message = nil
    }

    private func start(_ target: Target) {
        stop()
        recording = target
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { event in
            guard event.type == .keyDown else { stop(); return event }
            if event.keyCode == 53 { stop(); return nil }
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard let modifier = NavigationModifier.allCases.first(where: { $0.flags == flags }) else {
                message = "Use one modifier: ⌘, ⌥ or ⌃. Esc cancels."
                return nil
            }
            switch target.column {
            case .select:
                guard ShellTabShortcuts.keyCodes.prefix(10).contains(event.keyCode) else {
                    message = "Press the modifier with a number from the top row."
                    return nil
                }
                navigation.assign(modifier, to: target.scope)
            case .create:
                guard let letter = event.characters(byApplyingModifiers: [])?.lowercased(), letter.count == 1,
                      letter.first?.isASCII == true, letter.first?.isLetter == true else {
                    message = "Press the modifier with a letter (A–Z)."
                    return nil
                }
                if let error = creation.set(letter, modifier: modifier, for: target.scope.rawValue) {
                    message = error
                    return nil
                }
            }
            stop()
            return nil
        }
    }
}
