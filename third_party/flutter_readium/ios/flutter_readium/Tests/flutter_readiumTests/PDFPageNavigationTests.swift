import XCTest
import ReadiumShared
@testable import flutter_readium

final class PDFPageNavigationTests: XCTestCase {
  func testFragmentOverridesResourcePositionWithoutPageShift() {
    for page in [1, 2, 12, 100] {
      let locator = Locator(
        href: URL(string: "publication.pdf")!, mediaType: .pdf,
        locations: .init(fragments: ["page=\(page)&zoom=100"], position: 1)
      )
      XCTAssertEqual(pdfTargetPageNumber(locator), page)
    }
  }

  func testTopCornerRespectsCropOriginAndPageRotation() {
    let box = CGRect(x: 10, y: 20, width: 600, height: 800)
    XCTAssertEqual(pdfPageTopCorner(box, rotation: 0), CGPoint(x: 10, y: 820))
    XCTAssertEqual(pdfPageTopCorner(box, rotation: 90), CGPoint(x: 10, y: 20))
    XCTAssertEqual(pdfPageTopCorner(box, rotation: 180), CGPoint(x: 610, y: 20))
    XCTAssertEqual(pdfPageTopCorner(box, rotation: 270), CGPoint(x: 610, y: 820))
  }
}
