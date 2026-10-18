import AppKit
import SwiftUI

enum Layout {
    static let rowHeight: CGFloat = 30
    /// Rows that fit before the list scrolls.
    static let visibleRows = 7
    static let headerHeight: CGFloat = 44
    static let bodyHeight = CGFloat(visibleRows) * rowHeight + 14
    static let cardWidth: CGFloat = 732
    /// Transparent room around the card for its shadow.
    static let shadowMargin: CGFloat = 14
    static let cornerRadius: CGFloat = 20
}

struct WidgetView: View {
    @EnvironmentObject private var store: Store
    @State private var appeared = false

    var body: some View {
        Themed { p in
            let card = RoundedRectangle(cornerRadius: Layout.cornerRadius, style: .continuous)
            VStack(spacing: 0) {
                HeaderView()
                Rectangle().fill(p.border.opacity(0.55)).frame(height: 1)
                BodyView().frame(height: Layout.bodyHeight)
            }
            .frame(width: Layout.cardWidth)
            .font(Fonts.ui(13))
            .foregroundStyle(p.text)
            .background(card.fill(p.bg.opacity(0.86)))
            .clipShape(card)
            .overlay(card.strokeBorder(p.text.opacity(0.09)))
            .contextMenu { WidgetMenu() }
            .shadow(color: p.shadow, radius: 13, y: 8)
            .padding(Layout.shadowMargin)
            .scaleEffect(appeared ? 1 : 0.97)
            .opacity(appeared ? 1 : 0)
            .onAppear {
                withAnimation(.spring(duration: 0.38, bounce: 0)) { appeared = true }
            }
        }
    }
}

// MARK: - Header

private struct HeaderView: View {
    @EnvironmentObject private var store: Store

    var body: some View {
        ZStack {
            if store.searching {
                SearchBar().transition(.opacity)
            } else {
                TabsBar().transition(.opacity)
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .frame(height: Layout.headerHeight)
    }
}

private struct TabsBar: View {
    @EnvironmentObject private var store: Store

    var body: some View {
        Themed { p in
            HStack(spacing: 2) {
                Icon("git-pull-request").foregroundStyle(p.muted).padding(.trailing, 6)
                Text("Reviews").font(Fonts.ui(13, .semibold)).padding(.trailing, 8)

                ForEach(Filter.allCases, id: \.self) { filter in
                    let count = store.count(filter)
                    // Closed only shows up when there is something in it.
                    if filter != .done || count > 0 {
                        TabButton(filter: filter, count: store.lastUpdate == nil ? nil : count)
                    }
                }

                Spacer(minLength: 8)

                Text(updatedText)
                    .font(Fonts.mono(11.5))
                    .foregroundStyle(p.faint)
                    .padding(.trailing, 6)

                IconButton(icon: "search", help: "Search (⌘F)") { store.openSearch() }
                    .keyboardShortcut("f", modifiers: .command)
                IconButton(icon: "link-external", help: "Open review queue on GitHub") {
                    NSWorkspace.shared.open(GitHub.reviewQueue)
                }
                RefreshButton()
                IconButton(icon: "gear", help: "Settings") { store.showingSettings.toggle() }
                    .popover(isPresented: $store.showingSettings, arrowEdge: .bottom) {
                        SettingsView().environmentObject(store)
                    }
            }
        }
    }

    private var updatedText: String {
        guard let last = store.lastUpdate else { return "" }
        let since = ago(last)
        return since == "now" ? "updated now" : "updated \(since) ago"
    }
}

private struct TabButton: View {
    let filter: Filter
    /// Hidden until the first load so the counts don't start at zero.
    let count: Int?

    @EnvironmentObject private var store: Store
    @State private var hovering = false

    var body: some View {
        Themed { p in
            let active = store.filter == filter
            Button {
                withAnimation(.snappy) { store.filter = filter }
            } label: {
                HStack(spacing: 6) {
                    Text(filter.title).font(Fonts.ui(13, .medium))
                    if let count {
                        Text("\(count)")
                            .font(Fonts.mono(11.5))
                            .foregroundStyle(active ? p.muted : p.faint)
                            .contentTransition(.numericText(value: Double(count)))
                            .animation(.snappy, value: count)
                    }
                }
                .foregroundStyle(active || hovering ? p.text : p.muted)
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(RoundedRectangle(cornerRadius: 6).fill(active ? p.active : hovering ? p.hover : .clear))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering in withAnimation(.easeOut(duration: 0.14)) { self.hovering = hovering } }
        }
    }
}

/// Spins while loading; turns amber with the error as its tooltip when the
/// last refresh failed.
private struct RefreshButton: View {
    @EnvironmentObject private var store: Store

    var body: some View {
        Themed { p in
            TimelineView(.animation(paused: !store.loading)) { context in
                let angle = store.loading
                    ? context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.7) / 0.7 * 360
                    : 0
                IconButton(
                    icon: "sync",
                    help: store.error.map { "Couldn't refresh: \($0)" } ?? "Refresh (⌘R)",
                    tint: store.error == nil ? nil : p.amber
                ) {
                    store.refresh()
                }
                .rotationEffect(.degrees(angle))
            }
            .keyboardShortcut("r", modifiers: .command)
        }
    }
}

private struct SearchBar: View {
    @EnvironmentObject private var store: Store
    @FocusState private var focused: Bool

