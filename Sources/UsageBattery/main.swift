import AppKit

if let format = CLI.format(from: CommandLine.arguments) {
    exit(CLI.run(format))
}

// One instance only: a second launch pokes the first to show its widget and quits.
if let bundleID = Bundle.main.bundleIdentifier,
   NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).count > 1 {
    DistributedNotificationCenter.default().postNotificationName(
        AppDelegate.showNotification, object: nil, userInfo: nil, deliverImmediately: true)
    exit(0)
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.run()
