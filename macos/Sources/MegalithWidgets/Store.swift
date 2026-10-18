import AppKit
import SwiftUI
import UserNotifications

enum Filter: CaseIterable, Hashable {
    case all, requested, reReview, newCommits, done

    var title: String {
        switch self {
        case .all: "All"
        case .requested: "Review"
        case .reReview: "Re-review"
        case .newCommits: "Updated"
        case .done: "Closed"
        }
    }

    func matches(_ pr: PullRequest) -> Bool {
        switch self {
        case .all: pr.status != .done
        case .requested: pr.status == .requested
        case .reReview: pr.status == .reReview
        case .newCommits: pr.status == .newCommits
        case .done: pr.status == .done
        }
    }

    var emptyText: (title: String, body: String) {
        switch self {
        case .all: ("All caught up", "Nothing is waiting on your review.")
        case .done: ("Nothing closed", "Merged and closed PRs stay here for a day.")
        default: ("Nothing here", "No pull requests in this group.")
        }
    }
}

enum Page: Equatable {
    case loading
    case list
    case empty(Filter)
    case noMatches
    case error(String)
}

struct Toast: Equatable {
    let id = UUID()
    let text: String
}

@MainActor
final class Store: ObservableObject {
    /// Open PRs first (newest activity first), then recently closed ones.
    @Published private(set) var prs: [PullRequest] = []
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published private(set) var lastUpdate: Date?
    @Published private(set) var prefs = Prefs.load()
    @Published private(set) var avatars: [URL: NSImage] = [:]
    @Published private(set) var toast: Toast?
    @Published var filter = Filter.all
    @Published var query = ""
    @Published var searching = false
    @Published var showingSettings = false

    private static let tickInterval: TimeInterval = 15
    /// How long merged/closed PRs linger in the Closed tab.
    private static let keepDoneFor: TimeInterval = 24 * 60 * 60
    private static let toastSeconds: UInt64 = 6

    private var open: [PullRequest] = []
    private var done: [String: PullRequest] = [:]
    /// Attention keys already announced; nil until the first load so startup
    /// doesn't fire a notification for every waiting PR.
    private var announced: Set<String>?
    private var lastFetch: Date?
    private var undoPrefs: Prefs?
    private var timer: Timer?

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    // MARK: Fetching