    var body: some View {
        Themed { p in
            HStack(spacing: 8) {
                Icon("search").foregroundStyle(p.muted)
                TextField(
                    "",
                    text: $store.query,
                    prompt: Text("Search titles, repositories, authors, #numbers").foregroundStyle(p.faint)
                )
                .textFieldStyle(.plain)
                .font(Fonts.ui(13))
                .focused($focused)
                .onExitCommand { store.closeSearch() }

                if !store.normalizedQuery.isEmpty {
                    Text("\(store.rows.count) found")
                        .font(Fonts.mono(11.5))
                        .foregroundStyle(p.faint)
                }
                IconButton(icon: "x", help: "Close search (Esc)") { store.closeSearch() }
            }
            .onAppear { focused = true }
        }
    }
}

// MARK: - Body

private struct BodyView: View {
    @EnvironmentObject private var store: Store

    var body: some View {
        Themed { p in
            ZStack(alignment: .bottom) {
                switch store.page {
                case .loading:
                    PlaceholderList()
                case .list:
                    RowList()
                case .empty(let filter):
                    StateView(
                        icon: "check-circle",
                        tone: filter == .all ? p.green : nil,
                        title: filter.emptyText.title,
                        message: filter.emptyText.body
                    )
                case .noMatches:
                    StateView(
                        icon: "search",
                        tone: nil,
                        title: "No matches",
                        message: "Nothing matches “\(store.normalizedQuery)”."
                    )
                case .error(let message):
                    StateView(icon: "alert", tone: p.red, title: "Couldn't reach GitHub", message: message)
                }

                if let toast = store.toast {
                    ToastView(toast: toast) { store.undo() }
                        .padding(.bottom, 8)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.2), value: store.page)
        }
    }
}

private struct RowList: View {
    @EnvironmentObject private var store: Store

    var body: some View {
        let rows = store.rows
        ScrollView(.vertical) {
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, pr in
                    RowView(pr: pr, index: index)
                }
            }
            .padding(6)
            // A new tab or search rebuilds the rows so they all slide in.
            .id(store.searching ? "search" : "\(store.filter)")
        }
        .scrollIndicators(.automatic)
    }
}

/// Right-click anywhere outside a row.
private struct WidgetMenu: View {
    @EnvironmentObject private var store: Store

    var body: some View {
        Button("Refresh") { store.refresh() }
        Button("Open Review Queue") { NSWorkspace.shared.open(GitHub.reviewQueue) }

        let ignored = store.ignoredCount
        let unwatched = store.repositories.filter { !store.prefs.isWatched($0) }
        if ignored > 0 || !unwatched.isEmpty {
            Divider()
            if ignored > 0 {
                Button(ignored == 1 ? "Show 1 Ignored PR" : "Show \(ignored) Ignored PRs") { store.unignoreAll() }
            }
            ForEach(unwatched, id: \.self) { repo in
                Button("Watch \(repo)") { store.setWatched(repo, true) }
            }
        }

        Divider()
        Button("Quit Megalith Widgets") { NSApp.terminate(nil) }
    }
}
