import Cocoa
import FlutterMacOS
import IOKit
import IOKit.hid

/// DJ consoles that are USB HID devices, on a Mac without the Hercules driver.
///
/// A Hercules RMX has no MIDI interface; its driver (an old kernel extension that no
/// current macOS loads) was what made one. What the console itself has is a HID
/// interface that says the state of every button and knob in one 25-byte report, and
/// an output report for the lights. IOKit's HID manager hands the one to us and takes
/// the other, with no driver and no entitlement: the app is not sandboxed, and a DJ
/// console is not a keyboard, so Input Monitoring is not asked for. The layout that
/// gives the bytes their meaning lives on the Dart side.
///
/// Same channels as Android's Hid.kt, so the Dart transport is one class for both:
/// `muse/hid` (list / open / write / close), `muse/hid/packets` (every report, as
/// {id, bytes}, report id first as hidraw gives it), `muse/hid/changes` (something was
/// plugged in or pulled out).
final class Hid: NSObject {
  private var manager: IOHIDManager?
  private var sessions: [String: Session] = [:]
  fileprivate var packets: FlutterEventSink?
  fileprivate var changes: FlutterEventSink?

  /// Wires the three channels and keeps the handlers alive.
  static func register(with messenger: FlutterBinaryMessenger) -> Hid {
    let hid = Hid()
    let method = FlutterMethodChannel(name: "muse/hid", binaryMessenger: messenger)
    method.setMethodCallHandler { [hid] call, result in hid.handle(call, result) }
    FlutterEventChannel(name: "muse/hid/packets", binaryMessenger: messenger)
      .setStreamHandler(SinkHandler { [hid] sink in hid.packets = sink })
    FlutterEventChannel(name: "muse/hid/changes", binaryMessenger: messenger)
      .setStreamHandler(SinkHandler { [hid] sink in
        hid.changes = sink
        if sink != nil { _ = hid.start() }
      })
    return hid
  }

  func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "list":
      result(list())
    case "open":
      open(args["id"] as? String ?? "", result)
    case "write":
      guard let id = args["id"] as? String, let s = sessions[id] else {
        result(FlutterError(code: "closed", message: "\(args["id"] ?? "?") is not open", details: nil))
        return
      }
      if let bytes = args["bytes"] as? FlutterStandardTypedData { s.write(bytes.data) }
      result(nil)
    case "close":
      if let id = args["id"] as? String { sessions.removeValue(forKey: id)?.close() }
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: the manager

  /// One HID manager, matching every device, never opened: opening it would open every
  /// keyboard and mouse too, and that is what makes macOS ask for Input Monitoring. It
  /// is only for the list and for hearing about plugs and pulls; each console is opened
  /// on its own.
  private func start() -> IOHIDManager {
    if let m = manager { return m }
    let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    IOHIDManagerSetDeviceMatching(m, nil)
    let ctx = Unmanaged.passUnretained(self).toOpaque()
    IOHIDManagerRegisterDeviceMatchingCallback(m, { ctx, _, _, _ in
      guard let ctx = ctx else { return }
      Unmanaged<Hid>.fromOpaque(ctx).takeUnretainedValue().changed()
    }, ctx)
    IOHIDManagerRegisterDeviceRemovalCallback(m, { ctx, _, _, device in
      guard let ctx = ctx else { return }
      let hid = Unmanaged<Hid>.fromOpaque(ctx).takeUnretainedValue()
      hid.removed(Hid.key(of: device))
      hid.changed()
    }, ctx)
    IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
    manager = m
    return m
  }

  private func devices() -> [IOHIDDevice] {
    let m = start()
    guard let set = IOHIDManagerCopyDevices(m) as? Set<IOHIDDevice> else { return [] }
    return Array(set)
  }

  /// Every HID device there is, with what the Dart side filters on. Keyboards and
  /// mice are in here too; the layout and a few DJ words sort them out over there.
  private func list() -> [[String: Any]] {
    devices().map { d in
      var row: [String: Any] = ["id": Hid.key(of: d), "name": Hid.name(of: d)]
      if let v = Hid.int(d, kIOHIDVendorIDKey) { row["vid"] = v }
      if let p = Hid.int(d, kIOHIDProductIDKey) { row["pid"] = p }
      if let u = Hid.int(d, kIOHIDPrimaryUsagePageKey) { row["usagePage"] = u }
      if let u = Hid.int(d, kIOHIDPrimaryUsageKey) { row["usage"] = u }
      if let n = Hid.int(d, kIOHIDMaxInputReportSizeKey) { row["inputSize"] = n }
      return row
    }
  }

  private func find(_ id: String) -> IOHIDDevice? {
    devices().first { Hid.key(of: $0) == id }
  }

