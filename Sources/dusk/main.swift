// dusk: no temporal dithering on external displays, and a sun-synced warm tint (Apple Silicon, SDR).
//   status     show dithering and the link per external display, the looks and tonight's times
//   set        set a look's warmth (K) or brightness (%), or turn the tint, dithering or icon on or off
//   pause      no tint or dimming for a while (60 minutes by default)
//   night      Night until sunrise
//   resume     end a pause or night
//   reset      the default looks
//   apply      apply no dithering and the tint again now
//   install    copy this binary to ~/.local/bin and load the LaunchAgents
//   uninstall  unload them, restore the link and dithering, remove the files
//   agent      (local.dusk.display) wait for displays to settle, then apply no dithering
//   tint       (local.dusk.tint) show the warm tint and dimming, and the menu bar icon

import Foundation
import notify

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

func usage() -> Never {
    print("""
    usage: dusk status
           dusk set day warmth <1700-6500 K>
           dusk set evening warmth <1200-4000 K>
           dusk set night warmth <0-2700 K>
           dusk set day|evening|night brightness <30-100 %>
           dusk set tint|dither|icon on|off
           dusk pause [minutes]
           dusk night
           dusk resume
           dusk reset
           dusk apply
           dusk install
           dusk uninstall
    """)
    exit(2)
}

/// Change and save the settings, and tell the running `dusk tint`.
func change(_ edit: (inout Settings) -> Void) {
    var s = Settings.load()
    edit(&s)
    s.save()
    notify_post(settingsChanged)
}

func set(_ args: [String]) {
    switch (args.first, args.count) {
    case (let name?, 2) where ["tint", "dither", "icon"].contains(name) && ["on", "off"].contains(args[1]):
        let on = args[1] == "on"
        change {
            switch name {
            case "tint": $0.enabled = on
            case "dither": $0.noDither = !on
            default: $0.icon = on
            }
        }
        if name == "dither" { on ? restoreDisplay() : applyDisplay() }
    case (let name?, 3):
        guard let phase = Phase.allCases.first(where: { $0.name.lowercased() == name }), let value = Double(args[2]) else { usage() }
        switch args[1] {
        case "warmth" where phase.warmthRange.contains(value): change { $0.kelvin[phase.rawValue] = value }
        case "brightness" where (30...100).contains(value): change { $0.brightness[phase.rawValue] = value / 100 }
        default: usage()
        }
    default: usage()
    }
}

func install() throws {
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
    let jobs: [(name: String, args: [String], keys: [String: Any])] = [
        // launchd watches IOKit and starts the job only when a monitor's AV service appears.
        ("display", ["agent"], ["LaunchEvents": ["com.apple.iokit.matching": ["display attached": [
            "IOProviderClass": "DCPAVServiceProxy",
            "IOPropertyMatch": ["Location": "External"],
            "IOMatchLaunchStream": true,
        ]]]]),
        ("tint", ["tint"], ["KeepAlive": true]),
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
    // Stopping `dusk tint` makes macOS drop its gamma tables.
    for job in ["tint", "display"] {
        launchctl("bootout", "\(domain)/local.dusk.\(job)")
        try? FileManager.default.removeItem(at: agentPlist(job))
    }
    restoreDisplay()
    Settings.store.removePersistentDomain(forName: "local.dusk")
    try? FileManager.default.removeItem(at: installedBinary)
    print("removed the LaunchAgents, \(installedBinary.path) and the settings")
}

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "status":
    displayStatus()
    tintStatus()
case "set": set(Array(args.dropFirst()))
case "pause":
    guard let minutes = args.count == 1 ? 60 : Double(args[1]), minutes > 0, args.count <= 2 else { usage() }
    change { $0.pause(minutes: minutes, at: Clock.now) }
case "night": change { $0.nightUntilSunrise(at: Clock.now) }
case "resume": change { $0.resume() }
case "reset": change { $0.resetLooks() }
case "apply":
    Settings.load().noDither ? applyDisplay() : print("no dithering is off (dusk set dither off turns it on)")
    notify_post(settingsChanged)
case "install": do { try install() } catch { fail("install failed: \(error)") }
case "uninstall": uninstall()
case "agent": displayAgent()
case "tint": runTint()
default: usage()
}
exit(failed ? 1 : 0)
