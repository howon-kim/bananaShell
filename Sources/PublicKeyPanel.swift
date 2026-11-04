import Combine
import SwiftUI
import AppKit
import CryptoKit
import UniformTypeIdentifiers
import Darwin

struct PublicIdentity: Identifiable {
    let url: URL
    let algorithm: String
    let publicLine: String
    let digest: [UInt8]
    var id: URL { url }
    var fingerprint: String { "SHA256:" + Data(digest).base64EncodedString().replacingOccurrences(of: "=", with: "") }
    var filename: String { url.lastPathComponent }

    init(_ url: URL) throws {
        let meta = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        let invalid = NSError(domain: "bananaShell.keys", code: 1, userInfo: [NSLocalizedDescriptionKey: "Choose a single OpenSSH public key (.pub)."])
        guard url.pathExtension.lowercased() == "pub", meta.isRegularFile == true, meta.isSymbolicLink != true,
              (meta.fileSize ?? Int.max) < 512 * 1024 else { throw invalid }
        let lines = try String(contentsOf: url, encoding: .utf8).split(whereSeparator: \.isNewline)
        guard lines.count == 1 else { throw invalid }
        let parts = lines[0].split(maxSplits: 2, whereSeparator: \.isWhitespace)
        guard parts.count >= 2, ["ssh-", "ecdsa-", "sk-"].contains(where: { parts[0].hasPrefix($0) }),
              let blob = Data(base64Encoded: String(parts[1])), blob.count > 4 else { throw invalid }
        let size = blob.prefix(4).reduce(0) { $0 * 256 + Int($1) }
        guard size == parts[0].utf8.count, blob.count > size + 4,
              blob.dropFirst(4).prefix(size).elementsEqual(parts[0].utf8) else { throw invalid }
        self.url = url
        let type = String(parts[0])
        algorithm = (type.hasPrefix("ssh-") ? String(type.dropFirst(4)) : type).uppercased()
        publicLine = String(lines[0])
        digest = Array(SHA256.hash(data: blob))
    }
}

private struct KeyMark: View {
    let key: PublicIdentity
    var body: some View {
        let ink = Color(hue: Double(key.digest[15]) / 255, saturation: 0.46, brightness: 0.9)
        Canvas { context, size in
            let cell = min(size.width, size.height) / 7
            for row in 0..<5 {
                for col in 0..<5 where key.digest[row * 3 + min(col, 4-col)] & 1 == 1 {
                    let rect = CGRect(x: CGFloat(col + 1) * cell, y: CGFloat(row + 1) * cell, width: cell, height: cell)
                    context.fill(Path(roundedRect: rect, cornerRadius: cell * 0.14), with: .color(ink))
                }
            }
        }.background(ink.opacity(0.12), in: RoundedRectangle(cornerRadius: SurfaceRadius.tile)).accessibilityHidden(true)
    }
}

enum SSHKeyAlgorithm: String, CaseIterable, Identifiable {
    case ed25519, rsa, ecdsa
    var id: Self { self }
    var label: String { self == .ed25519 ? "Ed25519" : rawValue.uppercased() }
    var filename: String { "id_" + rawValue }
    var bitCounts: [Int] {
        switch self {
        case .ed25519: return []
        case .rsa: return [2048, 3072, 4096]
        case .ecdsa: return [256, 384, 521]
        }
    }
    var defaultBitCount: Int? {
        switch self {
        case .ed25519: return nil
        case .rsa: return 4096
        case .ecdsa: return 256
        }
    }
}

enum SSHKeyGenerator {
    enum Failure: LocalizedError {
        case invalidName, invalidComment, invalidPassphrase, invalidKeySize, alreadyExists, generationFailed
        var errorDescription: String? {
            switch self {
            case .invalidName: return "Use a file name starting with a letter or number, followed by letters, numbers, dots, hyphens, or underscores (up to 128 characters). Leave off .pub."
            case .invalidComment: return "Keep the comment on one line, without control characters (up to 255 bytes)."
            case .invalidPassphrase: return "The passphrase must not contain control characters and must be shorter than 1,024 bytes."
            case .invalidKeySize: return "Choose a supported key size for the selected key type."
            case .alreadyExists: return "A key file with this name already exists. Choose a different file name."
            case .generationFailed: return "ssh-keygen could not create the key. Please try again."
            }
        }
    }

