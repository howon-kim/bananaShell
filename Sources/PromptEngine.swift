import Foundation

enum PromptEngine: String, Sendable {
    case starship, posh = "oh-my-posh"
    var title: String { self == .starship ? "Starship" : "Oh My Posh" }
}

struct PromptEngineTools: Sendable {
    let directories: [URL]

    init(directories: [URL]? = nil) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.directories = directories ?? (
            (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").filter { $0.hasPrefix("/") }.map { URL(fileURLWithPath: String($0)) }
            + [URL(fileURLWithPath: "/opt/homebrew/bin"), URL(fileURLWithPath: "/usr/local/bin"),
               home.appendingPathComponent(".local/bin"), home.appendingPathComponent(".cargo/bin"), URL(fileURLWithPath: "/opt/local/bin")])
    }

    func executable(_ name: String, preferred: String? = nil) -> URL? {
        var candidates = directories.map { $0.appendingPathComponent(name) }
        if let preferred, preferred.hasPrefix("/"), URL(fileURLWithPath: preferred).lastPathComponent == name {
            candidates.insert(URL(fileURLWithPath: preferred), at: 0)
        }
        return candidates.first { url in
            var directory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory)
                && !directory.boolValue && FileManager.default.isExecutableFile(atPath: url.path)
        }
    }

    // Only the enum's fixed formula names reach Homebrew. Paths are positional
    // arguments, never interpolated into shell code. The result is published
    // only after both installation and the executable's version check succeed.
    static let installationScript = #"""
    set -e
    engine=$1
    brew=$2
    result=$3
    case "$engine" in starship|oh-my-posh) ;; *) exit 64 ;; esac
    if [ -z "$brew" ]; then
      work=$(/usr/bin/mktemp -d)
      trap '/bin/rm -rf "$work"' EXIT
      /usr/bin/curl --fail --location --proto '=https' --tlsv1.2 --connect-timeout 15 --max-time 120 \
        --output "$work/install.sh" https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh
      /bin/bash "$work/install.sh"
      if [ -x /opt/homebrew/bin/brew ]; then brew=/opt/homebrew/bin/brew
      elif [ -x /usr/local/bin/brew ]; then brew=/usr/local/bin/brew
      else printf '\nHomebrew could not be found after installation.\n'; exit 1; fi
    fi
    export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1
    export PATH="${brew%/*}:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
    "$brew" install --formula "$engine"
    prefix=$("$brew" --prefix)
    binary="$prefix/bin/$engine"
    if [ ! -x "$binary" ]; then printf '\nThe installed prompt executable could not be found.\n'; exit 1; fi
    "$binary" --version
    printf '%s' "$binary" > "$result"
    """#
}
