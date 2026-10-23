import XCTest
@testable import flutter_readium

final class FlutterPDFPreferencesTests: XCTestCase {
  func testHorizontalAndLegacyPaginatedSnapToPages() {
    for layout in ["scrollHorizontal", "paginated"] {
      let preferences = FlutterPDFPreferences(fromMap: ["layout": layout]).readium
      XCTAssertEqual(preferences.scroll, false)
      XCTAssertEqual(preferences.scrollAxis, .horizontal)
    }
  }

  func testVerticalRemainsContinuousWithPageSpacing() {
    let preferences = FlutterPDFPreferences(fromMap: [
      "layout": "scrollVertical",
      "pageSpacing": 8,
    ]).readium
    XCTAssertEqual(preferences.scroll, true)
    XCTAssertEqual(preferences.scrollAxis, .vertical)
    XCTAssertEqual(preferences.pageSpacing, 8)
  }
}
