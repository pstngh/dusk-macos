// `dusk menu`: the only resident part of dusk. It holds the brightness gamma table (macOS drops a
// gamma table on display mode switches and when the process that set it exits) and shows the
// optional menu bar icon. Idle, it has no timers and doesn't poll: it wakes only for dusk's
// Darwin notification, display changes, screen wake and clicks.

import AppKit
import notify

private let warmthNotches: [Double] = [0, 1200, 1900, 2300, 2700, 3400, 4000, 4500, 5000, 5500, 6500]
private let brightnessNotches = (6...20).map { Double($0) * 0.05 }  // 30...100%
private let icons = ["sun.max", "sunset", "moon", "circle.slash", "pause.circle"]

private var app: MenuApp!

/// Restart the tint job off the main thread: launchctl waits out launchd's restart throttle.
private let kicker = DispatchQueue(label: "local.dusk.kick")
private func kick() { kicker.async { kickTint() } }

func runMenu(icon: Bool) -> Never {
    NSApplication.shared.setActivationPolicy(.accessory)
    app = MenuApp(icon: icon)
    NSApplication.shared.run()
    exit(0)
}

private func nearest(_ notches: [Double], _ v: Double) -> Int {
    notches.indices.min { abs(notches[$0] - v) < abs(notches[$1] - v) }!
}