    func refresh() {
        guard !loading else { return }
        loading = true
        lastFetch = Date()
        let tracked = open.map(\.id)
        Task {
            do {
                let snapshot = try await GitHub.fetch(tracked: tracked)
                apply(snapshot)
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
            loading = false
        }
    }

    private func tick() {
        // Relative timestamps read the clock while rendering.
        objectWillChange.send()
        let interval = TimeInterval(max(prefs.settings.refreshMinutes, 1) * 60)
        if lastFetch.map({ Date().timeIntervalSince($0) >= interval }) ?? true {
            refresh()
        }
    }

    private func apply(_ snapshot: Snapshot) {
        let now = Date()
        for pr in snapshot.done {
            done[pr.id] = pr
        }
        for pr in snapshot.open {
            done[pr.id] = nil
        }
        done = done.filter { now.timeIntervalSince($0.value.closedAt ?? now) < Self.keepDoneFor }

        announce(snapshot.open)
        open = snapshot.open

        let finished = done.values.sorted { ($0.closedAt ?? .distantPast) > ($1.closedAt ?? .distantPast) }
        withAnimation(.snappy) {
            prs = open + finished
            lastUpdate = now
            // A tab that just emptied out falls back to "All".
            if filter == .done && matching(.done).isEmpty {
                filter = .all
            }
        }
        if prefs.prune(keeping: prs) {
            prefs.save()
        }
        loadAvatars()
    }

    private func loadAvatars() {
        let missing = Set(prs.compactMap(\.avatarURL)).subtracting(avatars.keys)
        for url in missing {
            Task {
                guard let response = try? await URLSession.shared.data(from: url),
                      let image = NSImage(data: response.0)
                else { return }
                avatars[url] = image
            }
        }
    }

    private func announce(_ open: [PullRequest]) {
        defer { announced = Set(open.map(\.attentionKey)) }
        guard let announced, prefs.settings.notifications, NotificationHandler.available else { return }

        for pr in open where !announced.contains(pr.attentionKey) && !prefs.isHidden(pr) {
            let content = UNMutableNotificationContent()
            content.title = switch pr.status {
            case .requested: "Review requested"
            case .reReview: "Re-review requested"
            case .newCommits: "New commits since your review"
            case .done: ""
            }
            guard !content.title.isEmpty else { continue }
            content.body = "\(pr.title)\n\(pr.repo) #\(pr.number) · \(pr.author)"
            content.userInfo = ["url": pr.url.absoluteString]
            UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: pr.id, content: content, trigger: nil)
            )
        }
    }

    // MARK: What's on screen

    /// PRs for a tab: visible ones only, pinned first.
    func matching(_ filter: Filter) -> [PullRequest] {
        pinnedFirst(prs.filter { filter.matches($0) && prefs.isVisible($0) })
    }

    func count(_ filter: Filter) -> Int {
        matching(filter).count
    }

    var normalizedQuery: String {
        query.trimmingCharacters(in: .whitespaces)
    }

    /// The rows to show: the current tab, or every visible PR while searching.
    var rows: [PullRequest] {
        let query = normalizedQuery
        guard searching, !query.isEmpty else { return matching(filter) }
        return pinnedFirst(prs.filter { prefs.isVisible($0) && Self.matches($0, query) })
    }

    var page: Page {
        if lastUpdate == nil {
            return error.map(Page.error) ?? .loading
        }
        if !rows.isEmpty {
            return .list
        }
        return searching && !normalizedQuery.isEmpty ? .noMatches : .empty(filter)
    }

    var repositories: [String] {
        prefs.repositories(in: prs)
    }

    var ignoredCount: Int {
        prefs.ignoredCount(in: prs)
    }

    private func pinnedFirst(_ prs: [PullRequest]) -> [PullRequest] {
        prs.filter(prefs.isPinned) + prs.filter { !prefs.isPinned($0) }
    }

    private static func matches(_ pr: PullRequest, _ query: String) -> Bool {
        let number = query.hasPrefix("#") ? String(query.dropFirst()) : query
        return pr.title.localizedCaseInsensitiveContains(query)
            || pr.repo.localizedCaseInsensitiveContains(query)
            || pr.author.localizedCaseInsensitiveContains(query)
            || String(pr.number) == number
    }

    // MARK: Actions

    func openSearch() {
        withAnimation(.easeOut(duration: 0.16)) { searching = true }
    }

    func closeSearch() {
        withAnimation(.easeOut(duration: 0.16)) {
            searching = false
            query = ""
        }
    }

    func setPinned(_ pr: PullRequest, _ pinned: Bool) {
        updatePrefs { $0.setPinned(pr, pinned) }
    }

    func ignore(_ pr: PullRequest) {
        updatePrefs(toast: "Ignored “\(pr.title)”") { $0.ignore(pr) }
    }

    func setWatched(_ repo: String, _ watched: Bool) {
        let toast = watched ? nil : "Stopped watching \(repo)"
        updatePrefs(toast: toast) { $0.setWatched(repo, watched) }
    }

    func unignoreAll() {
        updatePrefs { $0.unignoreAll() }
    }

    func updateSettings(_ change: (inout Settings) -> Void) {
        updatePrefs { change(&$0.settings) }
    }

    func undo() {
        guard let before = undoPrefs else { return }
        undoPrefs = nil
        withAnimation(.snappy) {
            prefs = before
            toast = nil
        }
        prefs.save()
    }

    /// Applies, saves and animates a prefs change. With a toast, the change
    /// can be undone for a few seconds.
    private func updatePrefs(toast text: String? = nil, _ change: (inout Prefs) -> Void) {
        let before = prefs
        var after = prefs
        change(&after)
        guard after != before else { return }

        withAnimation(.snappy) { prefs = after }
        prefs.save()

        guard let text else { return }
        undoPrefs = before
        let toast = Toast(text: text)
        withAnimation(.spring(duration: 0.25)) { self.toast = toast }
        Task {
            try? await Task.sleep(nanoseconds: Self.toastSeconds * 1_000_000_000)
            // A newer toast replaced this one; leave it alone.
            guard self.toast == toast else { return }
            withAnimation(.spring(duration: 0.25)) { self.toast = nil }
            undoPrefs = nil
        }
    }
}

/// "now", "5m", "3h", "2d", "4w".
func ago(_ date: Date, now: Date = Date()) -> String {
    let seconds = max(0, Int(now.timeIntervalSince(date)))
    switch seconds {
    case ..<60: return "now"
    case ..<3600: return "\(seconds / 60)m"
    case ..<86_400: return "\(seconds / 3600)h"
    case ..<604_800: return "\(seconds / 86_400)d"
    default: return "\(seconds / 604_800)w"
    }
}
