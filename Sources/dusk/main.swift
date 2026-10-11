// dusk: no temporal dithering on external displays, and a sun-synced warm tint (Apple Silicon, SDR).
//   status     show dithering and the link per external display, the tint settings and tonight's times
//   set        set a phase's warmth (K) or brightness (%)
//   apply      apply no dithering now and re-run the tint
//   install    copy this binary to ~/.local/bin and load the LaunchAgents
//   uninstall  unload them, restore the link, dithering and Color Filters, remove the files
//   agent      (local.dusk.display) wait for displays to settle, then apply no dithering
//   tick       (local.dusk.tint) show the tint for now and run any fade that is due
//   menu       (local.dusk.menu) hold the brightness and show the menu bar icon

import Foundation

setvbuf(stdout, nil, _IOLBF, 0)

let home = FileManager.default.homeDirectoryForCurrentUser
let installedBinary = home.appendingPathComponent(".local/bin/dusk")
let logPath = home.appendingPathComponent("Library/Logs/dusk.log").path
let domain = "gui/\(getuid())"

func agentPlist(_ job: String) -> URL {
    home.appendingPathComponent("Library/LaunchAgents/local.dusk.\(job).plist")
}

@discardableResult
func launchctl(_ args: String...) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    p.arguments = args
    p.standardError = FileHandle.nullDevice
    try? p.run()
    p.waitUntilExit()
    return p.terminationStatus
}

/// Restart the tint job so it shows the schedule with the current settings.
func kickTint() {
    launchctl("kickstart", "-k", "\(domain)/local.dusk.tint")
}

/// Show the tint for now: through the tint job when installed, else just the Color Filters part.
func retint() {
    if FileManager.default.fileExists(atPath: agentPlist("tint").path) { return kickTint() }
    let t = Clock.now
    showTint(Schedule(Settings.load(), around: t).look(t))
    print("dusk is not installed: tint set for now, no fades or dimming")
}

func usage() -> Never {
    print("""
    usage: dusk status
           dusk set day|evening|night warmth <0-6500 K>
           dusk set day|evening|night brightness <30-100 %>
           dusk apply
           dusk install [--no-menu]
           dusk uninstall
    """)
    exit(2)
}

func set(_ args: [String]) {
    guard args.count == 3, let phase = Phase.allCases.first(where: { $0.name.lowercased() == args[0] }),
          let value = Double(args[2]) else { usage() }
    var s = Settings.load()
    switch args[1] {
    case "warmth" where (0...6500).contains(value): s.kelvin[phase.rawValue] = value
    case "brightness" where (30...100).contains(value): s.brightness[phase.rawValue] = value / 100
    default: usage()
    }
    s.save()
    retint()
}

func install(menu: Bool) throws {
    let fm = FileManager.default
    // Replace nodither (dusk 1.x).
    launchctl("bootout", "\(domain)/local.nodither")
    for old in [home.appendingPathComponent("Library/LaunchAgents/local.nodither.plist"),
                home.appendingPathComponent(".local/bin/nodither")] where fm.fileExists(atPath: old.path) {
        try fm.removeItem(at: old)
        print("removed \(old.path)")
    }
    let me = Bundle.main.executableURL!.resolvingSymlinksInPath()
    try fm.createDirectory(at: installedBinary.deletingLastPathComponent(), withIntermediateDirectories: true)
    if me.path != installedBinary.path {
        try? fm.removeItem(at: installedBinary)
        try fm.copyItem(at: me, to: installedBinary)
    }
    // Remember the user's own Color Filters settings once, for uninstall.
    if Settings.store.dictionary(forKey: "previousColorFilters") == nil, let f = ColorFilters.read() {
        Settings.store.set(f.dictionary, forKey: "previousColorFilters")
    }
    let jobs: [(name: String, args: [String], keys: [String: Any])] = [
        // launchd watches IOKit and starts the job only when a monitor's AV service appears.
        ("display", ["agent"], ["LaunchEvents": ["com.apple.iokit.matching": ["display attached": [
            "IOProviderClass": "DCPAVServiceProxy",
            "IOPropertyMatch": ["Location": "External"],
            "IOMatchLaunchStream": true,
        ]]]]),
        // launchd runs missed calendar checks after wake and never starts a second instance.
        // ThrottleInterval 1: a settings change restarts the job within a second, not 10.
        ("tint", ["tick"], ["StartCalendarInterval": checkHours.map { ["Hour": $0, "Minute": 0] }, "ThrottleInterval": 1]),
        ("menu", menu ? ["menu"] : ["menu", "--no-icon"], ["KeepAlive": true]),
    ]
    try fm.createDirectory(at: agentPlist("").deletingLastPathComponent(), withIntermediateDirectories: true)
    for job in jobs {
        let label = "local.dusk.\(job.name)", url = agentPlist(job.name)
        let plist = job.keys.merging([
            "Label": label,
            "ProgramArguments": [installedBinary.path] + job.args,
            "RunAtLoad": true,
            "StandardOutPath": logPath,
            "StandardErrorPath": logPath,
        ]) { $1 }
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url)
        launchctl("bootout", "\(domain)/\(label)")
        let rc = launchctl("bootstrap", domain, url.path)
        rc == 0 ? print("loaded \(url.path)") : fail("launchctl bootstrap \(label) failed (\(rc))")
    }
    print("installed \(installedBinary.path) (log: \(logPath))")
}

func uninstall() {
    for job in ["menu", "tint", "display"] {
        launchctl("bootout", "\(domain)/local.dusk.\(job)")
        try? FileManager.default.removeItem(at: agentPlist(job))
    }
    restoreDisplay()
    if let now = ColorFilters.read() {
        var mine = now
        mine.enabled = false
        (ColorFilters(Settings.store.dictionary(forKey: "previousColorFilters")) ?? mine).write(over: now)
    }
    Settings.store.removePersistentDomain(forName: "local.dusk")
    try? FileManager.default.removeItem(at: installedBinary)
    print("removed the LaunchAgents, \(installedBinary.path) and the settings; Color Filters restored")
}

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "status":
    displayStatus()
    tintStatus()
case "set": set(Array(args.dropFirst()))
case "apply":
    Settings.load().noDither ? applyDisplay() : print("no dithering is turned off in the menu")
    retint()
case "install": do { try install(menu: !args.contains("--no-menu")) } catch { fail("install failed: \(error)") }
case "uninstall": uninstall()
case "agent": displayAgent()
case "tick": tick()
case "menu": runMenu(icon: !args.contains("--no-icon"))
default: usage()
}
exit(failed ? 1 : 0)
