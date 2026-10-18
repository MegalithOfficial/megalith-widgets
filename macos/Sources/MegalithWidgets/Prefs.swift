import Foundation

// Same JSON shape as src/prefs.rs in the Linux app. Unknown keys are
// ignored on both sides, including the macOS-only placement settings.

enum Appearance: String, Codable, CaseIterable {
    case system, dark, light
}

enum Corner: String, Codable, CaseIterable {
    case topLeft = "top-left"
    case topRight = "top-right"
    case bottomLeft = "bottom-left"
    case bottomRight = "bottom-right"
    case custom
}

struct Settings: Codable, Equatable {
    var notifications = true
    var showDrafts = true
    var refreshMinutes = 2
    var appearance = Appearance.system
    var corner = Corner.topLeft
    var automaticPlacement = true
    var customX = 10
    var customY = 10
    var customPositionSet: Bool? = false

    var hasCustomPosition: Bool { customPositionSet ?? (corner == .custom) }

    enum CodingKeys: String, CodingKey {
        case notifications
        case showDrafts = "show_drafts"
        case refreshMinutes = "refresh_minutes"
        case automaticPlacement = "automatic_placement"
        case customX = "custom_x"
        case customY = "custom_y"
        case customPositionSet = "custom_position_set"
        case appearance, corner
    }

    init() {}

    /// Missing keys fall back to defaults, so older files keep loading.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Settings()
        notifications = try container.decodeIfPresent(Bool.self, forKey: .notifications) ?? defaults.notifications
        showDrafts = try container.decodeIfPresent(Bool.self, forKey: .showDrafts) ?? defaults.showDrafts
        refreshMinutes = try container.decodeIfPresent(Int.self, forKey: .refreshMinutes) ?? defaults.refreshMinutes
        appearance = try container.decodeIfPresent(Appearance.self, forKey: .appearance) ?? defaults.appearance
        corner = try container.decodeIfPresent(Corner.self, forKey: .corner) ?? defaults.corner
        automaticPlacement = try container.decodeIfPresent(Bool.self, forKey: .automaticPlacement) ?? defaults.automaticPlacement
        customX = try container.decodeIfPresent(Int.self, forKey: .customX) ?? defaults.customX
        customY = try container.decodeIfPresent(Int.self, forKey: .customY) ?? defaults.customY
        customPositionSet = try container.decodeIfPresent(Bool.self, forKey: .customPositionSet)
    }
}

struct Prefs: Codable, Equatable {
    var settings = Settings()
    /// PR node ids kept at the top of every list.
    private(set) var pinned: Set<String> = []
    /// PR node ids that are never shown or announced again.
    private(set) var ignored: Set<String> = []
    /// `owner/repo` names switched off in settings.
    private(set) var unwatched: Set<String> = []
    private(set) var addedRepositories: Set<String> = []

    enum CodingKeys: String, CodingKey {
        case settings, pinned, ignored, unwatched
        case addedRepositories = "added_repositories"
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        settings = try container.decodeIfPresent(Settings.self, forKey: .settings) ?? Settings()
        pinned = try container.decodeIfPresent(Set<String>.self, forKey: .pinned) ?? []
        ignored = try container.decodeIfPresent(Set<String>.self, forKey: .ignored) ?? []
        unwatched = try container.decodeIfPresent(Set<String>.self, forKey: .unwatched) ?? []
        addedRepositories = try container.decodeIfPresent(Set<String>.self, forKey: .addedRepositories) ?? []
    }

    static var fileURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("megalith-widgets/prefs.json")
    }

    static func load() -> Prefs {
        guard let data = try? Data(contentsOf: fileURL) else { return Prefs() }
        do {
            return try JSONDecoder().decode(Prefs.self, from: data)
        } catch {
            print("ignoring unreadable \(fileURL.path): \(error)")
            return Prefs()
        }
    }

    func save() {
        do {
            try FileManager.default.createDirectory(
                at: Self.fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            // Atomic write: a crash never leaves a truncated file behind.
            try encoder.encode(self).write(to: Self.fileURL, options: .atomic)
        } catch {
            print("couldn't save \(Self.fileURL.path): \(error)")
        }
    }

    func isPinned(_ pr: PullRequest) -> Bool {
        pinned.contains(pr.id)
    }

    /// Ignored PRs and PRs from unwatched repositories are never shown or announced.
    func isHidden(_ pr: PullRequest) -> Bool {
        ignored.contains(pr.id) || !isWatched(pr.repo)
    }

    /// Whether the PR belongs on screen at all, given hides and settings.
    func isVisible(_ pr: PullRequest) -> Bool {
        !isHidden(pr) && (settings.showDrafts || pr.state != .draft)
    }

    func isWatched(_ repo: String) -> Bool {
        !unwatched.contains { $0.caseInsensitiveCompare(repo) == .orderedSame }
    }

    mutating func setPinned(_ pr: PullRequest, _ pinned: Bool) {
        if pinned {
            self.pinned.insert(pr.id)
        } else {
            self.pinned.remove(pr.id)
        }
    }

    mutating func ignore(_ pr: PullRequest) {
        ignored.insert(pr.id)
        pinned.remove(pr.id)
    }

    mutating func unignoreAll() {
        ignored.removeAll()
    }

    mutating func setWatched(_ repo: String, _ watched: Bool) {
        if watched {
            unwatched = unwatched.filter { $0.caseInsensitiveCompare(repo) != .orderedSame }
        } else if isWatched(repo) {
            unwatched.insert(repo)
        }
    }

    mutating func addRepository(_ repo: String) {
        setWatched(repo, true)
        if !addedRepositories.contains(where: { $0.caseInsensitiveCompare(repo) == .orderedSame }) {
            addedRepositories.insert(repo)
        }
    }

    /// Ignored PRs among `prs` that would otherwise be shown.
    func ignoredCount(in prs: [PullRequest]) -> Int {
        prs.filter { isWatched($0.repo) && ignored.contains($0.id) }.count
    }

    /// Repositories seen in `prs` plus any switched off, sorted for display.
    func repositories(in prs: [PullRequest]) -> [String] {
        var repos: [String: String] = [:]
        for repo in Array(addedRepositories) + Array(unwatched) + prs.map(\.repo) {
            repos[repo.lowercased()] = repo
        }
        return repos.sorted { $0.key < $1.key }.map(\.value)
    }

    /// Forgets pins for PRs that are gone. Ignores are kept, so a reopened
    /// PR stays ignored. Returns whether anything was dropped.
    mutating func prune(keeping prs: [PullRequest]) -> Bool {
        let ids = Set(prs.map(\.id))
        let before = pinned.count
        pinned.formIntersection(ids)
        return before != pinned.count
    }
}
