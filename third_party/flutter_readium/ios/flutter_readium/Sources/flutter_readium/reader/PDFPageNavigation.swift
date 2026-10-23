import CoreGraphics
import ReadiumShared

func pdfTargetPageNumber(_ locator: Locator) -> Int? {
  for fragment in locator.locations.fragments {
    for item in fragment.split(separator: "&") {
      if item.hasPrefix("page="), let number = Int(item.dropFirst(5)), number > 0 {
        return number
      }
    }
  }
  return locator.locations.position.flatMap { $0 > 0 ? $0 : nil }
}

func pdfPageTopCorner(_ bounds: CGRect, rotation: Int) -> CGPoint {
  switch (rotation % 360 + 360) % 360 {
  case 90: return CGPoint(x: bounds.minX, y: bounds.minY)
  case 180: return CGPoint(x: bounds.maxX, y: bounds.minY)
  case 270: return CGPoint(x: bounds.maxX, y: bounds.maxY)
  default: return CGPoint(x: bounds.minX, y: bounds.maxY)
  }
}
