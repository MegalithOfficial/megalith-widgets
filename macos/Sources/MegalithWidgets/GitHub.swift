import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Mirrors src/github.rs in the Linux app: same query, same classification.

enum PRState: String, Hashable {
    case open, draft, merged, closed
}

enum Mergeable: Hashable {
    case clean, conflicting, unknown
}

enum Checks: Hashable {
    case none, pending, passing, failing
}

enum ReviewStatus: String, Hashable {
    /// Review requested and you have never reviewed it.
    case requested
    /// You reviewed it before and were asked again.
    case reReview
    /// You reviewed it and the author pushed since.
    case newCommits
    /// Merged or closed after it was on your list.
    case done
}

struct PullRequest: Identifiable, Hashable {
    let id: String
    let number: Int
    let title: String
    let url: URL
    let repo: String
    let author: String
    let avatarURL: URL?
    let state: PRState
    let mergeable: Mergeable
    let checks: Checks
    let updatedAt: Date
    let closedAt: Date?
    let additions: Int
    let deletions: Int
    let headOid: String
    let status: ReviewStatus
    /// Commits pushed after your last review; 0 when unknown (e.g. force-push).
    let newCommits: Int

    /// Changes whenever the PR needs your attention again.
    var attentionKey: String { "\(id):\(status.rawValue):\(headOid)" }

    var shortRepo: String { repo.split(separator: "/").last.map(String.init) ?? repo }

    /// When it last mattered: closing time for finished PRs, activity otherwise.
    var relevantDate: Date { status == .done ? (closedAt ?? updatedAt) : updatedAt }
}

struct Snapshot {
    /// Open PRs waiting on you, newest activity first.
    var open: [PullRequest]
    /// Previously tracked PRs that have since been merged or closed.
    var done: [PullRequest]
}

enum GitHubError: LocalizedError {
    case noToken
    case rejected
    case http(Int)
    case api(String)

    var errorDescription: String? {
        switch self {
        case .noToken: "Not signed in. Run `gh auth login`."
        case .rejected: "GitHub rejected the token. Run `gh auth login`."
        case .http(let code): "GitHub returned HTTP \(code)."
        case .api(let message): "GitHub: \(message)"
        }
    }
}

enum GitHub {
    static let reviewQueue = URL(string: "https://github.com/pulls/review-requested")!

    private static let endpoint = URL(string: "https://api.github.com/graphql")!
    private static let requestedQuery = "is:pr is:open archived:false review-requested:@me"
    private static let reviewedQuery = "is:pr is:open archived:false reviewed-by:@me -author:@me"

    private static let query = """
    query($requested: String!, $reviewed: String!, $gone: [ID!]!) {
      requested: search(query: $requested, type: ISSUE, first: 40) { nodes { ...pr } }
      reviewed: search(query: $reviewed, type: ISSUE, first: 40) { nodes { ...pr } }
      gone: nodes(ids: $gone) { ...pr }
    }
    fragment pr on PullRequest {
      id number title url isDraft updatedAt closedAt additions deletions headRefOid state mergeable
      repository { nameWithOwner }
      author { login avatarUrl(size: 96) }
      reviews(last: 50) { nodes { viewerDidAuthor state commit { oid } } }
      commits(last: 50) { nodes { commit { oid } } }
      latest: commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
    }
    """

    /// `tracked` are the ids currently on screen, so anything that drops off
    /// the open lists can be reported as done.
    static func fetch(tracked: [String]) async throws -> Snapshot {
        let token = try token()

        var request = URLRequest(url: endpoint, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("megalith-widgets", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "query": query,
            "variables": ["requested": requestedQuery, "reviewed": reviewedQuery, "gone": tracked],
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw http.statusCode == 401 ? GitHubError.rejected : GitHubError.http(http.statusCode)
        }
        return try parse(data)
    }

    /// Split out from `fetch` so it can be exercised with a recorded response.
    static func parse(_ data: Data) throws -> Snapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let response = try decoder.decode(Response.self, from: data)

        if let error = response.errors?.first {
            throw GitHubError.api(error.message)
        }
        guard let payload = response.data else {
            throw GitHubError.api("no data")
        }

        var seen = Set<String>()
        let candidates = payload.requested.nodes.map { ($0, true) } + payload.reviewed.nodes.map { ($0, false) }
        let open = candidates
            .filter { seen.insert($0.0.id).inserted }
            .compactMap { classify($0.0, requested: $0.1) }
            .sorted { $0.updatedAt > $1.updatedAt }

        let done = payload.gone
            .compactMap { $0 }
            .filter { $0.state == "MERGED" || $0.state == "CLOSED" }
            .compactMap { classify($0, requested: false) }

        return Snapshot(open: open, done: done)
    }

