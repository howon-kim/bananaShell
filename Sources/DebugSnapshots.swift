#if DEBUG
import AppKit
import SwiftUI

/// Debug builds only: `bananaShell --render-marketplace out.png [WIDTHxHEIGHT] [card-id]`
/// (also `--render-extensions … [extension-id]`)
/// draws the Theme Marketplace off screen into a PNG and exits, without starting
/// terminals. Run it with `BANANASHELL_PROFILE` set to keep its files separate;
/// `-key value` arguments set preferences for the render (for example `-powerline YES`).
enum DebugSnapshots {
    @MainActor static func renderIfRequested() {
        let args = CommandLine.arguments
        let modes = ["--render-marketplace", "--render-tabbar", "--render-settings", "--render-prompt-options", "--render-automations", "--render-extensions"]
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
