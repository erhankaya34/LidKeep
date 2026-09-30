import AppKit
import ServiceManagement

private enum Settings {
    static let durationKey = "sessionMinutes"
    static let batteryKey = "batteryFloor"
    static let markerKey = "ownsSleepOverride"
    static let defaultMinutes = 120
    static let defaultBatteryFloor = 25
    static let durations = [30, 60, 120]
    static let batteryFloors = [20, 25, 30]
}

private struct CommandResult {
    let status: Int32
    let output: String
}

private enum SystemControl {
    static func run(_ path: String, _ arguments: [String]) -> CommandResult {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = arguments
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            return CommandResult(status: task.terminationStatus,
                                 output: String(decoding: data, as: UTF8.self))
        } catch {
            return CommandResult(status: -1, output: error.localizedDescription)
        }
    }

    static func sleepIsDisabled() -> Bool? {
        let result = run("/usr/bin/pmset", ["-g"])
        guard result.status == 0 else { return nil }
        for line in result.output.split(separator: "\n") {
            let words = line.split(whereSeparator: { $0.isWhitespace })
            if words.count == 2 && words[0] == "SleepDisabled" {
                return words[1] == "1"
            }
        }
        return nil
    }

    static func setSleepDisabled(_ disabled: Bool) -> CommandResult {
        // -k with a command ignores cached sudo credentials. A session must
        // have the narrow, persistent rule to be allowed to start.
        run("/usr/bin/sudo", ["-n", "-k", "/usr/bin/pmset", "-a", "disablesleep", disabled ? "1" : "0"])
    }

    static func battery() -> (percentage: Int, onBattery: Bool)? {
        let result = run("/usr/bin/pmset", ["-g", "batt"])
        guard result.status == 0 else { return nil }
        let onBattery = result.output.contains("Battery Power")
        guard let match = result.output.range(of: #"\b\d{1,3}%"#, options: .regularExpression),
              let percentage = Int(result.output[match].dropLast()) else { return nil }
        return (percentage, onBattery)
    }

    static func changePermission(remove: Bool) -> CommandResult {
        let user = NSUserName()
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-")
        guard !user.isEmpty && user.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            return CommandResult(status: -1, output: "Unsupported macOS account name.")
        }

        let target = "/etc/sudoers.d/lidkeep-disablesleep"
        let script: String
        let rule = "\(user) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1"
        if remove {
            script = "set -eu; /usr/bin/grep -Fqx '\(rule)' \(target); /bin/rm -- \(target); /usr/sbin/visudo -c"
        } else {
            script = "set -eu; if [ -e \(target) ]; then /usr/bin/grep -Fqx '\(rule)' \(target); exit 0; fi; t=$(/usr/bin/mktemp /etc/sudoers.d/.lidkeep.XXXXXX); trap '/bin/rm -f \"$t\"' EXIT; /usr/bin/printf '%s\\n' '\(rule)' > \"$t\"; /bin/chmod 0440 \"$t\"; /usr/sbin/visudo -cf \"$t\"; /bin/mv \"$t\" \(target); if ! /usr/sbin/visudo -c; then /bin/rm \(target); exit 1; fi"
        }
        return run("/usr/bin/osascript", [
            "-e", "on run argv",
            "-e", "do shell script (item 1 of argv) with administrator privileges",
            "-e", "end run",
            script
        ])
    }
}

@MainActor
private final class LidKeepApp: NSObject, NSApplicationDelegate {
    private let defaults = UserDefaults.standard
    private var statusItem: NSStatusItem!
    private var menu = NSMenu()
    private var refreshTimer: Timer?
    private var deadline: Date?
    private var active = false
    private var lastMessage = "Ready"

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "LidKeep"
        statusItem.menu = menu