    static func suggestedName(in folder: URL, algorithm: SSHKeyAlgorithm = .ed25519) -> String {
        var name = algorithm.filename, suffix = 1
        while exists(folder.appendingPathComponent(name)) || exists(folder.appendingPathComponent(name + ".pub")) {
            suffix += 1
            name = "\(algorithm.filename)_\(suffix)"
        }
        return name
    }

    static func generate(in folder: URL, filename: String, comment: String, passphrase: String,
                         algorithm: SSHKeyAlgorithm = .ed25519, bitCount: Int? = nil) throws -> URL {
        let selectedBits = bitCount ?? algorithm.defaultBitCount
        if let selectedBits {
            guard algorithm.bitCounts.contains(selectedBits) else { throw Failure.invalidKeySize }
        }
        let firstCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        let allowed = firstCharacters.union(CharacterSet(charactersIn: "._-"))
        guard filename.utf8.count <= 128, let first = filename.unicodeScalars.first, firstCharacters.contains(first),
              filename.unicodeScalars.allSatisfy(allowed.contains), !filename.lowercased().hasSuffix(".pub") else { throw Failure.invalidName }
        let lineBreaksAndControls = CharacterSet.controlCharacters.union(.newlines)
        guard comment.utf8.count <= 255, comment.rangeOfCharacter(from: lineBreaksAndControls) == nil else { throw Failure.invalidComment }
        guard passphrase.utf8.count < 1024, passphrase.rangeOfCharacter(from: lineBreaksAndControls) == nil else { throw Failure.invalidPassphrase }
        let privateURL = folder.appendingPathComponent(filename), publicURL = folder.appendingPathComponent(filename + ".pub")
        guard !exists(privateURL), !exists(publicURL) else { throw Failure.alreadyExists }

        let manager = FileManager.default
        try manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Generate privately on the same volume, then publish without replacing existing files.
        let staging = folder.appendingPathComponent(".bananaShell-key-" + UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: staging) }
        let stagedPrivate = staging.appendingPathComponent("key"), stagedPublic = staging.appendingPathComponent("key.pub")
        let process = Process(), input = Pipe(), errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        var arguments = ["-q", "-t", algorithm.rawValue, "-a", "64", "-C", comment, "-f", stagedPrivate.path]
        if let selectedBits { arguments += ["-b", String(selectedBits)] }
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["SSH_ASKPASS_REQUIRE"] = "never"
        process.environment = environment
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors
        // Keep the passphrase out of process arguments, environment variables, and files.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        try process.run()
        do {
            try input.fileHandleForWriting.write(contentsOf: Data((passphrase + "\n" + passphrase + "\n").utf8))
            try input.fileHandleForWriting.close()
        } catch {
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            throw error
        }
        _ = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else { throw Failure.generationFailed }
        _ = try PublicIdentity(stagedPublic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stagedPrivate.path)
        try manager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: stagedPublic.path)

        try publish(stagedPublic, at: publicURL)
        do { try publish(stagedPrivate, at: privateURL) }
        catch {
            // Roll back only the public file we just linked, never a replacement from another writer.
            var source = stat(), destination = stat()
            if lstat(stagedPublic.path, &source) == 0, lstat(publicURL.path, &destination) == 0,
               source.st_dev == destination.st_dev, source.st_ino == destination.st_ino { _ = unlink(publicURL.path) }
            throw error
        }
        return publicURL
    }

    private static func exists(_ url: URL) -> Bool {
        var attributes = stat()
        return lstat(url.path, &attributes) == 0
    }
    private static func publish(_ source: URL, at destination: URL) throws {
        guard link(source.path, destination.path) == 0 else {
            if errno == EEXIST { throw Failure.alreadyExists }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}

// Pins illustrate key-length ordering within one algorithm, not security strength across algorithms.
// https://nvlpubs.nist.gov/nistpubs/specialpublications/nist.sp.800-57pt1r5.pdf
private struct KeyLengthLock: View {
    let pins: Int
    let selected: Bool
    private var ink: Color { selected ? .accentColor : .secondary }

    var body: some View {
        ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 11)
                .stroke(ink.opacity(0.8), lineWidth: 3)
                .frame(width: 25, height: 28).padding(.bottom, 18)
            HStack(spacing: 3) {
                ForEach(0..<pins, id: \.self) { _ in
                    VStack(spacing: 3) {
                        Capsule().fill(ink.opacity(0.65)).frame(width: 2, height: 8)
                        Circle().fill(ink).frame(width: 4, height: 4)
                    }
                }
            }.frame(width: CGFloat(pins * 7 + 12), height: 27)
             .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
             .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(ink.opacity(0.45), lineWidth: 1))
        }.frame(width: 82, height: 46).accessibilityHidden(true)
    }
}

