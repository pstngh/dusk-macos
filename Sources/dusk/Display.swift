// No dithering on external displays: an 8-bit link (RGB full range when offered) and enableDither = No.

import CoreGraphics
import Foundation
import IOKit
import XPC

// MARK: - Private API (resolved at runtime; nil if a macOS update removes it)

func sym<T>(_ lib: String, _ name: String, _: T.Type) -> T? {
    guard let handle = dlopen(lib, RTLD_LAZY), let p = dlsym(handle, name) else { return nil }
    return unsafeBitCast(p, to: T.self)
}

private let skyLight = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
private let ioKit = "/System/Library/Frameworks/IOKit.framework/IOKit"

private let SLSGetCurrentDisplayMode = sym(skyLight, "SLSGetCurrentDisplayMode",
    (@convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Int32>) -> CGError).self)
// (display, mode, LinkDescription *out, int *inOutCount, int *outCurrentIndex)
private let SLSGetDisplayOutputModeLinkDescriptions = sym(skyLight, "SLSGetDisplayOutputModeLinkDescriptions",
    (@convention(c) (CGDirectDisplayID, Int32, UnsafeMutableRawPointer, UnsafeMutablePointer<Int32>, UnsafeMutablePointer<Int32>) -> CGError).self)
// (config, display, LinkDescription): the 16-byte struct is passed by value in two registers.
private let SLSConfigureDisplayOutputMode = sym(skyLight, "SLSConfigureDisplayOutputMode",
    (@convention(c) (CGDisplayConfigRef, CGDirectDisplayID, UInt64, UInt64) -> CGError).self)

private let IOAVVideoInterfaceCreateWithService = sym(ioKit, "IOAVVideoInterfaceCreateWithService",
    (@convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?).self)
private let IOAVVideoInterfaceCopyDisplayAttributes = sym(ioKit, "IOAVVideoInterfaceCopyDisplayAttributes",
    (@convention(c) (CFTypeRef) -> Unmanaged<CFDictionary>?).self)
private let IOAVVideoInterfaceGetLinkData = sym(ioKit, "IOAVVideoInterfaceGetLinkData",
    (@convention(c) (CFTypeRef, UnsafeMutableRawPointer) -> IOReturn).self)

/// WindowServer's description of a display link ("output mode").
struct LinkDescription: Equatable {
    var bitDepth: UInt32
    var range: UInt32     // 1 = full, 0 = limited
    var eotf: UInt32      // 0 = SDR
    var encoding: UInt32  // 0 = RGB, 1 = YCbCr 4:4:4, 2 = YCbCr 4:2:2

    static let zero = LinkDescription(bitDepth: 0, range: 0, eotf: 0, encoding: 0)

    var name: String {
        let encodings: [UInt32: String] = [0: "RGB", 1: "YCbCr 4:4:4", 2: "YCbCr 4:2:2"]
        return "\(bitDepth)-bit \(encodings[encoding] ?? "encoding \(encoding)"), \(range == 1 ? "full" : "limited") range"
    }
}

/// Set when any step fails; becomes the exit status, which `launchctl print` shows.
var failed = false
func fail(_ message: String) {
    print(message)
    failed = true
}

// MARK: - IORegistry

/// All services of an IOKit class; the caller releases them.
func services(_ cls: String) -> [io_service_t] {
    var iter: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(cls), &iter) == KERN_SUCCESS else { return [] }
    defer { IOObjectRelease(iter) }
    return Array(AnyIterator { let s = IOIteratorNext(iter); return s == 0 ? nil : s })
}

func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
    IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
}

/// A monitor from DisplayAttributes.ProductAttributes. The framebuffer, the DCP video interface
/// and CoreGraphics all report the same product ID and serial, which ties the three together.
struct Monitor {
    let id: String
    let name: String

