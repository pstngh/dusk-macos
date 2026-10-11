// Sun-synced warm tint and dimming.
//
// Both are one gamma formula per display: each channel's encoded value is multiplied by the warmth
// colour times the brightness. macOS drops a gamma table when the process that set it exits and
// resets it on display changes, so `dusk tint` stays running: it sets the formula again after
// display changes and wake, and otherwise sleeps on a wall-clock timer until the output next changes.

import AppKit
import notify

// MARK: - Schedule constants

/// Montreal. Clock times are local (system time zone), so DST is automatic.
let latitude = 45.5019
let longitude = -73.5674
/// Fully red at sunset + nightShare × (9 PM − sunset), so always before 9 PM.
let nightDeadlineHour = 21
let nightShare = 0.75
/// Back toward Evening when the last quarter of the time from sunset to sunrise starts.
let morningShare = 0.25
let fadeLength: TimeInterval = 30 * 60

/// Posted by `dusk set` and `dusk apply` so the running `dusk tint` reloads the settings.
let settingsChanged = "local.dusk.settings"

/// The current time, or with DUSK_NOW="yyyy-MM-dd HH:mm" a simulated one that runs DUSK_SPEED times as fast.
enum Clock {
    static let start = Date()
    static let origin: Date = {
        guard let s = ProcessInfo.processInfo.environment["DUSK_NOW"] else { return start }
        guard let d = formatter("yyyy-MM-dd HH:mm").date(from: s) else { print("DUSK_NOW: expected yyyy-MM-dd HH:mm"); exit(2) }
        return d
    }()
    static let speed = Double(ProcessInfo.processInfo.environment["DUSK_SPEED"] ?? "") ?? 1
    static var now: Date { origin + Date().timeIntervalSince(start) * speed }
    /// Real seconds until `t` on this clock.
    static func delay(until t: Date) -> TimeInterval { max(0, t.timeIntervalSince(now) / speed) }
}

private func formatter(_ format: String) -> DateFormatter {
    let f = DateFormatter()
    f.dateFormat = format
    return f
}

private let hhmm = formatter("HH:mm"), timestamp = formatter("yyyy-MM-dd HH:mm:ss")

func clock(_ date: Date) -> String { hhmm.string(from: date) }

/// A local timestamp for the log.
func stamp(_ date: Date = Date()) -> String { timestamp.string(from: date) }

// MARK: - Settings

enum Phase: Int, CaseIterable {
    case day, evening, night
    var name: String { ["Day", "Evening", "Night"][rawValue] }
}

/// Stored in ~/Library/Preferences/local.dusk.plist.
struct Settings {
    static let store = UserDefaults(suiteName: "local.dusk")!
    /// Defaults: Day 4000 K / 100%, Evening 2700 K / 85%, Night 0 K (pure red) / 70%.
    static let presetKelvin = [4000.0, 2700, 0], presetBrightness = [1.0, 0.85, 0.7]

    var kelvin = presetKelvin, brightness = presetBrightness
    var enabled = true, noDither = true, icon = true
    var pausedUntil: Date?, nightUntil: Date?

    static func load() -> Settings {
        let d = store
        var s = Settings()
        if let k = d.array(forKey: "kelvin") as? [Double], k.count == 3 { s.kelvin = k }
        if let b = d.array(forKey: "brightness") as? [Double], b.count == 3 { s.brightness = b }
        s.enabled = d.object(forKey: "enabled") as? Bool ?? true
        s.noDither = d.object(forKey: "noDither") as? Bool ?? true
        s.icon = d.object(forKey: "icon") as? Bool ?? true
        s.pausedUntil = d.object(forKey: "pausedUntil") as? Date
        s.nightUntil = d.object(forKey: "nightUntil") as? Date
        return s
    }

    func save() {
        let d = Settings.store
        d.set(kelvin, forKey: "kelvin")
        d.set(brightness, forKey: "brightness")
        d.set(enabled, forKey: "enabled")
        d.set(noDither, forKey: "noDither")
        d.set(icon, forKey: "icon")
        d.set(pausedUntil, forKey: "pausedUntil")
        d.set(nightUntil, forKey: "nightUntil")
    }