private struct GenerateSSHKeySheet: View {
    private enum Field: Hashable { case filename, comment, passphrase, confirmation }
    @Environment(\.dismiss) private var dismiss
    let folder: URL
    let created: (URL) -> Void
    @State private var filename = "id_ed25519"
    @State private var suggestedFilename = "id_ed25519"
    @State private var algorithm: SSHKeyAlgorithm = .ed25519
    @State private var bitCount = 0
    @State private var comment = ""
    @State private var passphrase = ""
    @State private var confirmation = ""
    @State private var generating = false
    @State private var errorMessage = ""
    @FocusState private var focusedField: Field?

    private var displayFilename: String { filename.isEmpty ? algorithm.filename : filename }
    private var location: String { (folder.path as NSString).abbreviatingWithTildeInPath }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "key.horizontal.fill")
                    .font(.system(size: 21, weight: .medium)).foregroundStyle(Color.accentColor)
                    .frame(width: 44, height: 44)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: SurfaceRadius.panel))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Create SSH key").font(.system(size: 21, weight: .semibold))
                    Text("Add a new key pair to this Mac.").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }.padding(.horizontal, 24).padding(.vertical, 18)
            Divider()
            ScrollView(showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    VStack(spacing: 12) {
                        section("01", "Key type") {
                            Picker("Key type", selection: Binding(get: { algorithm }, set: selectAlgorithm)) {
                                ForEach(SSHKeyAlgorithm.allCases) { type in Text(type.label).tag(type) }
                            }.pickerStyle(.segmented).labelsHidden()
                        }
                        section("02", "Key length") { keyLengthSection }
                    }.frame(width: 268)
                    VStack(spacing: 12) {
                        section("03", "Key files") { fileSection }
                        section("04", "Passphrase", optional: true) { protectionSection }
                    }
                }.padding(24).disabled(generating)
            }.frame(height: 460)
            if !errorMessage.isEmpty {
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red).accessibilityHidden(true)
                    Text(errorMessage).font(.callout).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                 .background(Color.red.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
                 .padding(.horizontal, 24).padding(.bottom, 16)
            }
            Divider()
            HStack(spacing: 10) {
                if generating {
                    ProgressView().controlSize(.small)
                    Text("Creating \(algorithm.label) key…").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    .controlSize(.large).disabled(generating)
                Button("Create Key", action: generate).buttonStyle(.borderedProminent)
                    .controlSize(.large).keyboardShortcut(.defaultAction)
                    .disabled(generating || filename.isEmpty)
            }.padding(.horizontal, 24).padding(.vertical, 16)
             .background(Color(nsColor: .controlBackgroundColor).opacity(0.35))
        }.frame(width: 780).background(Color(nsColor: .windowBackgroundColor))
         .interactiveDismissDisabled(generating)
         .onAppear {
             suggestedFilename = SSHKeyGenerator.suggestedName(in: folder, algorithm: algorithm)
             filename = suggestedFilename
             focusedField = .filename
         }
         .onDisappear { passphrase = ""; confirmation = "" }
    }

    private var keyLengthSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if algorithm == .ed25519 {
                VStack(spacing: 10) {
                    KeyLengthLock(pins: 4, selected: true).scaleEffect(1.25).frame(height: 64)
                    Text("256 bits").font(.system(size: 19, weight: .medium, design: .monospaced))
                    Text("Fixed by Ed25519").font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity).frame(height: 186)
            } else {
                VStack(spacing: 6) {
                    ForEach(Array(algorithm.bitCounts.enumerated()), id: \.element) { index, bits in
                        Button { bitCount = bits } label: {
                            HStack(spacing: 8) {
                                KeyLengthLock(pins: 4 + index * 2, selected: bitCount == bits)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("\(String(bits)) bits").font(.system(size: 14, weight: .medium, design: .monospaced))
                                    Text(bits == algorithm.defaultBitCount ? "Default" : (index == 0 ? "Smaller key" : (index == algorithm.bitCounts.count - 1 ? "Larger key" : "Mid-size key")))
                                        .font(.system(size: 11)).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: bitCount == bits ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(bitCount == bits ? Color.accentColor : Color.secondary.opacity(0.5))
                            }.padding(.horizontal, 8).padding(.vertical, 6)
                             .background(bitCount == bits ? Color.accentColor.opacity(0.09) : Color(nsColor: .windowBackgroundColor).opacity(0.5),
                                         in: RoundedRectangle(cornerRadius: 8))
                             .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(
                                bitCount == bits ? Color.accentColor.opacity(0.75) : Color.primary.opacity(0.06), lineWidth: 1))
                             .contentShape(RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(HoverButtonStyle(cornerRadius: 8)).accessibilityLabel("\(algorithm.label) \(bits) bits")
                         .accessibilityAddTraits(bitCount == bits ? .isSelected : [])
                    }
                }
            }
            Text("Compare lengths within one key type. Bit counts use different scales across key types.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var fileSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                field("File name") {
                    TextField(algorithm.filename, text: $filename).font(.system(size: 13, design: .monospaced))
                        .accessibilityLabel("File name").focused($focusedField, equals: .filename)
                }
                field("Comment", optional: true) {
                    TextField("e.g. Work Mac", text: $comment)
                        .accessibilityLabel("Comment (optional)").focused($focusedField, equals: .comment)
                }
            }
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "folder").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 5) {
                    Text(verbatim: location).font(TabTypography.path(size: 12))
                        .lineLimit(1).truncationMode(.middle).help(folder.path)
                    Text(verbatim: displayFilename + "  ·  " + displayFilename + ".pub")
                        .font(TabTypography.path(size: 11)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                        .help("Private key: \(displayFilename)\nPublic key: \(displayFilename).pub")
                }
                Spacer(minLength: 0)
            }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
             .background(Color(nsColor: .windowBackgroundColor).opacity(0.65), in: RoundedRectangle(cornerRadius: SurfaceRadius.tab))
        }
    }

    private var protectionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            field("Passphrase") {
                SecureField("Enter passphrase", text: $passphrase)
                    .accessibilityLabel("Passphrase").focused($focusedField, equals: .passphrase)
            }
            field("Confirm passphrase") {
                SecureField("Re-enter passphrase", text: $confirmation)
                    .accessibilityLabel("Confirm passphrase").focused($focusedField, equals: .confirmation)
            }
            Text("Protects the private key file. Leave empty to save without a passphrase.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func section<Content: View>(_ number: String, _ title: String, optional: Bool = false, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(number).font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.accentColor).frame(width: 24, height: 22)
                    .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 5))
                Text(title).font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 0)
                if optional { Text("Optional").font(.caption).foregroundStyle(.secondary) }
            }
            content()
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.45), in: RoundedRectangle(cornerRadius: SurfaceRadius.panel))
        .overlay(RoundedRectangle(cornerRadius: SurfaceRadius.panel).strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
        .accessibilityElement(children: .contain).accessibilityLabel(title)
    }

    private func field<Content: View>(_ title: String, optional: Bool = false, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 12, weight: .medium))
                if optional { Text("Optional").font(.system(size: 11)).foregroundStyle(.secondary) }
            }
            content().textFieldStyle(.roundedBorder).controlSize(.large)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func selectAlgorithm(_ next: SSHKeyAlgorithm) {
        let suggestion = SSHKeyGenerator.suggestedName(in: folder, algorithm: next)
        if filename == suggestedFilename { filename = suggestion }
        suggestedFilename = suggestion
        algorithm = next
        bitCount = next.defaultBitCount ?? 0
        errorMessage = ""
    }

    private func generate() {
        guard passphrase == confirmation else {
            errorMessage = "The passphrases do not match."
            focusedField = .confirmation
            return
        }
        let name = filename, note = comment, secret = passphrase
        let type = algorithm, bits = algorithm.bitCounts.isEmpty ? nil : bitCount
        errorMessage = ""; generating = true
        Task {
            do {
                let publicURL = try await Task.detached(priority: .userInitiated) {
                    try SSHKeyGenerator.generate(in: folder, filename: name, comment: note, passphrase: secret,
                                                 algorithm: type, bitCount: bits)
                }.value
                passphrase = ""; confirmation = ""
                created(publicURL)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                generating = false
            }
        }
    }
}

