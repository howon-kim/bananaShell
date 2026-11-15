// swiftc -parse-as-library Sources/PromptEngine.swift Tests/PromptEngineChecks.swift -o /tmp/banana-prompt-engine-checks
// Uses fake Homebrew and prompt executables in a temporary folder. No network or real installations.
import Foundation

@main enum PromptEngineChecks {
    static func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try value() else { throw NSError(domain: "PromptEngineChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("banana prompt checks " + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }
        let bin = root.appendingPathComponent("brew location/bin"), prefix = root.appendingPathComponent("installed prefix")
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        let brew = bin.appendingPathComponent("brew"), result = root.appendingPathComponent("engine-path")
        let fake = #"""
        #!/bin/bash
        set -e
        case "$1" in
          install)
            [ "$2" = --formula ] || exit 65
            [ "$TEST_MODE" != brew-failure ] || exit 17
            /bin/mkdir -p "$TEST_PREFIX/bin"
            if [ "$TEST_MODE" = version-failure ]; then
              printf '#!/bin/bash\nexit 23\n' > "$TEST_PREFIX/bin/$3"
            else
              printf '#!/bin/bash\nprintf "test version\\n"\n' > "$TEST_PREFIX/bin/$3"
            fi
            /bin/chmod 700 "$TEST_PREFIX/bin/$3" ;;
          --prefix) printf '%s' "$TEST_PREFIX" ;;
          *) exit 66 ;;
        esac
        """#
        try fake.write(to: brew, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: brew.path)
        let tools = PromptEngineTools(directories: [bin, prefix.appendingPathComponent("bin")])
        try check(tools.executable("brew") == brew, "Homebrew detection failed")
        try check(tools.executable("starship") == nil, "Missing engine was considered installed")
        try check(PromptEngineTools(directories: []).executable("brew") == nil, "Missing Homebrew detection failed")
        func run(_ engine: String, mode: String = "success") throws -> Int32 {
            try? fm.removeItem(at: result)
            let task = Process(), output = Pipe()
            task.executableURL = URL(fileURLWithPath: "/bin/bash")
            task.arguments = ["--noprofile", "--norc", "-c", PromptEngineTools.installationScript, "checks", engine, brew.path, result.path]
            var env = ProcessInfo.processInfo.environment
            env["TEST_MODE"] = mode; env["TEST_PREFIX"] = prefix.path
            task.environment = env; task.standardOutput = output; task.standardError = output
            try task.run()
            _ = output.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            return task.terminationStatus
        }
        for engine in [PromptEngine.starship, .posh] {
            try check(run(engine.rawValue) == 0, "Engine installation failed")
            let path = try String(contentsOf: result, encoding: .utf8)
            try check(path == prefix.appendingPathComponent("bin/" + engine.rawValue).path, "Installed path did not survive spaces")
            try check(tools.executable(engine.rawValue, preferred: path)?.path == path, "Installed engine was not discoverable")
        }
        try check(run("starship", mode: "brew-failure") == 17, "Homebrew failure was ignored")
        try check(!fm.fileExists(atPath: result.path), "Homebrew failure published a success result")
        try check(run("starship", mode: "version-failure") == 23, "Unusable engine was accepted")
        try check(!fm.fileExists(atPath: result.path), "Version failure published a success result")
        try check(run("starship; touch SHOULD_NOT_EXIST") == 64, "Unrecognized formula was accepted")
        try check(!fm.fileExists(atPath: result.path), "Invalid formula published a success result")
        let directory = bin.appendingPathComponent("not-an-executable")
        try fm.createDirectory(at: directory, withIntermediateDirectories: false)
        try check(tools.executable("not-an-executable") == nil, "Directory was accepted as an executable")
        let installed = prefix.appendingPathComponent("bin/oh-my-posh")
        try check(PromptEngineTools(directories: []).executable("oh-my-posh", preferred: installed.path) == installed, "Remembered custom install location was lost")
        print("Prompt engine checks passed: both engines, detection, paths with spaces, install failures, version verification and formula allowlist.")
    }
}