    func look(_ phase: Phase) -> Look {
        Look(kelvin: kelvin[phase.rawValue], brightness: brightness[phase.rawValue])
    }

    func paused(at t: Date) -> Bool { pausedUntil.map { $0 > t } ?? false }
    func nightOverride(at t: Date) -> Bool { nightUntil.map { $0 > t } ?? false }

    mutating func resetLooks() {
        kelvin = Settings.presetKelvin
        brightness = Settings.presetBrightness
    }

    /// No tint or dimming for a while, then a fade back into the schedule.
    mutating func pause(minutes: Double, at t: Date) {
        pausedUntil = t + minutes * 60
        nightUntil = nil
    }

    /// Night until half an hour before the next sunrise, then a fade back into the schedule.
    mutating func nightUntilSunrise(at t: Date) {
        nightUntil = Night.around(t).sunrise - fadeLength
        pausedUntil = nil
    }

    mutating func resume() {
        pausedUntil = nil
        nightUntil = nil
    }
}

// MARK: - Colour

/// What dusk shows: a multiplier for each channel's encoded value (warmth colour × brightness).
struct Look: Equatable {
    var rgb = [1.0, 1.0, 1.0]
    /// For the menu and `dusk status`; during a fade, in between the two looks' values.
    var kelvin = 6500.0, brightness = 1.0

    static let off = Look()

    init(rgb: [Double] = [1, 1, 1], kelvin: Double = 6500, brightness: Double = 1) {
        (self.rgb, self.kelvin, self.brightness) = (rgb, kelvin, brightness)
    }

    init(kelvin: Double, brightness: Double) {
        self.init(rgb: warmth(kelvin).map { $0 * brightness }, kelvin: kelvin, brightness: brightness)
    }

    func mixed(_ other: Look, _ p: Double) -> Look {
        func mix(_ a: Double, _ b: Double) -> Double { a + (b - a) * p }
        return Look(rgb: zip(rgb, other.rgb).map(mix), kelvin: mix(kelvin, other.kelvin), brightness: mix(brightness, other.brightness))
    }

    /// The 8-bit output for white, per channel. dusk only updates when this changes.
    var levels: [Int] { rgb.map { Int(($0 * 255).rounded()) } }
}

/// A blackbody colour approximation, 0...255 per channel.
private func blackbody(_ kelvin: Double) -> [Double] {
    let t = kelvin / 100
    let r = t <= 66 ? 255 : 329.698727446 * pow(t - 60, -0.1332047592)
    let g = t <= 66 ? 99.4708025861 * log(t) - 161.1195681661 : 288.1221695283 * pow(t - 60, -0.0755148492)
    let b = t >= 66 ? 255 : t <= 19 ? 0 : 138.5177312231 * log(t - 10) - 305.0447927307
    return [r, g, b].map { min(max($0, 0), 255) }
}

/// The colour for a temperature, in encoded values with red = 1: the blackbody colour white-balanced
/// to 6500 K, and below 2000 K a smoothstep from 2000 K's colour to pure red at 0 K.
func warmth(_ kelvin: Double) -> [Double] {
    let white = blackbody(6500)
    func balanced(_ k: Double) -> [Double] { zip(blackbody(k), white).map { min($0 / $1, 1) } }
    let k = min(max(kelvin, 0), 6500)
    guard k <= 2000 else { return balanced(k) }
    let t = 1 - k / 2000, s = t * t * (3 - 2 * t)
    return zip(balanced(2000), [1.0, 0, 0]).map { $0 + ($1 - $0) * s }
}

// MARK: - Sun and schedule

