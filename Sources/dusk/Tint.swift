// Sun-synced warm tint and brightness.
//
// The tint is macOS's Accessibility Color Filters (Color Tint): dusk writes the settings,
// universalaccessd applies them, and macOS keeps them across mode switches, sleep and reboots.
// Brightness is a gamma table, which macOS drops when the process that set it exits, so the
// resident `dusk menu` holds it and `dusk tick` sends it the value (see Menu.swift).

import CoreGraphics
import Foundation
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
/// A fade steps when a channel's 8-bit output has moved this many levels (and always at its end).
let stepLevels = 2
/// Local hours (on the hour) when launchd starts `dusk tick`. Every fade starts within one of them.
let checkHours = [2, 3, 4, 5, 6, 7, 15, 16, 17, 18, 19, 20]

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
    var enabled = true, noDither = true
    var pausedUntil: Date?, nightUntil: Date?

    static func load() -> Settings {
        let d = store
        var s = Settings()
        if let k = d.array(forKey: "kelvin") as? [Double], k.count == 3 { s.kelvin = k }
        if let b = d.array(forKey: "brightness") as? [Double], b.count == 3 { s.brightness = b }
        s.enabled = d.object(forKey: "enabled") as? Bool ?? true
        s.noDither = d.object(forKey: "noDither") as? Bool ?? true
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
        d.set(pausedUntil, forKey: "pausedUntil")
        d.set(nightUntil, forKey: "nightUntil")
    }

    func look(_ phase: Phase) -> Look {
        Look(kelvin: kelvin[phase.rawValue], brightness: brightness[phase.rawValue])
    }

    func paused(at t: Date) -> Bool { pausedUntil.map { $0 > t } ?? false }
    func nightOverride(at t: Date) -> Bool { nightUntil.map { $0 > t } ?? false }
}

// MARK: - Colour

/// What dusk shows: Color Filters gains for white, which work in linear light, and a brightness
/// that scales encoded values (a gamma table).
struct Look: Equatable {
    var gains = [1.0, 1.0, 1.0]
    var brightness = 1.0

    static let off = Look()

    init(gains: [Double] = [1, 1, 1], brightness: Double = 1) {
        self.gains = gains
        self.brightness = brightness
    }

    /// The colour for `kelvin`, converted to linear light for Color Filters.
    init(kelvin: Double, brightness: Double) {
        self.init(gains: warmth(kelvin).map { pow($0, 2.2) }, brightness: brightness)
    }

    func mixed(_ other: Look, _ p: Double) -> Look {
        Look(gains: zip(gains, other.gains).map { $0 + ($1 - $0) * p }, brightness: brightness + (other.brightness - brightness) * p)
    }

    /// The 8-bit output for white, per channel. dusk only updates when this changes.
    var levels: [Int] { gains.map { Int((pow($0, 1 / 2.2) * brightness * 255).rounded()) } }

    func stepsAway(from levels: [Int]) -> Bool { zip(self.levels, levels).contains { abs($0 - $1) >= stepLevels } }
}

/// A blackbody colour approximation, 0...255 per channel.
private func blackbody(_ kelvin: Double) -> [Double] {
    let t = kelvin / 100
    let r = t <= 66 ? 255 : 329.698727446 * pow(t - 60, -0.1332047592)
    let g = t <= 66 ? 99.4708025861 * log(t) - 161.1195681661 : 288.1221695283 * pow(t - 60, -0.0755148492)
    let b = t >= 66 ? 255 : t <= 19 ? 0 : 138.5177312231 * log(t - 10) - 305.0447927307
    return [r, g, b].map { min(max($0, 0), 255) }
}

/// The colour for a temperature, in encoded values with red = 1: the blackbody colour white-balanced to
/// 6500 K, and below 2000 K a smoothstep from 2000 K's colour to pure red at 0 K.
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
        edges = keys.map(\.time) + [settings.pausedUntil, settings.nightUntil].compactMap { $0 }.flatMap { [$0, $0 + fadeLength] }
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

    /// The next step before `horizon`: when the 8-bit output has moved `stepLevels` from `levels`,
    /// or at the end of a fade if it differs at all.
    func nextChange(after t: Date, from levels: [Int], before horizon: Date) -> Date? {
        var a = t
        for b in edges.filter({ $0 > t && $0 < horizon }).sorted() + [horizon] {
            let end = look(b)
            if end.stepsAway(from: levels) {
                // Fades are monotonic, so bisect for the first step (to 0.5 s).
                var lo = a, hi = b
                while hi.timeIntervalSince(lo) > 0.5 {
                    let mid = lo + hi.timeIntervalSince(lo) / 2
                    if look(mid).stepsAway(from: levels) { hi = mid } else { lo = mid }
                }
                return hi
            }
            if end.levels != levels { return b }
            a = b
        }
        return nil
    }

    /// The end of the fade running at `t`, or nil if the output holds.
    func fadeEnd(after t: Date) -> Date? {
        edges.filter { $0 > t }.min().flatMap { look($0).levels != look(t).levels ? $0 : nil }
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
}