    init?(_ displayAttributes: Any?) {
        guard let p = (displayAttributes as? [String: Any])?["ProductAttributes"] as? [String: Any] else { return nil }
        id = "\(p["ProductID"] as? Int ?? 0)/\(p["SerialNumber"] as? Int ?? 0)"
        name = p["ProductName"] as? String ?? "display \(id)"
    }

    static func id(_ display: CGDirectDisplayID) -> String {
        "\(CGDisplayModelNumber(display))/\(CGDisplaySerialNumber(display))"
    }
}

/// External display pipes, matched via IOMobileFramebufferAP (the parent class of AppleCLCD2 and
/// IOMobileFramebufferShim). `monitor` is nil when nothing is connected.
func externalFramebuffers() -> [(service: io_service_t, monitor: Monitor?)] {
    services("IOMobileFramebufferAP").compactMap { service in
        guard property(service, "external") as? Bool == true else { IOObjectRelease(service); return nil }
        return (service, Monitor(property(service, "DisplayAttributes")))
    }
}

/// Current link per monitor id, as reported by the display coprocessor (DCP) itself.
func currentLinks() -> [String: String] {
    guard let create = IOAVVideoInterfaceCreateWithService, let copyAttributes = IOAVVideoInterfaceCopyDisplayAttributes,
          let getLinkData = IOAVVideoInterfaceGetLinkData else { return [:] }
    let encodings: [UInt32: String] = [0: "RGB", 2: "YCbCr 4:2:2", 3: "YCbCr 4:4:4"]
    var links: [String: String] = [:]
    for service in services("DCPAVVideoInterfaceProxy") {
        defer { IOObjectRelease(service) }
        guard let iface = create(kCFAllocatorDefault, service)?.takeRetainedValue(),
              let monitor = Monitor(copyAttributes(iface)?.takeRetainedValue()) else { continue }
        // The active color element starts at offset 8: depth, pixel encoding, dynamic range (0 = full), ...
        var data = [UInt32](repeating: 0, count: 64)
        guard getLinkData(iface, &data) == kIOReturnSuccess, data[2] != 0 else { continue }
        links[monitor.id] = "\(data[2])-bit \(encodings[data[3]] ?? "encoding \(data[3])"), \(data[4] == 0 ? "full" : "limited") range"
    }
    return links
}

// MARK: - Link and dithering

func onlineDisplays() -> [CGDirectDisplayID] {
    var ids = [CGDirectDisplayID](repeating: 0, count: 16)
    var count: UInt32 = 0
    CGGetOnlineDisplayList(16, &ids, &count)
    return Array(ids.prefix(Int(count)))
}

func externalDisplays() -> [CGDirectDisplayID] {
    onlineDisplays().filter { CGDisplayIsBuiltin($0) == 0 }
}

