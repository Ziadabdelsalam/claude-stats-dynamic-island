import AppKit

// `.accessory`: menu-bar-only, no Dock icon, no Cmd-Tab entry. Set here (not just in
// `Info.plist`'s `LSUIElement`) because the plist key only takes effect for the bundled
// `.app` — `swift run ClaudeStatsApp` during development has no Info.plist at all.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let delegate = AppDelegate()
app.delegate = delegate

app.run()