// MARK: - Color Filters

private let mediaAccessibility = "/System/Library/Frameworks/MediaAccessibility.framework/MediaAccessibility"

/// MediaAccessibility's private Color Filters preference functions. Each setter writes
/// com.apple.mediaaccessibility and posts a change notification, and universalaccessd applies it.
private struct MA {
    let getEnabled: @convention(c) (Int) -> UInt8
    let setEnabled: @convention(c) (Int, UInt8) -> Void
    let getType: @convention(c) (Int) -> Int
    let setType: @convention(c) (Int, Int) -> Void
    let getHue: @convention(c) () -> Double
    let setHue: @convention(c) (Double) -> Void
    let getIntensity: @convention(c) () -> Double
    let setIntensity: @convention(c) (Double) -> Void
    let suspendNotifications: @convention(c) (UInt8) -> Void

    static let api: MA? = {
        func f<T>(_ name: String, _ t: T.Type) -> T? { sym(mediaAccessibility, "MADisplayFilterPref" + name, t) }
        guard let a = f("GetCategoryEnabled", (@convention(c) (Int) -> UInt8).self),
              let b = f("SetCategoryEnabled", (@convention(c) (Int, UInt8) -> Void).self),
              let c = f("GetType", (@convention(c) (Int) -> Int).self),
              let d = f("SetType", (@convention(c) (Int, Int) -> Void).self),
              let e = f("GetSingleColorHue", (@convention(c) () -> Double).self),
              let g = f("SetSingleColorHue", (@convention(c) (Double) -> Void).self),
              let h = f("GetSingleColorIntensity", (@convention(c) () -> Double).self),
              let i = f("SetSingleColorIntensity", (@convention(c) (Double) -> Void).self),
              let j = f("SuspendNotifications", (@convention(c) (UInt8) -> Void).self) else { return nil }
        return MA(getEnabled: a, setEnabled: b, getType: c, setType: d, getHue: e, setHue: g,
                  getIntensity: h, setIntensity: i, suspendNotifications: j)
    }()
}

/// The Color Filters settings dusk uses: category 1 (Color) with filter type 16 (Color Tint).
struct ColorFilters: Equatable {
    static let category = 1, colorTint = 16
    /// universalaccessd applies at least this tint intensity (about 5400 K).
    static let minIntensity = 0.25

    var enabled: Bool
    var type: Int
    var hue: Double  // 0...1 = 0...360°
    var intensity: Double

    static var available: Bool { MA.api != nil }

    static func read() -> ColorFilters? {
        guard let ma = MA.api else { return nil }
        return ColorFilters(enabled: ma.getEnabled(category) != 0, type: ma.getType(category),
                            hue: ma.getHue(), intensity: ma.getIntensity())
    }

    /// Color Tint's matrix is diag((1 − i) + i × hue colour), so for warm gains with red = 1 and
    /// green ≥ blue: intensity = 1 − blue, hue = 60° × (green − blue) / (1 − blue).
    func showing(_ gains: [Double]) -> ColorFilters {
        var f = self
        let blue = gains[2]
        f.enabled = blue < 0.995
        guard f.enabled else { return f }  // keep the user's own type, hue and intensity
        f.type = Self.colorTint
        f.intensity = max(1 - blue, Self.minIntensity)
        f.hue = max(gains[1] - blue, 0) / (1 - blue) / 6
        return f
    }

    /// Gains for white, or nil when a filter other than Color Tint is on.
    var gains: [Double]? {
        guard enabled else { return [1, 1, 1] }
        guard type == Self.colorTint else { return nil }
        let x = hue * 6
        return [abs(x - 3) - 1, 2 - abs(x - 2), 2 - abs(x - 4)].map { 1 - intensity + intensity * min(max($0, 0), 1) }
    }

    /// Write what differs from `old`, with one change notification for the batch.
    func write(over old: ColorFilters) {
        guard let ma = MA.api else { return }
        let c = Self.category
        var writes: [() -> Void] = []
        if type != old.type { writes.append { ma.setType(c, type) } }
        if abs(hue - old.hue) > 1e-9 { writes.append { ma.setHue(hue) } }
        if abs(intensity - old.intensity) > 1e-9 { writes.append { ma.setIntensity(intensity) } }
        if enabled != old.enabled { writes.append { ma.setEnabled(c, enabled ? 1 : 0) } }
        guard let last = writes.popLast() else { return }
        if !writes.isEmpty {
            ma.suspendNotifications(1)
            writes.forEach { $0() }
            ma.suspendNotifications(0)
        }
        last()
    }

    /// The user's own settings, saved at the first install and put back by uninstall.
    var dictionary: [String: Any] { ["enabled": enabled, "type": type, "hue": hue, "intensity": intensity] }

    init(enabled: Bool, type: Int, hue: Double, intensity: Double) {
        (self.enabled, self.type, self.hue, self.intensity) = (enabled, type, hue, intensity)
    }