/// NOAA sunrise and sunset (zenith 90.833°) on the local calendar day of `date`.
func sun(_ date: Date) -> (rise: Date, set: Date) {
    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = TimeZone(identifier: "UTC")!
    let day = utc.date(from: Calendar.current.dateComponents([.year, .month, .day], from: date))!
    let doy = Double(utc.ordinality(of: .day, in: .year, for: day)!)
    let g = 2 * Double.pi / Double(utc.range(of: .day, in: .year, for: day)!.count) * (doy - 1 + 0.5)
    let eqtime = 229.18 * (0.000075 + 0.001868 * cos(g) - 0.032077 * sin(g) - 0.014615 * cos(2 * g) - 0.040849 * sin(2 * g))
    let decl = 0.006918 - 0.399912 * cos(g) + 0.070257 * sin(g) - 0.006758 * cos(2 * g) + 0.000907 * sin(2 * g)
        - 0.002697 * cos(3 * g) + 0.00148 * sin(3 * g)
    let rad = Double.pi / 180, lat = latitude * rad
    let ha = acos(cos(90.833 * rad) / (cos(lat) * cos(decl)) - tan(lat) * tan(decl)) / rad
    // Minutes after UTC midnight of the same calendar day.
    return (day + (720 - 4 * (longitude + ha) - eqtime) * 60, day + (720 - 4 * (longitude - ha) - eqtime) * 60)
}

/// One night of the schedule, from the evening of `day`.
struct Night {
    let sunset, red, morning, sunrise: Date  // red: fully red; morning: the fade back starts

    init(evening day: Date) {
        let cal = Calendar.current
        sunset = sun(day).set
        sunrise = sun(cal.date(byAdding: .day, value: 1, to: day)!).rise
        let deadline = cal.date(bySettingHour: nightDeadlineHour, minute: 0, second: 0, of: day)!
        red = max(sunset + nightShare * deadline.timeIntervalSince(sunset), sunset)
        morning = sunrise - morningShare * sunrise.timeIntervalSince(sunset)
    }

    /// The night in progress, or the next one.
    static func around(_ t: Date) -> Night {
        let cal = Calendar.current
        let today = cal.startOfDay(for: t)
        return Night(evening: t < sun(today).rise ? cal.date(byAdding: .day, value: -1, to: today)! : today)
    }
}

struct Keyframe {
    let time: Date
    let phase: Phase
}

/// a → Evening over [t0, t1], then Evening → b over [t2, t3]; one fade through Evening if they overlap.
private func fades(_ a: Phase, _ t0: Date, _ t1: Date, _ t2: Date, _ t3: Date, _ b: Phase) -> [Keyframe] {
    guard t2 < t1 else {
        return [.init(time: t0, phase: a), .init(time: t1, phase: .evening), .init(time: t2, phase: .evening), .init(time: t3, phase: b)]
    }
    return [.init(time: t0, phase: a), .init(time: t0 + t3.timeIntervalSince(t0) / 2, phase: .evening), .init(time: t3, phase: b)]
}

/// The schedule with the menu's overrides, valid within a day of the `around` date.
/// Between keyframes with different phases dusk fades; between equal ones it holds.
struct Schedule {
    let settings: Settings
    let keys: [Keyframe]
    /// Times where the output can start or stop changing.
    let edges: [Date]

    init(_ settings: Settings, around date: Date) {
        self.settings = settings
        let cal = Calendar.current
        keys = (-1...1).flatMap { offset -> [Keyframe] in
            let n = Night(evening: cal.date(byAdding: .day, value: offset, to: cal.startOfDay(for: date))!)
            return fades(.day, n.sunset - fadeLength / 2, n.sunset + fadeLength / 2, n.red - fadeLength, n.red, .night)
                + fades(.night, n.morning, n.morning + fadeLength, n.sunrise - fadeLength, n.sunrise, .day)
        }
        edges = (keys.map(\.time) + [settings.pausedUntil, settings.nightUntil].compactMap { $0 }.flatMap { [$0, $0 + fadeLength] }).sorted()
    }

    /// The keyframes around `t` and the fade progress between them.
    func segment(_ t: Date) -> (from: Keyframe, to: Keyframe, progress: Double) {
        let i = keys.lastIndex { $0.time <= t } ?? 0
        let a = keys[i], b = keys[min(i + 1, keys.count - 1)]
        guard a.phase != b.phase else { return (a, b, 0) }
        return (a, b, min(max(t.timeIntervalSince(a.time) / b.time.timeIntervalSince(a.time), 0), 1))
    }

    func scheduled(_ t: Date) -> Look {
        let (a, b, p) = segment(t)
        return settings.look(a.phase).mixed(settings.look(b.phase), p)
    }

