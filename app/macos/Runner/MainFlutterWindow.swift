import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController

    // A size worth opening at the first time — the desk layout, with the dock beside the
    // library — and after that wherever it was left: the frame is saved under this name
    // and put back by the system.
    self.minSize = NSSize(width: 380, height: 560)
    if !self.setFrameUsingName("WetOwl") {
      let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
      let size = NSSize(width: min(1320, screen.width * 0.9), height: min(860, screen.height * 0.9))
      self.setFrame(
        NSRect(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2,
               width: size.width, height: size.height),
        display: true)
    }
    self.setFrameAutosaveName("WetOwl")

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
