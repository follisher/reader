import Foundation
import ReadiumNavigator
import ReadiumShared

/// Maps the Dart PDFPreferences JSON map to ReadiumNavigator's
/// PDFNavigatorViewController.Preferences for runtime updates.
struct FlutterPDFPreferences {
  var readium: PDFNavigatorViewController.Preferences = .init()

  init() {}

  init(fromMap map: [String: Any]) {
    var prefs = PDFNavigatorViewController.Preferences()
    // Horizontal reading turns one page at a time and snaps on release.
    // Keep "paginated" as a compatibility alias for previously saved settings.
    if let layoutString = map["layout"] as? String {
      switch layoutString {
      case "paginated", "scrollHorizontal":
        prefs.scroll = false
        prefs.scrollAxis = .horizontal
      case "scrollVertical":
        prefs.scroll = true
        prefs.scrollAxis = .vertical
      default:
        break
      }
    }
    if let rpString = map["readingProgression"] as? String,
       let rp = ReadiumNavigator.ReadingProgression(rawValue: rpString) {
      prefs.readingProgression = rp
    }
    if let fitString = map["fit"] as? String,
       let fit = ReadiumNavigator.Fit(rawValue: fitString) {
      prefs.fit = fit
    }
    if let pageSpacing = map["pageSpacing"] as? NSNumber {
      prefs.pageSpacing = pageSpacing.doubleValue
    }
    if let offsetFirstPage = map["offsetFirstPage"] as? Bool {
      prefs.offsetFirstPage = offsetFirstPage
    }
    if let spreadString = map["spread"] as? String,
       let spread = ReadiumNavigator.Spread(rawValue: spreadString) {
      prefs.spread = spread
    }
    if let visibleScrollbar = map["visibleScrollbar"] as? Bool {
      prefs.visibleScrollbar = visibleScrollbar
    }
    readium = prefs
  }
}