    /// The look at `t`. A pause or "Night until sunrise" fades back into the schedule when it ends.
    func look(_ t: Date) -> Look {
        guard settings.enabled else { return .off }
        for (end, look) in [(settings.pausedUntil, Look.off), (settings.nightUntil, settings.look(.night))] {
            if let end, t < end + fadeLength { return look.mixed(scheduled(t), max(0, t.timeIntervalSince(end)) / fadeLength) }
        }
        return scheduled(t)
    }

    /// The menu bar icon: a Phase raw value, 3 when off, 4 when paused.
    func icon(_ t: Date) -> Int {
        guard settings.enabled else { return 3 }
        if let end = settings.pausedUntil, t < end + fadeLength / 2 { return 4 }
        if let end = settings.nightUntil, t < end + fadeLength / 2 { return Phase.night.rawValue }
        let (a, b, p) = segment(t)
        return (p < 0.5 ? a : b).phase.rawValue
    }

    /// The next time the 8-bit output differs from `shown`'s, or the end of a fade if `shown` isn't
    /// exactly its final look; nil if nothing changes from here on.
    func nextChange(after t: Date, from shown: Look) -> Date? {
        var a = t
        for b in edges where b > t {
            let end = look(b)
            if end.levels != shown.levels {
                // Fades are monotonic, so bisect for the first change (to 0.5 s).
                var lo = a, hi = b
                while hi.timeIntervalSince(lo) > 0.5 {
                    let mid = lo + hi.timeIntervalSince(lo) / 2
                    if look(mid).levels != shown.levels { hi = mid } else { lo = mid }
                }
                return hi
            }
            if end != shown { return b }
            a = b
        }
        return nil
    }

    func describe(_ t: Date) -> String {
        guard settings.enabled else { return "off" }
        if let end = settings.pausedUntil, t < end { return "paused until \(clock(end))" }
        if let end = settings.nightUntil, t < end { return "Night until \(clock(end + fadeLength))" }
        let (a, b, _) = segment(t)
        if a.phase != b.phase { return "\(a.phase.name) → \(b.phase.name), fading until \(clock(b.time))" }
        guard let i = keys.firstIndex(where: { $0.time > t }), i + 1 < keys.count else { return a.phase.name }
        return "\(a.phase.name), \(keys[i + 1].phase.name) from \(clock(keys[i].time))"
    }

    /// The warmth and brightness on screen, nil without a tint: an estimate while they're changing.
    func values(_ t: Date) -> String? {
        let look = look(t)
        guard look.levels != Look.off.levels else { return nil }
        let percent = "\(Int((look.brightness * 100).rounded()))%"
        guard look == self.look(t + 1) else { return "about \(Int((look.kelvin / 100).rounded()) * 100) K, \(percent)" }
        return "\(kelvinText(look.kelvin)), \(percent)"
    }

    /// `describe`, with the warmth and brightness on screen.
    func now(_ t: Date) -> String {
        values(t).map { "\(describe(t)) · \($0)" } ?? describe(t)
    }
}

/// "2700 K", "0 K (red)" or "6500 K (off)".
func kelvinText(_ k: Double) -> String {
    k <= 0 ? "0 K (red)" : k >= 6500 ? "6500 K (off)" : "\(Int(k)) K"
}

// MARK: - dusk tint

/// The resident part of dusk: shows the look for now on every display, then sleeps on a wall-clock
/// timer (time asleep counts) until the 8-bit output next changes. Settings changes, wake and clock
/// changes show it again at once.
final class Tinter {
    private(set) var settings = Settings.load()
    private(set) var icon = 0
    /// Called after every update, for the menu bar icon.
    var updated: (() -> Void)?
    /// What the gamma tables show, and the menu's live preview while a slider moves.
    private var shown = Look.off
    private var preview: Look?
    private var described = ""
    private let timer = DispatchSource.makeTimerSource(queue: .main)
    private var token: Int32 = 0
    private var watchUntil = Date.distantPast

