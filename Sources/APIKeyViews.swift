import AppKit
import SwiftUI

struct APIKeyMark: View {
    var size: CGFloat = 34
    var body: some View {
        Image(systemName: "curlybraces")
            .font(.system(size: size * 0.43, weight: .medium)).foregroundStyle(Color.accentColor)
            .frame(width: size, height: size)
            .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: SurfaceRadius.tile))
            .accessibilityHidden(true)
    }
}

struct APIKeyEditor: View {
    private enum Field: Hashable { case name, service, link, secret }
    @Environment(\.dismiss) private var dismiss
    let record: APIKeyRecord?
    let store: APIKeyStore
    let saved: (UUID) -> Void
    @State private var name: String
    @State private var service: String
    @State private var link: String
    @State private var secret = ""
    @State private var saving = false
    @State private var failure: String?
    @FocusState private var focus: Field?

    init(record: APIKeyRecord? = nil, store: APIKeyStore, saved: @escaping (UUID) -> Void) {
        self.record = record; self.store = store; self.saved = saved
        _name = State(initialValue: record?.name ?? "")
        _service = State(initialValue: record?.service ?? "")
        _link = State(initialValue: record?.link?.absoluteString ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                APIKeyMark(size: 44)
                VStack(alignment: .leading, spacing: 4) {
                    Text(record == nil ? "Add API key" : "Edit API key").font(.system(size: 21, weight: .semibold))
                    Text("Stored securely in macOS Keychain.").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }.padding(.horizontal, 24).padding(.vertical, 18)
            Divider()
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Details").settingsSectionTitle()
                    VStack(alignment: .leading, spacing: 14) {
                        field("Name") {
                            TextField("e.g. Work API", text: $name).focused($focus, equals: .name)
                                .accessibilityLabel("API key name")
                        }
                        field("Service · Optional") {
                            TextField("e.g. OpenAI, GitHub, or a custom service", text: $service).focused($focus, equals: .service)
                                .accessibilityLabel("API key service")
                        }
                        field("Related link · Optional") {
                            TextField("https://… · dashboard or API documentation", text: $link).focused($focus, equals: .link)
                                .accessibilityLabel("API key related link")
                        }
                    }.padding(16).settingsSurface()
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("API key").settingsSectionTitle()
                    VStack(alignment: .leading, spacing: 8) {
                        SecureField(record == nil ? "Paste the API key" : "New key · leave empty to keep current", text: $secret)
                            .textFieldStyle(.roundedBorder).controlSize(.large).focused($focus, equals: .secret)
                            .accessibilityLabel("API key value").privacySensitive()
                        Text(record == nil ? "Use the full key without spaces or line breaks." : "Leave empty to keep the saved key. Enter a new value to replace it.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }.padding(16).settingsSurface()
                }
                if let failure { Text(failure).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            }.padding(24).disabled(saving)
            Divider()
            HStack {
                if saving { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(saving)
                Button(saving ? "Saving…" : "Save API Key", action: save)
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(saving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (record == nil && secret.isEmpty))
            }.padding(.horizontal, 24).padding(.vertical, 16)
        }.frame(width: 520)
         .interactiveDismissDisabled(saving)
         .onAppear { focus = .name }
         .onDisappear { secret = "" }
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 12, weight: .medium))
            content().textFieldStyle(.roundedBorder).controlSize(.large)
        }
    }

    private func save() {
        guard !saving else { return }
        let name = name, service = service, link = link, secret = secret, id = record?.id, store = store
        saving = true; failure = nil
        Task {
            do {
                let savedID = try await Task.detached(priority: .userInitiated) {
                    if let id {
                        try store.update(id: id, name: name, service: service, link: link, secret: secret.isEmpty ? nil : secret)
                        return id
                    }
                    return try store.add(name: name, service: service, link: link, secret: secret)
                }.value
                self.secret = ""
                saved(savedID)
                dismiss()
            } catch { failure = error.localizedDescription; saving = false }
        }
    }
}

@MainActor
private enum APIKeyClipboard {
    static func copy(_ value: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
        let version = pasteboard.changeCount
        // Retain only the change counter; never keep a second secret in a timer.
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
            if NSPasteboard.general.changeCount == version { NSPasteboard.general.clearContents() }
        }
    }
}

struct APIKeyDetail: View {
    let record: APIKeyRecord
    let store: APIKeyStore
    let delete: () -> Void
    @State private var revealed: String?
    @State private var busy = false
    @State private var copied = false
    @State private var failure: String?
    @State private var visible = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            KeyDetailHeader(mark: KeyMark(recordID: record.id), title: record.name,
                            subtitle: record.service.isEmpty ? "API key" : "API key · " + record.service,
                            added: record.createdAt, historyID: record.id.uuidString)
                .overlay(alignment: .topTrailing) {
                    Menu {
                        Button("Delete API Key…", role: .destructive, action: delete)
                    } label: { Image(systemName: "ellipsis").frame(width: 20, height: 24) }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .help("API key actions").accessibilityLabel("API key actions")
                }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text("API key").settingsSectionTitle()
                    ProgressView().controlSize(.small).frame(width: 16, height: 16)
                        .opacity(busy ? 1 : 0).accessibilityHidden(!busy)
                }
                KeyValueCard(value: revealed ?? "••••••••••••••••", secret: true) {
                    HStack(spacing: 4) {
                        PanelActionButton(symbol: revealed == nil ? "eye" : "eye.slash",
                                          title: revealed == nil ? "Show API key" : "Hide API key",
                                          highlighted: revealed != nil) {
                            if revealed != nil { revealed = nil } else { readSecret(copy: false) }
                        }
                        PanelActionButton(symbol: copied ? "checkmark" : "doc.on.doc",
                                          title: "Copy API key", highlighted: copied) { readSecret(copy: true) }
                    }
                }.disabled(busy)
                if copied { Text("Copied. Clipboard clears in 60 seconds while the app is open.").font(.caption).foregroundStyle(.secondary) }
            }
            if let link = record.link {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Related link").settingsSectionTitle()
                    Link(destination: link) {
                        KeyDestinationLabel(symbol: "link", title: link.host ?? link.absoluteString, subtitle: link.absoluteString)
                    }.buttonStyle(HoverButtonStyle(cornerRadius: SurfaceRadius.tile)).settingsSurface()
                        .help("Open in browser").accessibilityLabel("Open API related link: " + link.absoluteString)
                }
            }
            if let failure { Text(failure).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            Label("Saved in macOS Keychain", systemImage: "lock.shield")
                .font(.callout).foregroundStyle(.secondary)
        }
        .onAppear { visible = true }
        .onDisappear { visible = false; revealed = nil; copied = false }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in revealed = nil }
        .task(id: revealed != nil) {
            guard revealed != nil else { return }
            do { try await Task.sleep(nanoseconds: 30_000_000_000); revealed = nil } catch {}
        }
        .task(id: copied) {
            guard copied else { return }
            do { try await Task.sleep(nanoseconds: 3_000_000_000); copied = false } catch {}
        }
    }

    private func readSecret(copy: Bool) {
        guard !busy else { return }
        busy = true; failure = nil
        let id = record.id, store = store
        Task {
            defer { busy = false }
            do {
                let value = try await Task.detached(priority: .userInitiated) { try store.secret(for: id) }.value
                guard visible else { return }
                if copy { APIKeyClipboard.copy(value); copied = true }
                else if NSApp.isActive { revealed = value }
                else { return }
                KeyDates.accessed(id.uuidString)
            } catch { if visible { failure = error.localizedDescription } }
        }
    }
}
