import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let controller = StatusController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Settings.registerDefaults()
        controller.start()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // menu bar only, no Dock icon
app.run()
