import AppKit
import SwiftUI

/// One pull request, laid out in fixed-width columns so rows line up.
struct RowView: View {
    let pr: PullRequest
    /// Position among rows entering together, for the staggered slide-in.
    let index: Int

    @EnvironmentObject private var store: Store
    @State private var hovering = false
    @State private var appeared = false

    var body: some View {
        Themed { p in
            Button {
                NSWorkspace.shared.open(pr.url)
            } label: {
                content(p)
            }
            .buttonStyle(RowButtonStyle(palette: p, hovering: hovering))
            .onHover { hovering in withAnimation(.easeOut(duration: 0.12)) { self.hovering = hovering } }
            .contextMenu { RowMenu(pr: pr) }
            .help("\(pr.title)\n\(pr.repo) #\(pr.number) · \(pr.author)")
            .opacity(appeared ? 1 : 0)
            .offset(x: appeared ? 0 : -6)
            .onAppear {
                withAnimation(.spring(duration: 0.32, bounce: 0).delay(Double(min(index, 6)) * 0.03)) {
                    appeared = true
                }
            }
        }
    }

    private func content(_ p: Palette) -> some View {
        let state = stateIcon(p)
        let status = statusLabel(p)

        return HStack(spacing: 10) {
            Icon(state.icon)
                .foregroundStyle(state.tone)
                .help(state.tip)

            Avatar(url: pr.avatarURL, name: pr.author)

            HStack(spacing: 6) {
                if store.prefs.isPinned(pr) {
                    Icon("pin", size: 11).foregroundStyle(p.accent).help("Pinned")
                }
                Text(highlighted(pr.title, store.searching ? store.normalizedQuery : ""))
                    .foregroundStyle(pr.state == .draft ? p.muted : p.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text("\(pr.shortRepo) #\(pr.number)")
                .font(Fonts.mono(12))
                .foregroundStyle(p.muted)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 118, alignment: .leading)
                .help(pr.repo)

            ChecksMark(checks: pr.checks)

            HStack(spacing: 5) {
                Icon(status.icon, size: 12)
                Text(status.text)
            }
            .font(Fonts.ui(12, .medium))
            .foregroundStyle(status.tone)
            .frame(width: 88, alignment: .leading)

            HStack(spacing: 6) {
                Text("+\(pr.additions)").foregroundStyle(p.add)
                Text("−\(pr.deletions)").foregroundStyle(p.del)
            }
            .font(Fonts.mono(12))
            .lineLimit(1)
            .frame(width: 84, alignment: .trailing)

            Text(ago(pr.relevantDate))
                .font(Fonts.mono(12))
                .foregroundStyle(p.faint)
                .frame(width: 30, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .frame(height: Layout.rowHeight)
    }

    private func stateIcon(_ p: Palette) -> (icon: String, tone: Color, tip: String) {
        switch (pr.state, pr.mergeable) {
        case (.merged, _): ("git-merge", p.purple, "Merged")
        case (.closed, _): ("git-pull-request-closed", p.red, "Closed")
        case (.draft, _): ("git-pull-request-draft", p.faint, "Draft")
        case (.open, .conflicting): ("git-pull-request", p.red, "Merge conflicts")
        case (.open, .clean): ("git-pull-request", p.green, "No conflicts")
        case (.open, .unknown): ("git-pull-request", p.faint, "Checking for conflicts")
        }
    }

    private func statusLabel(_ p: Palette) -> (icon: String, tone: Color, text: String) {
        switch pr.status {
        case .requested: ("eye", p.blue, "Review")
        case .reReview: ("sync", p.purple, "Re-review")
        case .newCommits: ("git-commit", p.amber, pr.newCommits > 0 ? "\(pr.newCommits) new" : "Updated")
        case .done where pr.state == .merged: ("git-merge", p.purple, "Merged")
        case .done: ("git-pull-request-closed", p.red, "Closed")
        }
    }
}

/// Hover and press backgrounds, Zed's list-item style.
private struct RowButtonStyle: ButtonStyle {
    let palette: Palette
    let hovering: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(configuration.isPressed ? palette.active : hovering ? palette.hover : .clear)
            )
            .contentShape(Rectangle())
    }
}

private struct ChecksMark: View {
    let checks: Checks

    @State private var bright = false

    var body: some View {
        Themed { p in
            switch checks {
            case .none:
                Color.clear.frame(width: 12, height: 12)
            case .passing:
                Icon("check", size: 12).foregroundStyle(p.green).help("Checks passing")
            case .failing:
                Icon("x", size: 12).foregroundStyle(p.red).help("Checks failing")
            case .pending:
                Icon("dot-fill", size: 12)
                    .foregroundStyle(p.amber)
                    .opacity(bright ? 1 : 0.35)
                    .animation(.easeInOut(duration: 1).repeatForever(), value: bright)
                    .onAppear { bright = true }
                    .help("Checks running")
            }
        }
    }
}

private struct Avatar: View {
    let url: URL?
    let name: String

    @EnvironmentObject private var store: Store

    var body: some View {
        Themed { p in
            Group {
                if let url, let image = store.avatars[url] {
                    Image(nsImage: image).resizable().interpolation(.high)
                } else {
                    Text(name.prefix(1).uppercased())
                        .font(Fonts.ui(10, .semibold))
                        .foregroundStyle(p.muted)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(p.hover)
                }
            }
            .frame(width: 18, height: 18)
            .clipShape(Circle())
            .help(name)
        }
    }
}

struct RowMenu: View {
    let pr: PullRequest

    @EnvironmentObject private var store: Store

    var body: some View {
        Button("Open on GitHub") { NSWorkspace.shared.open(pr.url) }
        Button("Copy Link") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(pr.url.absoluteString, forType: .string)
        }
        Divider()
        if store.prefs.isPinned(pr) {
            Button("Unpin") { store.setPinned(pr, false) }
        } else {
            Button("Pin to Top") { store.setPinned(pr, true) }
        }
        Divider()
        Button("Ignore") { store.ignore(pr) }
        Button("Stop Watching \(pr.repo)") { store.setWatched(pr.repo, false) }
    }
}

/// Every case-insensitive match of `query` marked like Zed's search matches.
func highlighted(_ text: String, _ query: String) -> AttributedString {
    var result = AttributedString(text)
    guard !query.isEmpty else { return result }

    var searchRange = text.startIndex..<text.endIndex
    while let found = text.range(of: query, options: .caseInsensitive, range: searchRange) {
        if let range = Range(found, in: result) {
            result[range].backgroundColor = Palette.searchMatch
        }
        searchRange = found.upperBound..<text.endIndex
    }
    return result
}