struct PublicKeyPanel: View {
    let generateRequest: PassthroughSubject<Void, Never>
    let importRequest: PassthroughSubject<Void, Never>
    let folder: URL
    init(folder: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh"),
         generateRequest: PassthroughSubject<Void, Never> = .init(), importRequest: PassthroughSubject<Void, Never> = .init()) {
        self.folder = folder
        self.generateRequest = generateRequest
        self.importRequest = importRequest
    }
    @State private var keys: [PublicIdentity] = []
    @State private var aliases = UserDefaults.standard.dictionary(forKey: "publicKeyAliases") as? [String: String] ?? [:]
    @State private var query = ""
    @State private var selection: URL?
    @State private var showingDetail = false
    @State private var editing: URL?
    @FocusState private var aliasFocused: Bool
    @State private var alias = ""
    @State private var notice = ""
    @State private var copied: String?
    @State private var generatingKey = false
    private func name(_ key: PublicIdentity) -> String { aliases[key.fingerprint] ?? key.filename }
    private var matches: [PublicIdentity] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return term.isEmpty ? keys : keys.filter { key in
            [name(key), key.filename, key.fingerprint, key.algorithm].contains { $0.localizedCaseInsensitiveContains(term) }
        }
    }
    private var current: PublicIdentity? { matches.first(where: { $0.id == selection }) ?? matches.first }

    var body: some View {
        GeometryReader { geo in
            let narrow = geo.size.width < 690
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("SSH Keys").font(TabTypography.suite(size: NSFont.preferredFont(forTextStyle: .title1).pointSize, relativeTo: .title))
                            .bold()
                            .kerning(-0.6)
                        Text("Local public keys · ~/.ssh").font(TabTypography.suite(size: NSFont.preferredFont(forTextStyle: .caption1).pointSize + 1, relativeTo: .caption)).foregroundStyle(.secondary)
                    }
                    Spacer()

                }
                if !notice.isEmpty { Text(notice).font(.callout).foregroundStyle(.orange) }
                if keys.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "key").font(.largeTitle).foregroundStyle(.secondary)
                        Text("No public keys found in ~/.ssh").font(.headline)
                        Text("Use + in the tab bar to generate or import a key.").foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    HStack(alignment: .top, spacing: 16) {
                        if !narrow || !showingDetail {
                            VStack(alignment: .leading, spacing: 14) {
                                TextField("Search by name, file, or fingerprint", text: $query)
                                    .textFieldStyle(.roundedBorder)
                                ScrollView {
                                    VStack(spacing: 4) {
                                        ForEach(matches) { key in sidebarRow(key) }
                                        if matches.isEmpty { Text("No matching keys").foregroundStyle(.secondary) }
                                    }
                                }
                            }.frame(maxWidth: narrow ? .infinity : 260)
                        }
                        if !narrow { Divider() }
                        if !narrow || showingDetail {
                            ScrollView {
                                VStack(alignment: .leading, spacing: 16) {
                                    if narrow { Button("‹  All Keys") { showingDetail = false } }
                                    if let key = current { detail(key) }
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
                            }
                        }
                    }
                }
            }.padding(20)
        }.onAppear(perform: reload)
        .onReceive(generateRequest) { generatingKey = true }
        .onReceive(importRequest) { importKey() }
        .sheet(isPresented: $generatingKey) {
            GenerateSSHKeySheet(folder: folder) { url in
                reload(); selection = url; query = ""; showingDetail = true
            }
        }
    }

    private func sidebarRow(_ key: PublicIdentity) -> some View {
        HStack(spacing: 6) {
            if editing == key.id {
                TextField(key.filename, text: $alias)
                    .focused($aliasFocused)
                    .onAppear { aliasFocused = true }
                    .onSubmit { saveAlias(key) }
                    .onExitCommand { editing = nil }
                Button { saveAlias(key) } label: { Image(systemName: "checkmark") }
                    .help("Save alias").accessibilityLabel("Save alias")
                Button { editing = nil } label: { Image(systemName: "xmark") }
                    .help("Cancel").accessibilityLabel("Cancel")
            } else {
                Button { editing = nil; selection = key.id; showingDetail = true } label: {
                    HStack {
                        KeyMark(key: key).frame(width: 34, height: 34)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(verbatim: name(key)).lineLimit(1)
                            Text(key.algorithm).font(.caption2.monospaced()).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }.contentShape(Rectangle())
                }
                Button {
                    selection = key.id
                    alias = aliases[key.fingerprint] ?? ""
                    editing = key.id
                } label: { Image(systemName: "pencil") }
                .help("Edit alias").accessibilityLabel("Edit alias for " + name(key))
            }
        }.buttonStyle(HoverButtonStyle()).padding(8)
         .background(current?.id == key.id ? Color.accentColor.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 8))
    }

    private func saveAlias(_ key: PublicIdentity) {
        let value = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        aliases[key.fingerprint] = value.isEmpty ? nil : value
        UserDefaults.standard.set(aliases, forKey: "publicKeyAliases")
        editing = nil
    }

    @ViewBuilder private func detail(_ key: PublicIdentity) -> some View {
        KeyMark(key: key).frame(width: 56, height: 56)
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: name(key)).font(.title2.bold())
            Text(key.filename + " · " + key.algorithm).font(.caption.monospaced()).foregroundStyle(.secondary)
        }
        Divider()
        copyField("Fingerprint", key.fingerprint)
        copyField("Public Key", key.publicLine)
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([key.url]) }
    }

    private func copyField(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.headline)
            HStack(alignment: .top) {
                Text(verbatim: value).font(.body.monospaced()).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Button { copy(value); copied = value } label: {
                    Image(systemName: copied == value ? "checkmark" : "doc.on.doc")
                }.help("Copy " + label).accessibilityLabel("Copy " + label)
            }
        }.task(id: copied) {
            guard copied == value else { return }
            do { try await Task.sleep(nanoseconds: 1_500_000_000); copied = nil } catch {}
        }
    }
    private func copy(_ value: String) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string)
    }
    private func reload() {
        do {
            let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            keys = files.filter { $0.pathExtension.lowercased() == "pub" }.compactMap { try? PublicIdentity($0) }.sorted { $0.filename < $1.filename }
            notice = ""
        } catch {
            keys = []
            notice = [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains((error as NSError).code) ? "" : error.localizedDescription
        }
    }
    private func importKey() {
        let picker = NSOpenPanel()
        picker.allowedContentTypes = [UTType(filenameExtension: "pub") ?? .data]
        picker.canChooseDirectories = false
        guard picker.runModal() == .OK, let source = picker.url else { return }
        do {
            let key = try PublicIdentity(source)
            if let existing = keys.first(where: { $0.fingerprint == key.fingerprint }) {
                selection = existing.id
            } else {
                let dest = folder.appendingPathComponent(source.lastPathComponent)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try Data((key.publicLine + "\n").utf8).write(to: dest, options: .withoutOverwriting)
                reload(); selection = dest
            }
            query = ""; showingDetail = true
        } catch { notice = error.localizedDescription }
    }
}
