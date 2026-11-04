import SwiftUI

struct EditorSheet<Content: View, Actions: View>: View {
    let icon: String
    let title: String
    let subtitle: String
    let message: String?
    @ViewBuilder let content: () -> Content
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 21, weight: .medium)).foregroundStyle(Color.accentColor)
                    .frame(width: 44, height: 44)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: SurfaceRadius.panel))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 21, weight: .semibold))
                    Text(subtitle).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }.padding(.horizontal, 24).padding(.vertical, 18)
            Divider()
            ScrollView {
                content().padding(24)
            }.frame(height: 460)
            if let message, !message.isEmpty {
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red).accessibilityHidden(true)
                    Text(message).font(.callout).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                 .background(Color.red.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
                 .padding(.horizontal, 24).padding(.bottom, 16)
            }
            Divider()
            HStack(spacing: 10) { actions() }
                .controlSize(.large)
                .padding(.horizontal, 24).padding(.vertical, 16)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.35))
        }.frame(width: 780).background(Color(nsColor: .windowBackgroundColor))
    }
}

func editorSection<Content: View>(_ number: String, _ title: String, optional: Bool = false, @ViewBuilder content: () -> Content) -> some View {
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

func editorField<Content: View>(_ title: String, optional: Bool = false, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 7) {
        HStack(spacing: 6) {
            Text(title).font(.system(size: 12, weight: .medium))
            if optional { Text("Optional").font(.system(size: 11)).foregroundStyle(.secondary) }
        }
        content().textFieldStyle(.roundedBorder).controlSize(.large)
    }.frame(maxWidth: .infinity, alignment: .leading)
}