final class MenuApp: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var settings = Settings.load()
    /// The latest from `dusk tick`, and what the gamma table shows now.
    private var scheduled = (brightness: 1.0, icon: 0)
    private var brightness = 1.0
    private var token: Int32 = 0
    private var edited = false
    private var watchUntil = Date.distantPast

    init(icon: Bool) {
        super.init()
        if let s = Shared.read() { scheduled = s }
        notify_register_dispatch(Shared.name, &token, .main) { [unowned self] t in
            var s: UInt64 = 0
            notify_get_state(t, &s)
            guard let state = Shared.decode(s) else { return }
            scheduled = state
            if !edited { setBrightness(state.brightness) }
            updateIcon()
        }
        CGDisplayRegisterReconfigurationCallback({ _, _, _ in app.displaysChanged() }, nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { _ in app.displaysChanged() }
        if icon {
            statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            statusItem!.menu = NSMenu()
            statusItem!.menu!.delegate = self
            updateIcon()
        }
        setBrightness(scheduled.brightness)
        // Re-apply the schedule, in case a menu preview was cut short by a crash.
        kick()
        // Hand back the memory AppKit freed while starting up.
        DispatchQueue.main.async { malloc_zone_pressure_relief(nil, 0) }
    }

    // MARK: Brightness

    /// Dimming: a gamma formula that scales every encoded value by `b`, on every display.
    private func setBrightness(_ b: Double) {
        if b < 0.999 {
            var ids = [CGDirectDisplayID](repeating: 0, count: 16)
            var count: UInt32 = 0
            CGGetOnlineDisplayList(16, &ids, &count)
            let g = CGGammaValue(b)
            for id in ids.prefix(Int(count)) { CGSetDisplayTransferByFormula(id, 0, g, 1, 0, g, 1, 0, g, 1) }
        } else if brightness < 0.999 {
            CGDisplayRestoreColorSyncSettings()
        }
        brightness = b
    }

    /// macOS resets gamma tables during mode switches, monitor attach and wake, at a moment it
    /// doesn't announce. After any display change, check every 20 ms for 3 s and set ours again
    /// as soon as it has been reset.
    func displaysChanged() {
        guard brightness < 0.999 else { return }
        let watching = watchUntil > Date()
        watchUntil = Date() + 3
        if !watching { watch() }
    }

    private func watch() {
        guard brightness < 0.999 else { return }
        if gammaWasReset() { setBrightness(brightness) }
        if Date() < watchUntil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [self] in watch() }
        }
    }

    private func gammaWasReset() -> Bool {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetOnlineDisplayList(16, &ids, &count)
        return ids.prefix(Int(count)).contains { id in
            var r = [CGGammaValue](repeating: 0, count: 256), g = r, b = r
            var n: UInt32 = 0
            CGGetDisplayTransferByTable(id, 256, &r, &g, &b, &n)
            return n > 0 && abs(Double(r[Int(n) - 1]) - brightness) > 0.002
        }
    }

    // MARK: Menu

    private func updateIcon() {
        let name = icons.indices.contains(scheduled.icon) ? icons[scheduled.icon] : icons[0]
        statusItem?.button?.image = NSImage(systemSymbolName: name, accessibilityDescription: "dusk")
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        settings = Settings.load()
        let t = Clock.now
        menu.addItem(withTitle: Schedule(settings, around: t).describe(t).capitalizedFirst, action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        for phase in Phase.allCases {
            let p = phase.rawValue
            menu.addItem(row(phase.name, warmthNotches, nearest(warmthNotches, settings.kelvin[p]),
                             { $0 == 6500 ? "Off" : "\(Int($0)) K" }) { [unowned self] v in
                settings.kelvin[p] = v
                preview(phase)
            })
            menu.addItem(row("", brightnessNotches, nearest(brightnessNotches, settings.brightness[p]),
                             { "\(Int(($0 * 100).rounded()))%" }) { [unowned self] v in
                settings.brightness[p] = v
                preview(phase)
            })
        }
        menu.addItem(.separator())
        let paused = settings.paused(at: t)
        add(menu, "Reset to defaults", #selector(reset))
        add(menu, paused ? "Paused until \(clock(settings.pausedUntil!))" : "Pause for 1 hour", #selector(pause), on: paused)
        add(menu, "Night until sunrise", #selector(nightUntilSunrise), on: settings.nightOverride(at: t))
        add(menu, "Warm tint & dimming", #selector(toggleTint), on: settings.enabled)
        add(menu, "No dithering", #selector(toggleDither), on: settings.noDither)
        menu.addItem(.separator())
        let n = Night.around(t)
        menu.addItem(withTitle: "Sunset \(clock(n.sunset)) · red \(clock(n.red)) → \(clock(n.morning)) · sunrise \(clock(n.sunrise))",
                     action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        add(menu, "Hide icon", #selector(hideIcon))
    }

    /// Live preview while a slider moves; saved when the menu closes.
    private func preview(_ phase: Phase) {
        edited = true
        let look = settings.look(phase)
        showTint(look)
        setBrightness(look.brightness)
    }

    func menuDidClose(_ menu: NSMenu) {
        DispatchQueue.main.async { malloc_zone_pressure_relief(nil, 0) }
        guard edited else { return }
        edited = false
        settings.save()
        setBrightness(scheduled.brightness)
        kick()
    }

    private func row(_ title: String, _ notches: [Double], _ index: Int, _ text: @escaping (Double) -> String,
                     _ changed: @escaping (Double) -> Void) -> NSMenuItem {
        let item = NSMenuItem()
        item.view = SliderRow(title: title, count: notches.count, index: index, text: { text(notches[$0]) }) { changed(notches[$0]) }
        return item
    }

    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, on: Bool = false) {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
        item.target = self
        item.state = on ? .on : .off
    }

    private func update(_ change: (inout Settings) -> Void) {
        change(&settings)
        settings.save()
        kick()
    }

    @objc private func reset() {
        update { $0.kelvin = Settings.presetKelvin; $0.brightness = Settings.presetBrightness }
    }

    @objc private func pause() {
        let t = Clock.now, paused = settings.paused(at: t)
        update { $0.pausedUntil = paused ? nil : t + 3600; $0.nightUntil = nil }
    }

    /// Red until half an hour before the next sunrise, then a fade back into the schedule.
    @objc private func nightUntilSunrise() {
        let t = Clock.now, night = settings.nightOverride(at: t)
        update { $0.nightUntil = night ? nil : Night.around(t).sunrise - fadeLength; $0.pausedUntil = nil }
    }

    @objc private func toggleTint() {
        update { $0.enabled.toggle() }
    }

    @objc private func toggleDither() {
        settings.noDither.toggle()
        settings.save()
        let on = settings.noDither
        DispatchQueue.global().async { on ? applyDisplay() : restoreDisplay() }
    }

    @objc private func hideIcon() {
        statusItem.map(NSStatusBar.system.removeStatusItem)
        statusItem = nil
    }
}

/// A menu row with a notched slider: title, slider, value.
private final class SliderRow: NSView {
    private let slider = NSSlider()
    private let value = NSTextField(labelWithString: "")
    private let text: (Int) -> String
    private let changed: (Int) -> Void
    private var index: Int

    init(title: String, count: Int, index: Int, text: @escaping (Int) -> String, changed: @escaping (Int) -> Void) {
        (self.text, self.changed, self.index) = (text, changed, index)
        super.init(frame: NSRect(x: 0, y: 0, width: 290, height: 26))
        let font = NSFont.menuFont(ofSize: 0)
        let label = NSTextField(labelWithString: title)
        label.font = font
        label.frame = NSRect(x: 20, y: 5, width: 64, height: 16)
        slider.frame = NSRect(x: 84, y: 3, width: 140, height: 20)
        slider.controlSize = .small
        slider.minValue = 0
        slider.maxValue = Double(count - 1)
        slider.numberOfTickMarks = count
        slider.allowsTickMarkValuesOnly = true
        slider.doubleValue = Double(index)
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(moved)
        value.font = NSFont.monospacedDigitSystemFont(ofSize: font.pointSize, weight: .regular)
        value.alignment = .right
        value.frame = NSRect(x: 222, y: 5, width: 56, height: 16)
        value.stringValue = text(index)
        [label, slider, value].forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Write only when the slider reaches another notch.
    @objc private func moved() {
        let i = Int(slider.doubleValue.rounded())
        guard i != index else { return }
        index = i
        value.stringValue = text(i)
        changed(i)
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
