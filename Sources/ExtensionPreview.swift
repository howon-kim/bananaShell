import SwiftUI

/// A two-step terminal example. The button changes the displayed text locally.
struct ExtensionDemo {
    let explanation: String
    let action: String
    let before: AttributedString
    let after: AttributedString

    private static func ink(_ value: String, _ color: Color) -> AttributedString {
        var text = AttributedString(value)
        text.foregroundColor = color
        return text
    }

    static func example(for plugin: ShellPlugin) -> Self? {
        switch plugin.id {
        case ShellPlugin.suggestions.id:
            return Self(explanation: "A command from your history appears in gray as you type. Accept the rest with the right arrow.",
                        action: "Press →", before: "❯ git st" + ink("atus", .secondary), after: "❯ git status")
        case ShellPlugin.highlighting.id:
            return Self(explanation: "Command names change color as you type. Here, fixing the typo turns the command green.",
                        action: "Correct the typo", before: "❯ " + ink("gti", .red) + " status",
                        after: "❯ " + ink("git", .green) + " status")
        case ShellPlugin.corrections.id:
            return Self(explanation: "After a command fails, enter f to review a suggested correction.",
                        action: "Enter f", before: "❯ git sttaus\ngit: 'sttaus' is not a git command.",
                        after: "❯ f\nSuggested fix   git status")
        case "zsh-autopair":
            return Self(explanation: "Type an opening quote and the closing quote appears with the cursor between the two.",
                        action: "Type an opening quote", before: "❯ echo ▏", after: "❯ echo \"▏\"")
        case "zsh-vi-mode":
            return Self(explanation: "Edit the command line with vi motions. Escape enters normal mode, 0 moves to the start, and dw deletes the first word.",
                        action: "Press Esc, 0, dw", before: "❯ echo hello world", after: "❯ hello world")
        case "zsh-history-substring-search":
            return Self(explanation: "Enter part of an earlier command, then use your history-search binding to recall the matching line.",
                        action: "Search history", before: "❯ --short", after: "❯ git status --short")
        case "zsh-you-should-use":
            return Self(explanation: "With gs already set as your alias for git status, running the long form brings up an alias reminder.",
                        action: "Enter the command", before: "❯ git status", after: "❯ git status\nAlias reminder   gs")
        case "zsh-system-clipboard":
            return Self(explanation: "In vi command mode, paste text from the system clipboard into the command line. Here the clipboard contains hello.",
                        action: "Paste hello", before: "❯ echo ", after: "❯ echo hello")
        default: return nil
        }
    }
}

struct ExtensionPreview: View {
    let plugin: ShellPlugin
    let formula: HomebrewFormula?
    @State private var advanced = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            MarketplaceEyebrow("How it works")
            if let demo = ExtensionDemo.example(for: plugin) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 6) {
                        ForEach([Color.red, .yellow, .green], id: \.self) { Circle().fill($0.opacity(0.75)).frame(width: 8, height: 8) }
                        Spacer()
                        Button { advanced.toggle() } label: {
                            Label(advanced ? "Reset" : demo.action, systemImage: advanced ? "arrow.counterclockwise" : "play.fill")
                        }
                        .buttonStyle(.borderless).font(.caption.weight(.medium))
                    }
                    .padding(.horizontal, 10).frame(height: 28)
                    .background(Color.white.opacity(0.05))
                    Text(advanced ? demo.after : demo.before)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(maxWidth: .infinity, minHeight: 54, alignment: .topLeading)
                        .padding(12)
                        .animation(.easeOut(duration: 0.15), value: advanced)
                }
                .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.08)))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                Text(demo.explanation).font(.callout).fixedSize(horizontal: false, vertical: true)
            } else if let formula {
                ExtensionReadmePreview(formula: formula)
            } else {
                Text("Usage information is unavailable for this installed copy.").font(.callout).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ExtensionReadmePreview: View {
    let formula: HomebrewFormula
    @State private var excerpt: String?
    @State private var loading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if loading {
                ProgressView("Loading usage notes…").controlSize(.small)
            } else if let excerpt {
                Text(verbatim: excerpt).font(.callout).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                    .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.08)))
            } else {
                Text(formula.desc ?? "See the project README for usage examples.").font(.callout)
            }
            if let project = formula.homepage {
                Link("Read the full README", destination: URL(string: "#readme", relativeTo: project)?.absoluteURL ?? project)
                    .font(.callout)
            }
        }
        .task(id: formula.urls.stable.url) {
            loading = true
            excerpt = nil
            let snippet = await formula.usageExcerpt()
            if !Task.isCancelled { excerpt = snippet; loading = false }
        }
    }
}