    init?(_ d: [String: Any]?) {
        guard let d, let e = d["enabled"] as? Bool, let t = d["type"] as? Int,
              let h = d["hue"] as? Double, let i = d["intensity"] as? Double else { return nil }
        self.init(enabled: e, type: t, hue: h, intensity: i)
    }
}

/// Show `look`'s tint, writing Color Filters only if the 8-bit output changes. Returns whether it wrote.
@discardableResult
func showTint(_ look: Look) -> Bool {
    guard let old = ColorFilters.read() else { return false }
    let new = old.showing(look.gains)
    if let shown = old.gains, Look(gains: shown, brightness: look.brightness).levels
        == Look(gains: new.gains!, brightness: look.brightness).levels { return false }
    new.write(over: old)
    return true
}

// MARK: - Brightness and icon state, from `dusk tick` to `dusk menu`

/// A Darwin notification whose 64-bit state holds the brightness (per mille) and the icon.
enum Shared {
    static let name = "local.dusk.state"
    static let token: Int32 = {
        var t: Int32 = 0
        notify_register_check(name, &t)
        return t
    }()

    static func decode(_ s: UInt64) -> (brightness: Double, icon: Int)? {
        s == 0 ? nil : (Double(s & 0xffff) / 1000, Int(s >> 16) - 1)
    }

    static func read() -> (brightness: Double, icon: Int)? {
        var s: UInt64 = 0
        notify_get_state(token, &s)
        return decode(s)
    }

    static func post(brightness: Double, icon: Int) {
        let s = UInt64((brightness * 1000).rounded()) | UInt64(icon + 1) << 16
        var old: UInt64 = 0
        notify_get_state(token, &old)
        guard s != old else { return }
        notify_set_state(token, s)
        notify_post(name)
    }
}

// MARK: - dusk tick

/// The displays are all asleep or the session is locked, so a fade would go unseen.
func screensOff() -> Bool {
    if (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool == true { return true }
    var ids = [CGDirectDisplayID](repeating: 0, count: 16)
    var count: UInt32 = 0
    CGGetOnlineDisplayList(16, &ids, &count)
    return ids.prefix(Int(count)).allSatisfy { CGDisplayIsAsleep($0) != 0 }
}

/// The next time launchd starts `dusk tick`.
func nextCheck(after t: Date) -> Date {
    checkHours.compactMap {
        Calendar.current.nextDate(after: t, matching: DateComponents(hour: $0, minute: 0), matchingPolicy: .nextTime)
    }.min()!
}

/// `dusk tick`: started by launchd at login, at the check hours, after wake (for missed checks)
/// and when the settings change. Shows the look for now. If a fade is running or starts before the
/// next check, it waits idle on a wall-clock timer (time asleep counts) and steps each time the
/// 8-bit output changes; then it exits. Nothing is kept between runs.
func tick() -> Never {
    if !ColorFilters.available { fail("tint: Color Filters API not found on this macOS, skipping the tint") }
    let settings = Settings.load()
    let schedule = Schedule(settings, around: Clock.now)
    var writes = 0
    func step() {
        let t = Clock.now
        var look = schedule.look(t)
        // Nobody is watching: jump to the end of the fade instead of stepping through it.
        if screensOff(), let end = schedule.fadeEnd(after: t) { look = schedule.look(end) }
        if showTint(look) { writes += 1 }
        Shared.post(brightness: look.brightness, icon: schedule.icon(t))
        // A pause can end outside the check hours; "Night until sunrise" ends inside them.
        let horizon = max(nextCheck(after: t), settings.pausedUntil.map { $0 + fadeLength } ?? .distantPast)
        guard let next = schedule.nextChange(after: t, from: look.levels, before: horizon) else {
            if writes > 0 { print("[\(stamp(t))] tick: \(schedule.describe(t)), \(writes) tint update\(writes == 1 ? "" : "s")") }
            exit(failed ? 1 : 0)
        }
        DispatchQueue.main.asyncAfter(wallDeadline: .now() + Clock.delay(until: next), execute: step)
    }
    step()
    dispatchMain()
}

func tintStatus() {
    let s = Settings.load(), t = Clock.now
    let n = Night.around(t)
    print("Tint\(ColorFilters.available ? "" : " (Color Filters API not found on this macOS)")")
    for p in Phase.allCases {
        let k = s.kelvin[p.rawValue]
        let kelvin = k <= 0 ? "0 K (red)" : k >= 6500 ? "6500 K (off)" : "\(Int(k)) K"
        print("  \(p.name.lowercased().padding(toLength: 12, withPad: " ", startingAt: 0))  \(kelvin), \(Int((s.brightness[p.rawValue] * 100).rounded()))%")
    }
    print("  sunset        \(clock(n.sunset))")
    print("  fully red by  \(clock(n.red))")
    print("  red until     \(clock(n.morning))")
    print("  sunrise       \(clock(n.sunrise))")
    print("  now           \(Schedule(s, around: t).describe(t))")
}