/// Set each external display's link to the preferred 8-bit link, or with `restore` to
/// WindowServer's own choice (the first link it lists, which is what it picks by default).
func setLinks(restore: Bool = false) {
    guard let getMode = SLSGetCurrentDisplayMode, let getLinks = SLSGetDisplayOutputModeLinkDescriptions,
          let configure = SLSConfigureDisplayOutputMode else {
        return fail("link: SkyLight output-mode API not found on this macOS, skipping")
    }
    let fbs = externalFramebuffers()
    defer { fbs.forEach { IOObjectRelease($0.service) } }
    var config: CGDisplayConfigRef?
    for id in externalDisplays() {
        let name = fbs.lazy.compactMap(\.monitor).first { $0.id == Monitor.id(id) }?.name ?? "display \(id)"
        var mode: Int32 = 0
        var descs = [LinkDescription](repeating: .zero, count: 32)
        var count = Int32(descs.count), current: Int32 = -1
        guard getMode(id, &mode) == .success, getLinks(id, mode, &descs, &count, &current) == .success else {
            fail("\(name): could not read link modes")
            continue
        }
        descs = Array(descs.prefix(Int(count)))
        // Any 8-bit SDR link leaves the monitor nothing to dither; encoding and range only affect
        // color accuracy. Prefer RGB, then YCbCr 4:4:4, then 4:2:2, and full range over limited.
        let target = restore ? descs.first : descs.filter { $0.bitDepth == 8 && $0.eotf == 0 }
            .min { ($0.encoding, $0.range == 1 ? 0 : 1) < ($1.encoding, $1.range == 1 ? 0 : 1) }
        guard let target else {
            fail("\(name): no \(restore ? "" : "8-bit ")link offered for the current mode")
            continue
        }
        if descs.indices.contains(Int(current)), descs[Int(current)] == target {
            print("\(name): link already \(target.name)")
            continue
        }
        if config == nil, CGBeginDisplayConfiguration(&config) != .success {
            return fail("could not begin display configuration")
        }
        let err = configure(config!, id, UInt64(target.bitDepth) | UInt64(target.range) << 32,
                            UInt64(target.eotf) | UInt64(target.encoding) << 32)
        err == .success ? print("\(name): set link to \(target.name)") : fail("\(name): set link failed (\(err.rawValue))")
    }
    if let config, CGCompleteDisplayConfiguration(config, .permanently) != .success {
        fail("display configuration failed")
    }
}

func setDither(_ enabled: Bool) {
    let fbs = externalFramebuffers()
    if fbs.isEmpty { fail("no external display pipes found") }
    for fb in fbs {
        defer { IOObjectRelease(fb.service) }
        let name = fb.monitor?.name ?? "(no display)"
        let kr = IORegistryEntrySetCFProperty(fb.service, "enableDither" as CFString, enabled ? kCFBooleanTrue : kCFBooleanFalse)
        kr == KERN_SUCCESS ? print("\(name): enableDither = \(enabled ? "Yes" : "No")")
                           : fail("\(name): enableDither failed: \(String(cString: mach_error_string(kr)))")
    }
}

func applyDisplay() {
    setLinks()
    setDither(false)
}

/// Back to macOS defaults: WindowServer's own link and GPU dithering on.
func restoreDisplay() {
    setLinks(restore: true)
    setDither(true)
}

/// `dusk agent`: launched by launchd at login and when a display attaches; nothing stays resident between runs.
func displayAgent() {
    print("[\(stamp())] agent")
    guard Settings.load().noDither else { return print("no dithering is turned off, skipping") }
    // launchd keeps relaunching the job until its IOKit match events are received.
    let lock = NSLock()
    var lastEvent = Date()
    xpc_set_event_stream_handler("com.apple.iokit.matching", .global()) { _ in
        lock.withLock { lastEvent = Date() }
    }
    // Wait until WindowServer has every connected external display online and
    // nothing new has attached for 2 s (max 30 s), so the link is up before we touch it.
    // Go again if another display attached after that, since its event was delivered to us.
    var settled: Date
    repeat {
        let start = Date()
        repeat {
            settled = lock.withLock { lastEvent }
            let fbs = externalFramebuffers()
            let connected = fbs.filter { $0.monitor != nil }.count
            fbs.forEach { IOObjectRelease($0.service) }
            if connected > 0, externalDisplays().count >= connected, Date().timeIntervalSince(settled) >= 2 { break }
            usleep(250_000)
        } while Date().timeIntervalSince(start) < 30
        applyDisplay()
    } while lock.withLock({ lastEvent }) != settled
}

func displayStatus() {
    let links = currentLinks()
    let fbs = externalFramebuffers()
    defer { fbs.forEach { IOObjectRelease($0.service) } }
    for case let (service, monitor?) in fbs {
        let dither = (property(service, "enableDither") as? Bool).map { $0 ? "Yes" : "No" } ?? "?"
        print(monitor.name)
        print("  enableDither  \(dither)")
        print("  link          \(links[monitor.id] ?? "unknown")")
    }
}
