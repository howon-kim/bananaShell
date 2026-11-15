import AppKit
import Darwin
import SwiftUI
import SwiftTerm

@MainActor
final class PromptEngineInstallation: NSObject, ObservableObject, LocalProcessTerminalViewDelegate {
    let engine: PromptEngine
    let tools: PromptEngineTools
    let terminal = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 630, height: 290))
    @Published private(set) var running = false
    @Published private(set) var started = false
    @Published private(set) var failure: String?
    private var cancelled = false
    private var work: URL?
    private var applied: ((URL) -> Void)?
    var needsHomebrew: Bool { tools.executable("brew") == nil }

    init(engine: PromptEngine, tools: PromptEngineTools) {
        self.engine = engine; self.tools = tools
        super.init()
        terminal.font = terminalFont(size: 12)
        terminal.lineSpacing = 1.15
        terminal.nativeBackgroundColor = shellSurface
        terminal.nativeForegroundColor = NSColor(white: 0.93, alpha: 1)
        terminal.processDelegate = self
        terminal.setAccessibilityLabel("Prompt engine installation terminal")
    }

    func start(applied: @escaping (URL) -> Void) {
        guard !running else { return }
        self.applied = applied
        cancelled = false; failure = nil; started = true
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("banana-prompt-install-" + UUID().uuidString)
        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        catch { failure = error.localizedDescription; return }
        work = folder
        running = true
        terminal.feed(text: "\r\nInstalling \(engine.title)…\r\n")
        terminal.startProcess(executable: "/bin/bash", args: ["--noprofile", "--norc", "-c", PromptEngineTools.installationScript, "banana-prompt-install",
                              engine.rawValue, tools.executable("brew")?.path ?? "", folder.appendingPathComponent("engine-path").path],
                              environment: Terminal.getEnvironmentVariables(), currentDirectory: folder.path)
        terminal.window?.makeFirstResponder(terminal)
    }

    func stop() {
        applied = nil; cancelled = true
        if running {
            let pid = terminal.process.shellPid
            // The installer owns this PTY session. Stop its child installers too.
            if pid > 0, getpgid(pid) == pid { kill(-pid, SIGTERM) }
            terminal.terminate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, self.running, self.cancelled, self.terminal.process.shellPid == pid,
                      pid > 0, getpgid(pid) == pid else { return }
                kill(-pid, SIGKILL)
            }
        }
    }

    private func cleanup() {
        if let work { try? FileManager.default.removeItem(at: work) }
        work = nil; applied = nil
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        guard running else { return }
        running = false
        defer { cleanup() }
        guard !cancelled else { failure = "Installation stopped. Your previous theme is unchanged."; return }
        guard exitCode == 0, let work,
              let path = try? String(contentsOf: work.appendingPathComponent("engine-path"), encoding: .utf8),
              let binary = tools.executable(engine.rawValue, preferred: path) else {
            failure = "Installation did not finish successfully. Check the terminal above and try again. Your previous theme is unchanged."
            return
        }
        applied?(binary)
    }

    func processFailedToStart(source: TerminalView, error: LocalProcessError) {
        running = false
        failure = "Could not start the installer: \(error)"
        cleanup()
    }
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
}

struct PromptEngineInstallView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var installation: PromptEngineInstallation
    let theme: String
    let applied: (URL) -> Void

    init(engine: PromptEngine, theme: String, tools: PromptEngineTools, applied: @escaping (URL) -> Void) {
        _installation = StateObject(wrappedValue: PromptEngineInstallation(engine: engine, tools: tools))
        self.theme = theme; self.applied = applied
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "arrow.down.circle").font(.system(size: 28)).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Install " + installation.engine.title).font(.system(size: 21, weight: .semibold))
                    Text("Required to apply “" + theme + "”.").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }.padding(24)
            Divider()
            VStack(alignment: .leading, spacing: 16) {
                Text(installation.needsHomebrew
                     ? "Homebrew will be installed first, followed by \(installation.engine.title). Enter your administrator password in the terminal if requested. Your selected theme will be applied when installation finishes."
                     : "Install \(installation.engine.title) with Homebrew, then automatically apply your selected theme.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Label(theme, systemImage: "paintpalette").font(.callout.weight(.medium))
                    .frame(maxWidth: .infinity, alignment: .leading).padding(14).settingsSurface()
                if installation.started {
                    InstallationTerminal(terminal: installation.terminal).frame(height: 290)
                        .onAppear { installation.terminal.window?.makeFirstResponder(installation.terminal) }
                        .clipShape(RoundedRectangle(cornerRadius: SurfaceRadius.tile))
                        .overlay(RoundedRectangle(cornerRadius: SurfaceRadius.tile).strokeBorder(.white.opacity(0.1)))
                }
                if let failure = installation.failure { Text(failure).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            }.padding(24)
            Divider()
            HStack {
                if installation.running { ProgressView().controlSize(.small); Text("Installing…").font(.callout).foregroundStyle(.secondary) }
                Spacer()
                if installation.running {
                    Button("Stop") { installation.stop() }
                } else {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button(installation.started ? "Retry" : "Install") { installation.start(applied: applied) }
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                }
            }.padding(.horizontal, 24).padding(.vertical, 16)
        }.frame(width: 680)
         .interactiveDismissDisabled(installation.running)
         .onDisappear { installation.stop() }
    }

    private struct InstallationTerminal: NSViewRepresentable {
        let terminal: LocalProcessTerminalView
        func makeNSView(context: Context) -> LocalProcessTerminalView { terminal }
        func updateNSView(_ view: LocalProcessTerminalView, context: Context) {}
    }
}
