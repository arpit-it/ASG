import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    // Restore saved foundation records before the Flutter engine starts.
    if let identifier = Bundle.main.bundleIdentifier {
      let legacy = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Containers/\(identifier)/Data/Library/Preferences/\(identifier).plist")
      do {
        try Self.restoreLegacyPreferences(from: legacy, into: UserDefaults.standard)
      } catch {
        let alert = NSAlert()
        alert.messageText = "Unable to read saved Studio settings"
        alert.informativeText = "Your previous settings have not been changed. Resolve access to the previous app container before continuing."
        alert.runModal()
        NSApplication.shared.terminate(nil)
        return
      }
    }
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }

  static func restoreLegacyPreferences(from source: URL, into defaults: UserDefaults) throws {
    guard FileManager.default.fileExists(atPath: source.path) else { return }
    let data = try Data(contentsOf: source)
    guard let values = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
      throw CocoaError(.fileReadCorruptFile)
    }
    for (key, value) in values where key.hasPrefix("flutter.studio.") || key.hasPrefix("studio.") {
      if defaults.object(forKey: key) == nil { defaults.set(value, forKey: key) }
    }
  }
}
