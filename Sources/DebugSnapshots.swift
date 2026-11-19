#if DEBUG
import AppKit
import SwiftUI
import SwiftTerm

/// Debug builds only: `bananaShell --render-marketplace out.png [WIDTHxHEIGHT] [card-id]`
/// (also `--render-extensions … [extension-id]`)
/// draws the Theme Marketplace off screen into a PNG and exits, without starting
/// terminals. Run it with `BANANASHELL_PROFILE` set to keep its files separate;
/// `-key value` arguments set preferences for the render (for example `-powerline YES`).
enum DebugSnapshots {
    @MainActor static func renderIfRequested() {
        let args = CommandLine.arguments
        // `--attach-dump tmux socket config session COLSxROWS seconds`: attaches a headless
        // SwiftTerm as a tmux client for the given time, then prints its visible screen.
        if let flag = args.firstIndex(of: "--attach-dump"), args.count > flag + 6 {
            let size = args[flag + 5].split(separator: "x").compactMap { Int($0) }
            let seconds = Double(args[flag + 6]) ?? 10
            let headless = HeadlessTerminal(queue: DispatchQueue(label: "attach"),
                                            options: SwiftTerm.TerminalOptions(cols: size[0], rows: size[1]),
                                            directDelivery: true) { _ in }
            headless.process.startProcess(executable: args[flag + 1],
                                          args: ["-u", "-L", args[flag + 2], "-f", args[flag + 3], "attach", "-t", args[flag + 4]],
                                          environment: ["TERM=xterm-256color", "LANG=en_US.UTF-8", "HOME=" + NSHomeDirectory()])
            // Optional resize schedule: "100x40@4,88x32@6.5" resizes the client like the app does.
            var elapsed = 0.0
            var finalRows = size[1]
            if args.count > flag + 7 {
                for step in args[flag + 7].split(separator: ",") {
                    let parts = step.split(separator: "@")
                    let dims = parts[0].split(separator: "x").compactMap { Int($0) }
                    let at = Double(parts[1]) ?? elapsed
                    Thread.sleep(forTimeInterval: max(0, at - elapsed)); elapsed = at
                    headless.terminal.terminalLock.withLock { headless.terminal.resize(cols: dims[0], rows: dims[1]) }
                    var ws = headless.getWindowSize()
                    _ = headless.process.updateWindowSize(&ws)
                    finalRows = dims[1]
                }
            }
            Thread.sleep(forTimeInterval: max(0, seconds - elapsed))
            let terminal = headless.terminal!
            for row in 0..<finalRows {
                print(terminal.getLine(row: row)?.translateToString(trimRight: true, skipNullCellsFollowingWide: true) ?? "")
            }
            exit(0)
        }
        // `--terminal-widths file`: prints how many columns SwiftTerm advances for each line of the file.
        if let flag = args.firstIndex(of: "--terminal-widths"), args.indices.contains(flag + 1),
           let data = FileManager.default.contents(atPath: args[flag + 1]) {
            final class Sink: SwiftTerm.TerminalDelegate { func send(source: SwiftTerm.Terminal, data: ArraySlice<UInt8>) {} }
            let sink = Sink()
            let terminal = SwiftTerm.Terminal(delegate: sink, options: SwiftTerm.TerminalOptions(cols: 120, rows: 5))
            for item in String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true) {
                terminal.feed(text: "\u{1b}[H\u{1b}[2J" + item)
                print("\(terminal.getCursorLocation().x)\t\(item)")
            }
            exit(0)
        }
        let modes = ["--render-marketplace", "--render-tabbar", "--render-settings", "--render-prompt-options", "--render-automations", "--render-extensions", "--render-terminal"]
        guard let flag = args.firstIndex(where: modes.contains), args.indices.contains(flag + 1) else { return }
        let mode = args[flag]
        let tabBar = mode == "--render-tabbar"
        let output = URL(fileURLWithPath: args[flag + 1])
        var size = NSSize(width: 1280, height: 860)
        if args.indices.contains(flag + 2) {
            let parts = args[flag + 2].split(separator: "x").compactMap { Double($0) }
            if parts.count == 2 { size = NSSize(width: parts[0], height: parts[1]) }
        }
        let selection = args.indices.contains(flag + 3) ? args[flag + 3] : nil
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let host: NSView
        if tabBar {
            // A window's group bar with three groups; the last argument picks the selected tab.
            let state = WorkspaceState()
            state.activityBoards.add()
            state.activityBoards.add()
            state.selected = ["keys": .keys, "automations": .automations, "themes": .themes, "settings": .settings][selection ?? ""] ?? .activity
            host = NSHostingView(rootView: ThemedRoot(content: FavoriteTabs(state: state, select: { _ in })
                .frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(nsColor: shellSurface))))
        } else if mode == "--render-settings" {
            host = NSHostingView(rootView: ThemedRoot(content: PromptSettings(initialSection: selection, didChange: {})
                .background(Color(nsColor: shellSurface))))
        } else if mode == "--render-automations" {
            host = NSHostingView(rootView: ThemedRoot(content: AutomationPanel()
                .background(Color(nsColor: shellSurface))))
        } else if mode == "--render-terminal" {
            // Feeds a captured `tmux capture-pane -e` file (the last argument) into a
            // terminal configured like a zsh tab, to check how output is drawn.
            let terminal = ComposingProcessTerminalView(frame: NSRect(origin: .zero, size: size))
            terminal.font = terminalFont(size: 14)
            terminal.lineSpacing = 1.15
            terminal.nativeBackgroundColor = PromptSetup.background(forShell: "/bin/zsh")
            terminal.nativeForegroundColor = NSColor(white: 0.93, alpha: 1)
            if let path = selection, let data = FileManager.default.contents(atPath: path) {
                let text = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\n", with: "\r\n")
                terminal.feed(text: text)
            }
            host = terminal
        } else if mode == "--render-extensions" {
            host = NSHostingView(rootView: ThemedRoot(content: ExtensionMarketplaceView(initialSelection: selection)))
        } else if mode == "--render-prompt-options" {
            host = NSHostingView(rootView: ThemedRoot(content: PromptOptionsView(changed: {}, turnOn: {})
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).background(Color(white: 0.17))))
        } else {
            host = NSHostingView(rootView: ThemedRoot(content: ThemeMarketplaceView(initialSelection: selection)))
        }
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        // Composited by the window server like any window, but kept below the
        // desktop picture so it never shows; only this process's window is read.
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
        window.setFrameOrigin(NSScreen.main?.visibleFrame.origin ?? .zero)
        window.orderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(2.5))
        typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW),
              let symbol = dlsym(handle, "CGWindowListCreateImage"),
              let image = unsafeBitCast(symbol, to: Capture.self)(.null, 1 << 3, UInt32(window.windowNumber), 1 << 0)?
                .takeRetainedValue() else { exit(1) }
        let rep = NSBitmapImageRep(cgImage: image)
        do { try rep.representation(using: .png, properties: [:])?.write(to: output) } catch { exit(1) }
        exit(0)
    }
}
#endif
