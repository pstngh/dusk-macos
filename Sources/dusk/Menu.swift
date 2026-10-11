// `dusk tint`: the resident part of dusk (see Tinter in Tint.swift) and its optional menu bar icon.

import AppKit

private let warmthNotches: [Double] = [0, 1200, 1900, 2300, 2700, 3400, 4000, 4500, 5000, 5500, 6500]
private let brightnessNotches = (6...20).map { Double($0) * 0.05 }  // 30...100%
private let linkQueue = DispatchQueue(label: "local.dusk.link")
private let icons = ["sun.max", "sunset", "moon", "circle.slash", "pause.circle"]

func runTint() -> Never {
    NSApplication.shared.setActivationPolicy(.accessory)
    let tinter = Tinter()
    let menu = StatusMenu(tinter)
    // Hand back the memory AppKit freed while starting up.
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { malloc_zone_pressure_relief(nil, 0) }
    withExtendedLifetime((tinter, menu)) { NSApplication.shared.run() }
    exit(0)
}

private func warmthText(_ k: Double) -> String { k == 0 ? "Red" : k == 6500 ? "Off" : "\(Int(k)) K" }
private func percentText(_ b: Double) -> String { "\(Int((b * 100).rounded()))%" }

private func nearest(_ notches: [Double], _ v: Double) -> Int {
    notches.indices.min { abs(notches[$0] - v) < abs(notches[$1] - v) }!
}

final class StatusMenu: NSObject, NSMenuDelegate {
    private let tinter: Tinter
    private var item: NSStatusItem?
    private var shownIcon = -1
    /// The sliders' settings while the menu is open; saved when it closes.
    private var draft = Settings()
    private var edited = false

    init(_ tinter: Tinter) {
        self.tinter = tinter
        super.init()
        tinter.updated = { [unowned self] in refresh() }
        refresh()
    }

    /// Show or hide the icon as the settings say, and match it to the phase.
    private func refresh() {
        if tinter.settings.icon, item == nil {
            item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item!.menu = NSMenu()
            item!.menu!.delegate = self
            shownIcon = -1
        } else if !tinter.settings.icon, let item {
            NSStatusBar.system.removeStatusItem(item)
            self.item = nil
        }
        guard let item, tinter.icon != shownIcon else { return }
        shownIcon = tinter.icon
        item.button?.image = NSImage(systemSymbolName: icons.indices.contains(shownIcon) ? icons[shownIcon] : icons[0],
                                     accessibilityDescription: "dusk")
    }

    /// Built on each click and emptied when the menu closes.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        draft = tinter.settings
        let t = Clock.now
        let schedule = Schedule(draft, around: t)
        menu.addItem(label(schedule.describe(t).capitalizedFirst))
        if let values = schedule.values(t) { menu.addItem(withTitle: values.capitalizedFirst, action: nil, keyEquivalent: "") }
        for phase in Phase.allCases {
            let p = phase.rawValue
            menu.addItem(.separator())
            if #available(macOS 14, *) {
                menu.addItem(.sectionHeader(title: phase.name))
            } else {
                menu.addItem(withTitle: phase.name, action: nil, keyEquivalent: "")
            }
            menu.addItem(row("Warmth", warmthNotches, draft.kelvin[p], warmthText) { [unowned self] v in
                draft.kelvin[p] = v
                preview(phase)
            })
            menu.addItem(row("Brightness", brightnessNotches, draft.brightness[p], percentText) { [unowned self] v in
                draft.brightness[p] = v
                preview(phase)
            })
        }
        menu.addItem(.separator())
        let paused = draft.paused(at: t)
        add(menu, paused ? "Paused until \(clock(draft.pausedUntil!))" : "Pause for 1 hour", #selector(pause), on: paused)
        add(menu, "Night until sunrise", #selector(nightUntilSunrise), on: draft.nightOverride(at: t))
        menu.addItem(.separator())
        add(menu, "Warm tint & dimming", #selector(toggleTint), on: draft.enabled)
        add(menu, "No dithering", #selector(toggleDither), on: draft.noDither)
        add(menu, "Reset to defaults", #selector(reset))
        menu.addItem(.separator())
        let n = Night.around(t)
        menu.addItem(withTitle: "Sunset \(clock(n.sunset)) · sunrise \(clock(n.sunrise))", action: nil, keyEquivalent: "")
        menu.addItem(withTitle: "Red \(clock(n.red)) → \(clock(n.morning))", action: nil, keyEquivalent: "")
    }

    /// Live preview of the look being edited, until the menu closes.
    private func preview(_ phase: Phase) {
        edited = true
        tinter.preview(draft.look(phase))
    }

    func menuDidClose(_ menu: NSMenu) {
        // After the clicked item's action has run.
        DispatchQueue.main.async {
            menu.removeAllItems()
            malloc_zone_pressure_relief(nil, 0)
        }
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

    /// Bold text in the normal colour (a disabled item's title would be greyed out).
    private func label(_ text: String) -> NSMenuItem {
        let field = NSTextField(labelWithString: text)
        field.font = .boldSystemFont(ofSize: NSFont.menuFont(ofSize: 0).pointSize)
        field.sizeToFit()
        field.frame.origin = NSPoint(x: 22, y: 3)
        let item = NSMenuItem()
        item.view = NSView(frame: NSRect(x: 0, y: 0, width: field.frame.maxX + 14, height: field.frame.height + 6))
        item.view!.addSubview(field)
        return item
    }

    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, on: Bool = false) {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
        item.target = self
        item.state = on ? .on : .off
    }

    @objc private func reset() {
        tinter.change { $0.resetLooks() }
    }

    @objc private func pause() {
        let t = Clock.now
        tinter.change { $0.paused(at: t) ? $0.resume() : $0.pause(minutes: 60, at: t) }
    }

    @objc private func nightUntilSunrise() {
        let t = Clock.now
        tinter.change { $0.nightOverride(at: t) ? $0.resume() : $0.nightUntilSunrise(at: t) }
    }

    @objc private func toggleTint() {
        tinter.change { $0.enabled.toggle() }
    }

    @objc private func toggleDither() {
        tinter.change { $0.noDither.toggle() }
        let on = tinter.settings.noDither
        // One link change at a time, in the order clicked.
        linkQueue.async { on ? applyDisplay() : restoreDisplay() }
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
        label.frame = NSRect(x: 22, y: 5, width: 72, height: 16)
        slider.frame = NSRect(x: 96, y: 3, width: 128, height: 20)
        slider.controlSize = .small
        slider.minValue = 0
        slider.maxValue = Double(count - 1)
        slider.doubleValue = Double(index)
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(moved)
        value.font = NSFont.monospacedDigitSystemFont(ofSize: font.pointSize, weight: .regular)
        value.alignment = .right
        value.frame = NSRect(x: 226, y: 5, width: 52, height: 16)
        value.stringValue = text(index)
        [label, slider, value].forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Snap to the nearest notch (they aren't drawn), and only act when it changes.
    @objc private func moved() {
        let i = Int(slider.doubleValue.rounded())
        slider.doubleValue = Double(i)
        guard i != index else { return }
        index = i
        value.stringValue = text(i)
        changed(i)
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
