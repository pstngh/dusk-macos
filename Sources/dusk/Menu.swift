// `dusk tint`: the resident part of dusk (see Tinter in Tint.swift) and its optional menu bar icon.

import AppKit

private let warmthNotches: [Double] = [0, 1200, 1900, 2300, 2700, 3400, 4000, 4500, 5000, 5500, 6500]
private let brightnessNotches = (6...20).map { Double($0) * 0.05 }  // 30...100%
private let icons = ["sun.max", "sunset", "moon", "circle.slash", "pause.circle"]

func runTint(icon: Bool) -> Never {
    NSApplication.shared.setActivationPolicy(.accessory)
    let tinter = Tinter()
    let menu = icon ? StatusMenu(tinter) : nil
    // Hand back the memory AppKit freed while starting up.
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { malloc_zone_pressure_relief(nil, 0) }
    withExtendedLifetime((tinter, menu)) { NSApplication.shared.run() }
    exit(0)
}

private func nearest(_ notches: [Double], _ v: Double) -> Int {
    notches.indices.min { abs(notches[$0] - v) < abs(notches[$1] - v) }!
}

final class StatusMenu: NSObject, NSMenuDelegate {
    private let tinter: Tinter
    private var item: NSStatusItem? = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    /// The sliders' settings while the menu is open; saved when it closes.
    private var draft = Settings()
    private var edited = false

    init(_ tinter: Tinter) {
        self.tinter = tinter
        super.init()
        item!.menu = NSMenu()
        item!.menu!.delegate = self
        tinter.iconChanged = { [unowned self] in showIcon($0) }
        showIcon(tinter.icon)
    }

    private func showIcon(_ i: Int) {
        item?.button?.image = NSImage(systemSymbolName: icons.indices.contains(i) ? icons[i] : icons[0], accessibilityDescription: "dusk")
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        draft = tinter.settings
        let t = Clock.now
        menu.addItem(withTitle: Schedule(draft, around: t).describe(t).capitalizedFirst, action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        for phase in Phase.allCases {
            let p = phase.rawValue
            menu.addItem(row(phase.name, warmthNotches, draft.kelvin[p], { $0 == 6500 ? "Off" : "\(Int($0)) K" }) { [unowned self] v in
                draft.kelvin[p] = v
                preview(phase)
            })
            menu.addItem(row("", brightnessNotches, draft.brightness[p], { "\(Int(($0 * 100).rounded()))%" }) { [unowned self] v in
                draft.brightness[p] = v
                preview(phase)
            })
        }
        menu.addItem(.separator())
        let paused = draft.paused(at: t)
        add(menu, "Reset to defaults", #selector(reset))
        add(menu, paused ? "Paused until \(clock(draft.pausedUntil!))" : "Pause for 1 hour", #selector(pause), on: paused)
        add(menu, "Night until sunrise", #selector(nightUntilSunrise), on: draft.nightOverride(at: t))
        add(menu, "Warm tint & dimming", #selector(toggleTint), on: draft.enabled)
        add(menu, "No dithering", #selector(toggleDither), on: draft.noDither)
        menu.addItem(.separator())
        let n = Night.around(t)
        menu.addItem(withTitle: "Sunset \(clock(n.sunset)) · red \(clock(n.red)) → \(clock(n.morning)) · sunrise \(clock(n.sunrise))",
                     action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        add(menu, "Hide icon", #selector(hideIcon))
    }

    /// Live preview of the look being edited, until the menu closes.
    private func preview(_ phase: Phase) {
        edited = true
        tinter.preview(draft.look(phase))
    }

    func menuDidClose(_ menu: NSMenu) {
        DispatchQueue.main.async { malloc_zone_pressure_relief(nil, 0) }
        guard edited else { return }
        edited = false
        let looks = draft
        tinter.change { $0.kelvin = looks.kelvin; $0.brightness = looks.brightness }
    }

    private func row(_ title: String, _ notches: [Double], _ value: Double, _ text: @escaping (Double) -> String,
                     _ changed: @escaping (Double) -> Void) -> NSMenuItem {
        let item = NSMenuItem()
        item.view = SliderRow(title: title, count: notches.count, index: nearest(notches, value),
                              text: { text(notches[$0]) }) { changed(notches[$0]) }
        return item
    }

    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, on: Bool = false) {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
        item.target = self
        item.state = on ? .on : .off
    }

    @objc private func reset() {
        tinter.change { $0.kelvin = Settings.presetKelvin; $0.brightness = Settings.presetBrightness }
    }

    @objc private func pause() {
        let t = Clock.now
        tinter.change { $0.pausedUntil = $0.paused(at: t) ? nil : t + 3600; $0.nightUntil = nil }
    }

    /// Red until half an hour before the next sunrise, then a fade back into the schedule.
    @objc private func nightUntilSunrise() {
        let t = Clock.now
        tinter.change { $0.nightUntil = $0.nightOverride(at: t) ? nil : Night.around(t).sunrise - fadeLength; $0.pausedUntil = nil }
    }

    @objc private func toggleTint() {
        tinter.change { $0.enabled.toggle() }
    }

    @objc private func toggleDither() {
        tinter.change { $0.noDither.toggle() }
        let on = tinter.settings.noDither
        DispatchQueue.global().async { on ? applyDisplay() : restoreDisplay() }
    }

    /// Until the next login; the tint keeps working.
    @objc private func hideIcon() {
        item.map(NSStatusBar.system.removeStatusItem)
        item = nil
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

    /// Only act when the slider reaches another notch.
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
