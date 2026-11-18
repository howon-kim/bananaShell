import SwiftUI

/// Shared measurements for the Themes and Extensions marketplaces, so both pages line up.
enum MarketplaceMetrics {
    static let horizontalPadding: CGFloat = 24
    static let topPadding: CGFloat = 20
    static let bottomPadding: CGFloat = 20
    /// Between the header and the scrolling content.
    static let headerSpacing: CGFloat = 18
    /// Between blocks inside the scrolling content (hero, toolbar, notices, shelves).
    static let contentSpacing: CGFloat = 22
    /// Between shelves.
    static let shelfSpacing: CGFloat = 26
    /// Between a shelf's title and its cards.
    static let shelfHeaderSpacing: CGFloat = 10
    static let gridColumnSpacing: CGFloat = 14
    static let gridRowSpacing: CGFloat = 16
    static let inspectorWidth: CGFloat = 340
    static let inspectorPadding: CGFloat = 18
    static let searchWidth: CGFloat = 220
    static let emptyStatePadding: CGFloat = 60
}

/// Page title and subtitle with icon buttons on the right.
struct MarketplaceHeader<Actions: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 26, weight: .bold))
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            actions()
        }
    }
}

/// One capsule in a marketplace section bar; the selected one fills with the accent.
struct MarketplaceTab: View {
    let title: String
    let icon: String
    let selected: Bool
    var badge: Int? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Label(title, systemImage: icon)
                if let badge, badge > 0 {
                    Text("\(badge)").font(.system(size: 10.5, weight: .bold)).monospacedDigit()
                        .padding(.horizontal, 5).frame(minWidth: 16, minHeight: 16)
                        .background((selected ? Color.black : Color.accentColor).opacity(selected ? 0.18 : 0.3), in: Capsule())
                }
            }
            .font(.system(size: 12.5, weight: .medium))
            .padding(.horizontal, 11).frame(height: 28)
            .foregroundStyle(selected ? Color.black.opacity(0.85) : .primary)
            .background(selected ? Color.accentColor : .clear, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The capsule track that holds `MarketplaceTab`s.
struct MarketplaceTabBar<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: 4) { content() }
            .padding(3)
            .background(Color.white.opacity(0.05), in: Capsule())
    }
}

struct MarketplaceSearchField: View {
    let prompt: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(prompt, text: $text).textFieldStyle(.plain).accessibilityLabel(prompt)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain).accessibilityLabel("Clear search")
            }
        }
        .font(.callout).padding(.horizontal, 10)
        .frame(width: MarketplaceMetrics.searchWidth, height: 30)
        .background(Color.white.opacity(0.05), in: Capsule())
    }
}

/// A shelf title with a subtitle and an optional trailing control.
struct MarketplaceShelfHeader<Trailing: View>: View {
    let title: String
    let subtitle: String?
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 16, weight: .semibold))
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            trailing()
        }
    }
}

/// Icon, message, centered in the content area.
struct MarketplaceEmptyState: View {
    let symbol: String
    let message: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.title2)
            Text(message)
        }
        .foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, MarketplaceMetrics.emptyStatePadding)
    }
}

/// Uppercase caption at the top of an inspector or a section inside it.
struct MarketplaceEyebrow: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased()).font(.system(size: 10.5, weight: .semibold)).tracking(0.8).foregroundStyle(.secondary)
    }
}

/// A label–value line in an inspector.
struct MarketplaceInfoRow: View {
    let title: String
    let value: String
    init(_ title: String, _ value: String) { self.title = title; self.value = value }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(.secondary).frame(width: 72, alignment: .leading)
            Text(value).textSelection(.enabled).lineLimit(3).truncationMode(.middle)
        }.font(.callout)
    }
}

struct MarketIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: 30, height: 28)
            .background(Color.white.opacity(configuration.isPressed ? 0.14 : 0.06), in: RoundedRectangle(cornerRadius: 7))
            .contentShape(RoundedRectangle(cornerRadius: 7))
    }
}
