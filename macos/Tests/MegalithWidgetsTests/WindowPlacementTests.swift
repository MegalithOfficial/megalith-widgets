import XCTest
@testable import MegalithWidgets

final class WindowPlacementTests: XCTestCase {
    private let area = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private let size = CGSize(width: 760, height: 300)

    func testEmptyDesktopUsesSelectedCorner() {
        let expected: [(Corner, CGPoint)] = [
            (.topLeft, CGPoint(x: 10, y: 590)),
            (.topRight, CGPoint(x: 670, y: 590)),
            (.bottomLeft, CGPoint(x: 10, y: 10)),
            (.bottomRight, CGPoint(x: 670, y: 10)),
        ]
        for (corner, point) in expected {
            XCTAssertEqual(WindowPlacement.origin(size: size, in: area, corner: corner, avoiding: []), point)
        }
    }

    func testCalendarWeatherAndPhotoLeaveRoomToTheirRight() throws {
        let widgets = [
            CGRect(x: 10, y: 720, width: 160, height: 160),
            CGRect(x: 190, y: 720, width: 160, height: 160),
            CGRect(x: 10, y: 540, width: 340, height: 160),
        ]
        let origin = try XCTUnwrap(WindowPlacement.origin(size: size, in: area, corner: .topLeft, avoiding: widgets))
        XCTAssertEqual(origin, CGPoint(x: 360, y: 590))
        XCTAssertTrue(widgets.allSatisfy { !$0.intersects(CGRect(origin: origin, size: size)) })
    }

    func testFullWidthWidgetMovesPanelBelowIt() {
        let widget = CGRect(x: 10, y: 700, width: 1420, height: 180)
        XCTAssertEqual(
            WindowPlacement.origin(size: size, in: area, corner: .topLeft, avoiding: [widget]),
            CGPoint(x: 10, y: 390)
        )
    }

    func testNoSpaceReturnsNoPlacement() {
        XCTAssertNil(WindowPlacement.origin(size: size, in: area, corner: .topLeft, avoiding: [area]))
        XCTAssertNil(WindowPlacement.origin(size: size, in: CGRect(x: 0, y: 0, width: 400, height: 200), corner: .topLeft, avoiding: []))
    }

    func testDisplayLeftOfPrimaryKeepsNegativeCoordinates() {
        let display = CGRect(x: -1440, y: 0, width: 1440, height: 900)
        XCTAssertEqual(
            WindowPlacement.origin(size: size, in: display, corner: .topRight, avoiding: []),
            CGPoint(x: -770, y: 590)
        )
    }

    func testQuartzBoundsConvertAcrossDisplays() {
        XCTAssertEqual(
            WindowPlacement.appKitBounds(CGRect(x: -1440, y: -900, width: 160, height: 160), primaryTop: 900),
            CGRect(x: -1440, y: 1640, width: 160, height: 160)
        )
    }

    func testSavedPositionIsClampedAfterDisplayRemoval() {
        XCTAssertEqual(WindowPlacement.clamped(CGPoint(x: -1200, y: 1200), size: size, in: area), CGPoint(x: 0, y: 600))
    }

    func testOldPreferencesDefaultToAutomaticPlacement() throws {
        let settings = try JSONDecoder().decode(Settings.self, from: Data("{\"corner\":\"bottom-right\"}".utf8))
        XCTAssertTrue(settings.automaticPlacement)
        XCTAssertEqual(settings.corner, .bottomRight)
    }

    func testManualPlacementSurvivesPreferencesRoundTrip() throws {
        var settings = Settings()
        settings.automaticPlacement = false
        settings.corner = .custom
        settings.customX = -1200
        settings.customY = 160
        let restored = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings))
        XCTAssertFalse(restored.automaticPlacement)
        XCTAssertEqual(restored.corner, .custom)
        XCTAssertEqual(restored.customX, -1200)
        XCTAssertEqual(restored.customY, 160)
    }
}