    init() {
        timer.setEventHandler { [unowned self] in update() }
        timer.activate()
        notify_register_dispatch(settingsChanged, &token, .main) { [unowned self] _ in
            settings = Settings.load()
            update()
            if gammaWasReset() { setGamma() }
        }
        CGDisplayRegisterReconfigurationCallback({ _, _, tinter in
            Unmanaged<Tinter>.fromOpaque(tinter!).takeUnretainedValue().displaysChanged()
        }, Unmanaged.passUnretained(self).toOpaque())
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [unowned self] _ in update() }
        workspace.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [unowned self] _ in
            displaysChanged()
        }
        // An app that sets its own gamma table resets every display's when it quits.
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [unowned self] _ in
                for delay in [0.1, 1, 3] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [self] in if gammaWasReset() { setGamma() } }
                }
            }
        }
        for name in [Notification.Name.NSSystemClockDidChange, .NSSystemTimeZoneDidChange] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [unowned self] _ in update() }
        }
        update()
    }

    /// Change and save the settings, and show the result.
    func change(_ edit: (inout Settings) -> Void) {
        edit(&settings)
        settings.save()
        preview = nil
        update()
    }

    /// Show `look` instead of the schedule until the next `change`.
    func preview(_ look: Look) {
        preview = look
        show(look)
    }

    func update() {
        guard preview == nil else { return }
        let t = Clock.now
        let schedule = Schedule(settings, around: t)
        let look = schedule.look(t)
        show(look)
        icon = schedule.icon(t)
        updated?()
        if schedule.describe(t) != described {
            described = schedule.describe(t)
            print("[\(stamp(t))] \(described)")
        }
        let next = schedule.nextChange(after: t, from: look)
        timer.schedule(wallDeadline: next.map { .now() + Clock.delay(until: $0) } ?? .distantFuture)
        // Going idle: hand back the memory freed since the last time.
        if next.map({ Clock.delay(until: $0) > 60 }) ?? true { malloc_zone_pressure_relief(nil, 0) }
    }

    private func show(_ look: Look) {
        guard look != shown else { return }
        shown = look
        setGamma()
    }

    /// output = input × rgb, per channel, on every display.
    private func setGamma() {
        guard shown.levels != Look.off.levels else { return CGDisplayRestoreColorSyncSettings() }
        let rgb = shown.rgb.map { CGGammaValue($0) }
        for id in onlineDisplays() { CGSetDisplayTransferByFormula(id, 0, rgb[0], 1, 0, rgb[1], 1, 0, rgb[2], 1) }
    }

    /// macOS resets gamma tables during mode switches, monitor attach and wake, at a moment it
    /// doesn't announce. After any display change, check every 20 ms for 3 s and set ours again as
    /// soon as it has been reset.
    private func displaysChanged() {
        guard shown.levels != Look.off.levels else { return }
        let watching = watchUntil > Date()
        watchUntil = Date() + 3
        if !watching { watch() }
    }

    private func watch() {
        if gammaWasReset() { setGamma() }
        if Date() < watchUntil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [self] in watch() }
        }
    }

    private func gammaWasReset() -> Bool {
        shown.levels != Look.off.levels && onlineDisplays().contains { id in
            var r = [CGGammaValue](repeating: 0, count: 256), g = r, b = r
            var n: UInt32 = 0
            CGGetDisplayTransferByTable(id, 256, &r, &g, &b, &n)
            guard n > 0 else { return false }
            return zip([r[Int(n) - 1], g[Int(n) - 1], b[Int(n) - 1]], shown.rgb).contains { abs(Double($0) - $1) > 0.002 }
        }
    }
}

func tintStatus() {
    let s = Settings.load(), t = Clock.now
    let n = Night.around(t)
    print("Tint")
    for p in Phase.allCases {
        print("  \(p.name.lowercased().padding(toLength: 12, withPad: " ", startingAt: 0))  \(kelvinText(s.kelvin[p.rawValue])), \(Int((s.brightness[p.rawValue] * 100).rounded()))%")
    }
    print("  sunset        \(clock(n.sunset))")
    print("  fully red by  \(clock(n.red))")
    print("  red until     \(clock(n.morning))")
    print("  sunrise       \(clock(n.sunrise))")
    print("  now           \(Schedule(s, around: t).now(t))")
}
