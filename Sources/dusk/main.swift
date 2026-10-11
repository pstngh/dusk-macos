// dusk: no temporal dithering on external displays, and a sun-synced warm tint (Apple Silicon, SDR).
//   status     show dithering and the link per external display, the looks and tonight's times
//   set        set a look's warmth (K) or brightness (%)
//   apply      apply no dithering now and reload the settings
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
    notify_post(settingsChanged)
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
    let jobs: [(name: String, args: [String], keys: [String: Any])] = [
        // launchd watches IOKit and starts the job only when a monitor's AV service appears.
        ("display", ["agent"], ["LaunchEvents": ["com.apple.iokit.matching": ["display attached": [
            "IOProviderClass": "DCPAVServiceProxy",
            "IOPropertyMatch": ["Location": "External"],
            "IOMatchLaunchStream": true,
        ]]]]),
        ("tint", menu ? ["tint"] : ["tint", "--no-icon"], ["KeepAlive": true]),
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
case "apply":
    Settings.load().noDither ? applyDisplay() : print("no dithering is turned off in the menu")
    notify_post(settingsChanged)
case "install": do { try install(menu: !args.contains("--no-menu")) } catch { fail("install failed: \(error)") }
case "uninstall": uninstall()
case "agent": displayAgent()
case "tint": runTint(icon: !args.contains("--no-icon"))
default: usage()
}
exit(failed ? 1 : 0)