        // An earlier process may have crashed while its system override was on.
        // Only restore the setting when this app recorded that it owned it.
        if defaults.bool(forKey: Settings.markerKey) {
            if SystemControl.sleepIsDisabled() == true {
                let result = SystemControl.setSleepDisabled(false)
                if result.status != 0 {
                    active = true
                    lastMessage = "Could not restore sleep: \(result.output)"
                }
                else { defaults.removeObject(forKey: Settings.markerKey) }
            } else {
                defaults.removeObject(forKey: Settings.markerKey)
            }
        }

        rebuildMenu()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard active || defaults.bool(forKey: Settings.markerKey) else { return .terminateNow }
        if SystemControl.sleepIsDisabled() == false {
            defaults.removeObject(forKey: Settings.markerKey)
            return .terminateNow
        }
        let result = SystemControl.setSleepDisabled(false)
        if result.status == 0 {
            active = false
            defaults.removeObject(forKey: Settings.markerKey)
            return .terminateNow
        }
        showError("LidKeep could not restore normal sleep. It will remain open so you can retry.", result.output)
        return .terminateCancel
    }

    private var minutes: Int {
        let value = defaults.integer(forKey: Settings.durationKey)
        return Settings.durations.contains(value) ? value : Settings.defaultMinutes
    }

    private var batteryFloor: Int {
        let value = defaults.integer(forKey: Settings.batteryKey)
        return Settings.batteryFloors.contains(value) ? value : Settings.defaultBatteryFloor
    }

    private func refresh() {
        guard active else { return }
        if let deadline, Date() >= deadline {
            deactivate(reason: "Time limit reached")
            return
        }
        if let battery = SystemControl.battery(), battery.onBattery,
           battery.percentage <= batteryFloor {
            deactivate(reason: "Battery reached \(batteryFloor)%")
            return
        }
        if ProcessInfo.processInfo.thermalState == .serious || ProcessInfo.processInfo.thermalState == .critical {
            deactivate(reason: "Mac temperature is high")
            return
        }
        if SystemControl.sleepIsDisabled() == false {
            active = false
            deadline = nil
            defaults.removeObject(forKey: Settings.markerKey)
            lastMessage = "Sleep setting changed outside LidKeep"
        }
        rebuildMenu()
    }

    private func activate() {
        guard !active else { return }
        if let battery = SystemControl.battery(), battery.onBattery,
           battery.percentage <= batteryFloor {
            showError("Battery is at or below the \(batteryFloor)% safety limit.", "Charge the Mac or choose another limit.")
            return
        }
        if ProcessInfo.processInfo.thermalState == .serious || ProcessInfo.processInfo.thermalState == .critical {
            showError("Mac temperature is high.", "Let it cool down before enabling LidKeep.")
            return
        }
        guard SystemControl.sleepIsDisabled() == false else {
            showError("The Mac sleep setting is already changed.", "Turn off the other sleep utility before using LidKeep.")
            return
        }
        defaults.set(true, forKey: Settings.markerKey)
        let result = SystemControl.setSleepDisabled(true)
        if result.status != 0 {
            defaults.removeObject(forKey: Settings.markerKey)
            showError("Permission is required to keep the Mac awake with its lid closed.",
                      "Choose ‘Set Up Permission’ in the menu, then try again.\n\n\(result.output)")
            return
        }
        guard SystemControl.sleepIsDisabled() == true else {
            let restore = SystemControl.setSleepDisabled(false)
            if restore.status == 0 {
                defaults.removeObject(forKey: Settings.markerKey)
                showError("Could not verify the system sleep setting.", "The override was reverted.")
            } else {
                active = true
                lastMessage = "Could not verify sleep setting"
                rebuildMenu()
                showError("Could not restore the system sleep setting.", restore.output)
            }
            return
        }
        active = true
        deadline = Date().addingTimeInterval(Double(minutes * 60))
        lastMessage = "Active"
        rebuildMenu()
    }

    private func deactivate(reason: String = "Ready") {
        guard active || defaults.bool(forKey: Settings.markerKey) else { return }
        let result = SystemControl.setSleepDisabled(false)
        if result.status != 0 {
            showError("Could not restore normal sleep.", result.output)
            return
        }
        active = false
        deadline = nil
        defaults.removeObject(forKey: Settings.markerKey)
        lastMessage = reason
        rebuildMenu()
    }

    @objc private func toggle() {
        if active { deactivate() } else { activate() }
    }

    @objc private func setDuration(_ sender: NSMenuItem) {
        defaults.set(sender.tag, forKey: Settings.durationKey)
        if active { deadline = Date().addingTimeInterval(Double(sender.tag * 60)) }
        rebuildMenu()
    }

    @objc private func setBatteryFloor(_ sender: NSMenuItem) {
        defaults.set(sender.tag, forKey: Settings.batteryKey)
        refresh()
        rebuildMenu()
    }

    @objc private func setUpPermission() {
        let result = SystemControl.changePermission(remove: false)
        if result.status == 0 {
            lastMessage = "Permission is ready"
            rebuildMenu()
        } else {
            showError("Permission setup was not completed.", result.output)
        }
    }

    @objc private func removePermission() {
        if active { deactivate() }
        guard !active else { return }
        let result = SystemControl.changePermission(remove: true)
        if result.status == 0 {
            lastMessage = "Permission removed"
            rebuildMenu()
        } else {
            showError("Permission removal was not completed.", result.output)
        }
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
            rebuildMenu()
        } catch { showError("Could not change Login Items.", error.localizedDescription) }
    }

    @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "LidKeep"
        alert.informativeText = "Keep a Mac awake with its lid closed for a limited time. The menu bar switch restores normal sleep when turned off or when the timer ends.\n\nLidKeep does not collect data or use a network connection."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc private func quit() { NSApp.terminate(nil) }

    private func showError(_ title: String, _ details: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = details
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func actionItem(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func rebuildMenu() {
        menu.removeAllItems()
        statusItem.button?.title = active ? "LidKeep ●" : "LidKeep"

        let state = NSMenuItem(title: active ? "On · Mac can stay awake" : "Off · Normal sleep", action: nil, keyEquivalent: "")
        state.isEnabled = false
        menu.addItem(state)
        if active, let deadline {
            let remaining = max(0, Int(ceil(deadline.timeIntervalSinceNow / 60)))
            let item = NSMenuItem(title: "Turns off in \(remaining) min", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        } else if lastMessage != "Ready" {
            let item = NSMenuItem(title: lastMessage, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(actionItem(active ? "Turn Off" : "Turn On", #selector(toggle)))

        let durationMenu = NSMenu()
        for option in Settings.durations {
            let item = actionItem("\(option) minutes", #selector(setDuration(_:)))
            item.tag = option
            item.state = minutes == option ? .on : .off
            durationMenu.addItem(item)
        }
        let durationItem = NSMenuItem(title: "Maximum time", action: nil, keyEquivalent: "")
        durationItem.submenu = durationMenu
        menu.addItem(durationItem)

        let batteryMenu = NSMenu()
        for option in Settings.batteryFloors {
            let item = actionItem("\(option)%", #selector(setBatteryFloor(_:)))
            item.tag = option
            item.state = batteryFloor == option ? .on : .off
            batteryMenu.addItem(item)
        }
        let batteryItem = NSMenuItem(title: "Turn off at battery", action: nil, keyEquivalent: "")
        batteryItem.submenu = batteryMenu
        menu.addItem(batteryItem)

        menu.addItem(.separator())
        menu.addItem(actionItem("Set Up Permission…", #selector(setUpPermission)))
        menu.addItem(actionItem("Remove Permission…", #selector(removePermission)))
        let login = actionItem("Open at Login", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(actionItem("About LidKeep", #selector(showAbout)))
        menu.addItem(actionItem("Quit LidKeep", #selector(quit), key: "q"))
    }
}

@main
private enum EntryPoint {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = LidKeepApp()
        app.delegate = delegate
        app.run()
    }
}