  private func open(_ id: String, _ result: @escaping FlutterResult) {
    if sessions[id] != nil { result(true); return }
    guard let device = find(id) else { result(false); return }
    let r = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
    guard r == kIOReturnSuccess else {
      let why: String
      switch UInt32(bitPattern: r) {
      case 0xE000_02E2:   // kIOReturnNotPermitted
        why = "macOS would not let the app at this device. If it is a keyboard-like one, "
          + "System Settings › Privacy & Security › Input Monitoring is where WetOwl is allowed."
      case 0xE000_02C5:   // kIOReturnExclusiveAccess
        why = "another program has this device open (Mixxx, Traktor, the Hercules control panel?)"
      default:
        why = String(format: "IOHIDDeviceOpen failed (0x%08x)", UInt32(bitPattern: r))
      }
      result(FlutterError(code: "open", message: why, details: nil))
      return
    }
    let s = Session(id: id, device: device, owner: self)
    sessions[id] = s
    s.start()
    result(true)
  }

  fileprivate func removed(_ id: String) {
    sessions.removeValue(forKey: id)?.close()
  }

  fileprivate func changed() {
    changes?(nil)
  }

  fileprivate func packet(id: String, bytes: Data) {
    packets?(["id": id, "bytes": FlutterStandardTypedData(bytes: bytes)])
  }

  // MARK: properties

  /// Stable while the device stays plugged in: its registry entry id.
  fileprivate static func key(of d: IOHIDDevice) -> String {
    let service = IOHIDDeviceGetService(d)
    var entry: UInt64 = 0
    if service != 0, IORegistryEntryGetRegistryEntryID(service, &entry) == KERN_SUCCESS, entry != 0 {
      return String(entry)
    }
    let v = int(d, kIOHIDVendorIDKey) ?? 0
    let p = int(d, kIOHIDProductIDKey) ?? 0
    return String(format: "%04x:%04x", v, p)
  }

  fileprivate static func name(of d: IOHIDDevice) -> String {
    let product = string(d, kIOHIDProductKey)
    let maker = string(d, kIOHIDManufacturerKey)
    switch (maker, product) {
    case let (m?, p?) where !p.lowercased().hasPrefix(m.lowercased()): return "\(m) \(p)"
    case let (_, p?): return p
    case let (m?, _): return m
    default: return "HID device"
    }
  }

  fileprivate static func int(_ d: IOHIDDevice, _ key: String) -> Int? {
    (IOHIDDeviceGetProperty(d, key as CFString) as? NSNumber)?.intValue
  }

  private static func string(_ d: IOHIDDevice, _ key: String) -> String? {
    let s = (IOHIDDeviceGetProperty(d, key as CFString) as? String)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return (s?.isEmpty ?? true) ? nil : s
  }

  // MARK: one open console

  /// Reports arrive on the main run loop, where the sinks want them anyway.
  private final class Session {
    let id: String
    let device: IOHIDDevice
    unowned let owner: Hid
    private let size: Int
    private let buffer: UnsafeMutablePointer<UInt8>

    init(id: String, device: IOHIDDevice, owner: Hid) {
      self.id = id
      self.device = device
      self.owner = owner
      size = max(Hid.int(device, kIOHIDMaxInputReportSizeKey) ?? 64, 64)
      buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
    }

    deinit { buffer.deallocate() }

    func start() {
      let ctx = Unmanaged.passUnretained(self).toOpaque()
      IOHIDDeviceRegisterInputReportCallback(device, buffer, size, { ctx, result, _, _, reportId, report, length in
        guard let ctx = ctx, result == kIOReturnSuccess, length > 0 else { return }
        let s = Unmanaged<Session>.fromOpaque(ctx).takeUnretainedValue()
        // IOKit gives a numbered report with its id in front, as hidraw does, which is
        // what the layouts count bytes from. Should a device's id ever be missing, put
        // it there, so the Dart side sees one shape.
        var bytes = Data(bytes: report, count: length)
        if reportId != 0 && bytes[0] != UInt8(truncatingIfNeeded: reportId) {
          bytes.insert(UInt8(truncatingIfNeeded: reportId), at: 0)
        }
        s.owner.packet(id: s.id, bytes: bytes)
      }, ctx)
      IOHIDDeviceRegisterRemovalCallback(device, { ctx, _, _ in
        guard let ctx = ctx else { return }
        let s = Unmanaged<Session>.fromOpaque(ctx).takeUnretainedValue()
        s.owner.removed(s.id)
        s.owner.changed()
      }, ctx)
      IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
    }

    /// An output report: the id in front, as hidraw takes it. Report 0 means the
    /// device does not number them, and the id byte stays here (the RMX's lights);
    /// a numbered one goes whole, which is what IOKit expects — hidapi does the same.
    func write(_ bytes: Data) {
      guard !bytes.isEmpty else { return }
      let reportId = bytes[bytes.startIndex]
      let payload = reportId == 0 ? Data(bytes.dropFirst()) : bytes
      guard !payload.isEmpty else { return }
      payload.withUnsafeBytes { raw in
        guard let p = raw.bindMemory(to: UInt8.self).baseAddress else { return }
        _ = IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(reportId), p, payload.count)
      }
    }

    func close() {
      IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
      _ = IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
    }
  }
}

/// An event channel's end, handed to whoever keeps the sink.
private final class SinkHandler: NSObject, FlutterStreamHandler {
  private let set: (FlutterEventSink?) -> Void
  init(_ set: @escaping (FlutterEventSink?) -> Void) { self.set = set }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    set(events)
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    set(nil)
    return nil
  }
}
