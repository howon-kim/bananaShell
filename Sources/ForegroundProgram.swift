import Foundation
import Darwin

enum ForegroundProgram {
    static let commands: [String: String] = {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        guard let url = bundle.url(forResource: "commands", withExtension: "json", subdirectory: "ProgramLogos"),
              let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }()

    static let packages = [
        "@anthropic-ai/claude-code": "claude", "@openai/codex": "openai",
        "@google/gemini-cli": "gemini", "@github/copilot": "githubcopilot",
        "@qwen-code/qwen-code": "qwen", "@sourcegraph/amp": "amp",
        "opencode-ai": "opencode", "openclaw": "openclaw", "firebase-tools": "firebase",
        "netlify-cli": "netlify", "@angular/cli": "angularjs", "typescript": "typescript",
        "next": "nextjs", "nuxt": "nuxtjs", "@playwright/test": "playwright"
    ]
    static func nameIcon(_ name: String) -> String? {
        if let known = commands[name.lowercased()] { return known }
        // Homebrew and virtual environments often expose python3.13 instead of python3.
        if name.range(of: #"^python[23](\.[0-9]+)*$"#, options: .regularExpression) != nil { return "python" }
        return nil
    }

    static func pathIcon(_ path: String) -> String? {
        let parts = path.lowercased().split(separator: "/").map(String.init)
        guard let leaf = parts.last else { return nil }
        if let idx = parts.lastIndex(of: "node_modules"), idx + 1 < parts.count {
            let pkg = parts[idx+1]
            if pkg == ".bin" { return nameIcon(leaf) }
            let key = pkg.hasPrefix("@") ? parts.dropFirst(idx+1).prefix(2).joined(separator: "/") : pkg
            return packages[key] ?? nameIcon(key)
        }
        if parts.count >= 3, parts[parts.count-2] == "versions" {
            return nameIcon(parts[parts.count-3].trimmingCharacters(in: CharacterSet(charactersIn: ".")))
        }
        return nameIcon(leaf)
    }

    static func icon(pid: pid_t, name: String?, title: String) -> String? {
        let command = String((name ?? "").lowercased().prefix { !$0.isWhitespace })
        let direct = nameIcon(command)
        let interpreters = ["node", "bun", "deno", "python", "ruby", "perl", "php", "bash", "zsh", "sh"]
        if let direct, !interpreters.contains(direct) { return direct }
        var pathBuffer = [CChar](repeating: 0, count: 4096)
        let path = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count)) > 0 ? String(cString: pathBuffer) : ""
        let native = pathIcon(path)
        if let native, !interpreters.contains(native) { return native }
        let args = arguments(pid)
        if let first = args.first, let cli = pathIcon(first), !interpreters.contains(cli) { return cli }
        if let entry = args.dropFirst().first, !entry.hasPrefix("-"), entry.contains("/") {
            // Only executable scripts and installed packages identify a CLI. A local
            // Python or Node project called "docker" is not evidence of Docker.
            let parent = URL(fileURLWithPath: entry).deletingLastPathComponent().lastPathComponent
            if entry.contains("/node_modules/") || ["bin", "sbin", ".bin"].contains(parent),
               let cli = pathIcon(entry) { return cli }
        }
        if direct == "python", args.dropFirst().first == "-m", args.count >= 3,
           ["pip", "pytest", "flask", "jupyter", "poetry"].contains(args[2]) { return nameIcon(args[2]) }
        if command.first?.isNumber == true, title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "claude code" { return "claude" }
        return direct ?? native
    }

    // KERN_PROCARGS2: argc, executable path, padding, argv, environment.
    // Decode only the launcher and first two arguments; never inspect the environment.
    private static func arguments(_ pid: pid_t) -> [String] {
        var mib = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return [] }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &bytes, &size, nil, 0) == 0, size > 4 else { return [] }
        let argc = Int(bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
        guard argc > 0, var i = bytes[4..<size].firstIndex(of: 0) else { return [] }
        while i < size && bytes[i] == 0 { i += 1 }
        var args: [String] = []
        for _ in 0..<min(argc, 3) {
            guard i < size, let end = bytes[i..<size].firstIndex(of: 0) else { break }
            args.append(String(decoding: bytes[i..<end], as: UTF8.self))
            i = end + 1
        }
        return args
    }
}
