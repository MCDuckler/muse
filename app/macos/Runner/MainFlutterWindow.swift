import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  /// DJ consoles that are HID devices — the Hercules RMX without its driver. See Hid.swift.
  private var hid: Hid?

  override func awakeFromNib() {
    // Flutter on a Mac hands main() nothing of the command line. The stage window lives
    // on it: `WetOwl --stage <url>`, started by the WetOwl Desk or by the booth's pop-out
    // (stage_window.dart). What macOS adds itself (-psn_…, -NS… defaults) stays out.
    let args = Array(CommandLine.arguments.dropFirst()).filter {
      !$0.hasPrefix("-psn_") && !$0.hasPrefix("-NS") && !$0.hasPrefix("-Apple")
    }
    let project = FlutterDartProject()
    project.dartEntrypointArguments = args
    let flutterViewController = FlutterViewController(project: project)
    self.contentViewController = flutterViewController

    // A size worth opening at the first time — the desk layout, with the dock beside the
    // library — and after that wherever it was left: the frame is saved under this name
    // and put back by the system. A stage window keeps its own, not the app's.
    let frameName = args.contains("--stage") ? "WetOwl Stage" : "WetOwl"
    self.minSize = NSSize(width: 380, height: 560)
    if !self.setFrameUsingName(frameName) {
      let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
      let size = NSSize(width: min(1320, screen.width * 0.9), height: min(860, screen.height * 0.9))
      self.setFrame(
        NSRect(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2,
               width: size.width, height: size.height),
        display: true)
    }
    self.setFrameAutosaveName(frameName)

    RegisterGeneratedPlugins(registry: flutterViewController)
    hid = Hid.register(with: flutterViewController.engine.binaryMessenger)

    super.awakeFromNib()
  }
}
