import ReadiumNavigator
import ReadiumShared
import Flutter
import UIKit

/// The Flutter method-channel dispatch table, registered as the channel's call
/// handler in `init`. Each case delegates to the relevant `EPUBReaderView+*` extension.
extension EPUBReaderView {

  func onMethodCall(call: FlutterMethodCall, result: @escaping FlutterResult) {
    Log.reader.debug("onMethodCall: \(call.method)")
    switch call.method {
    case "setSelectionHandleColor":
      let tint = (call.arguments as? NSNumber).map { value in
        let argb = value.uint32Value
        return UIColor(
          red: CGFloat((argb >> 16) & 0xff) / 255,
          green: CGFloat((argb >> 8) & 0xff) / 255,
          blue: CGFloat(argb & 0xff) / 255,
          alpha: CGFloat((argb >> 24) & 0xff) / 255
        )
      }
      containerView.tintColor = tint
      readiumViewController.view.tintColor = tint
      result(nil)
    case "evaluateSelectionScript":
      guard let script = call.arguments as? String else {
        result(FlutterError(code: "InvalidArgument", message: "Missing selection script", details: nil))
        return
      }
      Task { @MainActor in
        switch await self.evaluateJavascript(script) {
        case .success(let value): result(value as? String)
        case .failure(let error):
          result(FlutterError(code: "SelectionError", message: error.localizedDescription, details: nil))
        }
      }
    case "clearSelection":
      readiumViewController.clearSelection()
      result(nil)
    case "go":
      let args = call.arguments as? [Any?]
      guard let locatorStr = args?[0] as? String,
            let locator = try? Locator(legacyJSONString: locatorStr, warnings: readiumBugLogger) else {
        Log.reader.warn("go: failed to parse locator argument; ignoring navigation request")
        result(false)
        break
      }
      let animated = args?[1] as? Bool ?? false

      Task.detached(priority: .high) {
        let success = await self.goToLocator(locator, animated: animated)
        await MainActor.run() {
          result(success)
        }
      }
      break
    case "goBackward":
      let animated = call.arguments as? Bool ?? false
      let navOptions = NavigatorGoOptions(animated: animated)
      let readiumViewController = self.readiumViewController
      let scrollMode = self.readiumViewController.presentation.scroll

      Task.detached(priority: .high) {
        await MainActor.run { self.enterManualModeIfNarrationPlaying() }
        let layoutMode = await self.readiumViewController.publication.metadata.layout ?? Layout.reflowable
        let success: Bool
        if (layoutMode == .reflowable && scrollMode == true) {
          success = await self.goBackwardInScrollMode(options: navOptions)
        } else {
          success = await readiumViewController.goBackward(options: navOptions)
        }
        await MainActor.run() {
          result(success)
        }
      }
      break
    case "goForward":
      let animated = call.arguments as? Bool ?? false
      let navOptions = NavigatorGoOptions(animated: animated)
      let readiumViewController = self.readiumViewController
      let scrollMode = self.readiumViewController.presentation.scroll

      Task.detached(priority: .high) {
        await MainActor.run { self.enterManualModeIfNarrationPlaying() }
        let layoutMode = await self.readiumViewController.publication.metadata.layout ?? Layout.reflowable
        let success: Bool
        if (layoutMode == .reflowable && scrollMode == true) {
          success = await self.goForwardInScrollMode(options: navOptions)
        } else {
          success = await readiumViewController.goForward(options: navOptions)
        }
        await MainActor.run() {
          result(success)
        }
      }
      break
    case "notifyUserNavigation":
      // The user swiped or edge-tapped the reader (detected by the Flutter
      // Listener above the platform view). Enter narration manual mode if
      // narration is currently driving the reader; otherwise a no-op.
      Task { @MainActor in
        enterManualModeIfNarrationPlaying()
        result(nil)
      }
      break
    case "setPreferences":
      let args = call.arguments as! [String: Any]
      Log.reader.debug("onMethodCall[setPreferences] args = \(args)")
      let oldDisableSync = self.preferences?.disableSync
      let preferences = FlutterEPUBPreferences.init(fromMap: args)
      setUserPreferences(preferences: preferences)
      self.preferences = preferences
      // Flip the runtime sync flag only on an actual `disableSync` transition.
      // `disableSynchronization` is serialized on every preferences push (non-null on
      // the Dart side), so reacting unconditionally would clobber a manual-mode override
      // set via setNarrationSyncEnabled whenever any unrelated preference (font, theme, …)
      // changes mid-playback.
      if let disableSync = preferences.disableSync, disableSync != oldDisableSync {
        setNarrationSyncEnabled(!disableSync)
      }
      result(nil)
      break
    case "applyDecorations":
      let args = call.arguments as! [Any?]
      let identifier = args[0] as! String
      let decorationsStr = args[1] as! [String]

      guard let decorations = try? decorationsStr.map({ try Decoration(fromJson: $0) }) else {
        return result(FlutterError.init(
          code: "JSON mapping error",
          message: "Could not map decorations from JSON: \(decorationsStr)",
          details: nil))
      }

      applyDecorations(decorations, forGroup: identifier)
      result(nil)
      break
    case "configureSelectionActions":
      let args = call.arguments as! [[String: Any]]
      let actions = args.compactMap { dict -> (id: String, title: String)? in
        guard let id = dict["id"] as? String, let title = dict["title"] as? String else { return nil }
        return (id: id, title: title)
      }
      containerView.configureActions(actions)
      result(nil)
      break
    case "dispose":
      Log.reader.info("Disposing readiumViewController")
      readiumViewController.view.removeFromSuperview()
      readiumViewController.delegate = nil
      FlutterReadiumPlugin.instance?.clearCurrentReaderView(ifIs: self)
      emitReaderStatusChanged(status: ReadiumReaderStatusClosed)
      result(nil)
      break
    default:
      Log.reader.warn("Unhandled call: \(call.method)")
      result(FlutterMethodNotImplemented)
      break
    }
  }
}
