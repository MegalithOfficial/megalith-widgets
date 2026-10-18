import XCTest
@testable import MegalithWidgets

final class RepositoryTests: XCTestCase {
    func testNamesAndGitHubURLs() {
        for input in [" Pumpkin-MC/Pumpkin ", "https://github.com/Pumpkin-MC/Pumpkin/", "github.com/Pumpkin-MC/Pumpkin.git"] {
            XCTAssertEqual(RepositoryName.normalize(input), "Pumpkin-MC/Pumpkin")
        }
        for input in ["", "Pumpkin", "https://example.com/owner/repo", "owner/repo/pulls", "owner/repo?tab=readme", "owner/..", "owner/repo name"] {
            XCTAssertNil(RepositoryName.normalize(input))
        }
    }

    func testAddedRepositoriesPersistWithoutPullRequests() throws {
        var prefs = Prefs()
        prefs.addRepository("Owner/Repo")
        prefs.setWatched("owner/repo", false)
        XCTAssertFalse(prefs.isWatched("Owner/Repo"))
        prefs.addRepository("OWNER/REPO")
        XCTAssertTrue(prefs.isWatched("owner/repo"))
        XCTAssertEqual(prefs.repositories(in: []).count, 1)
        let encoded = try JSONEncoder().encode(prefs)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNotNil(json["added_repositories"])
        let restored = try JSONDecoder().decode(Prefs.self, from: encoded)
        XCTAssertEqual(restored.repositories(in: []), prefs.repositories(in: []))
    }
}