    /// Prefers `GITHUB_TOKEN`, then the GitHub CLI. Apps launched from Finder
    /// don't inherit the shell's PATH, so the usual install locations are tried.
    static func token() throws -> String {
        if let token = ProcessInfo.processInfo.environment["GITHUB_TOKEN"], !token.isEmpty {
            return token
        }
        let candidates = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
        guard let gh = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) else {
            throw GitHubError.noToken
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: gh)
        process.arguments = ["auth", "token"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()

        let data = output.fileHandleForReading.readDataToEndOfFile()
        let token = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0, !token.isEmpty else {
            throw GitHubError.noToken
        }
        return token
    }

    private static func classify(_ node: Node, requested: Bool) -> PullRequest? {
        let state: PRState = switch node.state {
        case "MERGED": .merged
        case "CLOSED": .closed
        default: node.isDraft ? .draft : .open
        }

        let reviewedOid = node.reviews.nodes
            .last { $0.viewerDidAuthor && $0.state != "PENDING" }?
            .commit?.oid

        let status: ReviewStatus
        if state == .merged || state == .closed {
            status = .done
        } else if requested {
            status = reviewedOid == nil ? .requested : .reReview
        } else if let reviewedOid, reviewedOid != node.headRefOid {
            status = .newCommits
        } else {
            return nil
        }

        let commits = node.commits.nodes.map(\.commit.oid)
        let newCommits = reviewedOid
            .flatMap { oid in commits.firstIndex(of: oid) }
            .map { commits.count - $0 - 1 } ?? 0

        let mergeable: Mergeable = switch node.mergeable {
        case "MERGEABLE": .clean
        case "CONFLICTING": .conflicting
        default: .unknown
        }

        let checks: Checks = switch node.latest.nodes.first?.commit.statusCheckRollup?.state {
        case nil: .none
        case "SUCCESS": .passing
        case "FAILURE", "ERROR": .failing
        default: .pending
        }

        guard let url = URL(string: node.url) else { return nil }
        return PullRequest(
            id: node.id,
            number: node.number,
            title: node.title,
            url: url,
            repo: node.repository.nameWithOwner,
            author: node.author?.login ?? "ghost",
            avatarURL: node.author.flatMap { URL(string: $0.avatarUrl) },
            state: state,
            mergeable: mergeable,
            checks: checks,
            updatedAt: node.updatedAt,
            closedAt: node.closedAt,
            additions: node.additions,
            deletions: node.deletions,
            headOid: node.headRefOid,
            status: status,
            newCommits: newCommits
        )
    }
}

// MARK: - Response shape

private struct Response: Decodable {
    let data: Payload?
    let errors: [GraphQLError]?
}

private struct GraphQLError: Decodable {
    let message: String
}

private struct Payload: Decodable {
    let requested: Search
    let reviewed: Search
    let gone: [Node?]
}

private struct Search: Decodable {
    let nodes: [Node]
}

private struct Connection<T: Decodable>: Decodable {
    let nodes: [T]
}

private struct Node: Decodable {
    let id: String
    let number: Int
    let title: String
    let url: String
    let isDraft: Bool
    let updatedAt: Date
    let closedAt: Date?
    let additions: Int
    let deletions: Int
    let headRefOid: String
    let state: String
    let mergeable: String
    let repository: Repository
    let author: Author?
    let reviews: Connection<Review>
    let commits: Connection<CommitNode>
    let latest: Connection<LatestCommit>
}

private struct Repository: Decodable {
    let nameWithOwner: String
}

private struct Author: Decodable {
    let login: String
    let avatarUrl: String
}

private struct Review: Decodable {
    let viewerDidAuthor: Bool
    let state: String
    let commit: Oid?
}

private struct CommitNode: Decodable {
    let commit: Oid
}

private struct Oid: Decodable {
    let oid: String
}

private struct LatestCommit: Decodable {
    let commit: CheckedCommit
}

private struct CheckedCommit: Decodable {
    let statusCheckRollup: Rollup?
}

private struct Rollup: Decodable {
    let state: String
}
