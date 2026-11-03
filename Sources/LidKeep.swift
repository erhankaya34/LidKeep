import AppKit
import ServiceManagement

private enum Settings {
    static let durationKey = "sessionMinutes"
    static let batteryKey = "batteryFloor"
    static let unlimitedACKey = "unlimitedWhilePluggedIn"
    static let markerKey = "ownsSleepOverride"
    static let defaultMinutes = 120
    static let defaultBatteryFloor = 25
    static let durations = [30, 60, 120]
    static let batteryFloors = [20, 25, 30]
}

struct CommandResult {
    let status: Int32
    let output: String
}

struct SystemControl {
    var execute: (String, [String]) -> CommandResult = Self.run

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

    func sleepIsDisabled() -> Bool? {
        let result = execute("/usr/bin/pmset", ["-g"])
        guard result.status == 0 else { return nil }
        for line in result.output.split(separator: "\n") {
            let words = line.split(whereSeparator: { $0.isWhitespace })
            if words.count == 2 && words[0] == "SleepDisabled" {
                return words[1] == "1"
            }
        }
        return nil
    }

    func setSleepDisabled(_ disabled: Bool) -> CommandResult {
        // -k with a command ignores cached sudo credentials. A session must
        // have the narrow, persistent rule to be allowed to start.
        execute("/usr/bin/sudo", ["-n", "-k", "/usr/bin/pmset", "-a", "disablesleep", disabled ? "1" : "0"])
    }

    func battery() -> (percentage: Int, onBattery: Bool)? {
        let result = execute("/usr/bin/pmset", ["-g", "batt"])
        guard result.status == 0 else { return nil }
        let onBattery = result.output.contains("Battery Power")
        guard let match = result.output.range(of: #"\b\d{1,3}%"#, options: .regularExpression),
              let percentage = Int(result.output[match].dropLast()) else { return nil }
        return (percentage, onBattery)
    }

    func changePermission(remove: Bool) -> CommandResult {
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
        return execute("/usr/bin/osascript", [
            "-e", "on run argv",
            "-e", "do shell script (item 1 of argv) with administrator privileges",
            "-e", "end run",
            script
        ])
    }
}

@MainActor
final class LidKeepApp: NSObject, NSApplicationDelegate {
    private let defaults: UserDefaults
    private let now: () -> Date
    private let system: SystemControl
    private let errorHandler: ((String, String) -> Void)?

    init(defaults: UserDefaults = .standard, system: SystemControl = SystemControl(),
         now: @escaping () -> Date = Date.init,
         errorHandler: ((String, String) -> Void)? = nil) {
        self.defaults = defaults
        self.system = system
        self.now = now
        self.errorHandler = errorHandler
        super.init()
    }
    private var statusItem: NSStatusItem!
    private var menu = NSMenu()
    private(set) var refreshTimer: Timer?
    private var deadline: Date?
    private var remainingSeconds: TimeInterval = 0
    private var unlimitedActive = false
    private(set) var active = false
    private var lastMessage = "Ready"
    private var restoringSleep = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "LidKeep"
        statusItem.menu = menu

        // An earlier process may have crashed while its system override was on.
        // Only restore the setting when this app recorded that it owned it.
        if defaults.bool(forKey: Settings.markerKey) {
            if system.sleepIsDisabled() != false {
                let result = system.setSleepDisabled(false)
                if result.status != 0 {
                    active = true
                    restoringSleep = true
                    lastMessage = "Could not restore sleep: \(result.output)"
                }
                else { defaults.removeObject(forKey: Settings.markerKey) }
            } else {
                defaults.removeObject(forKey: Settings.markerKey)
            }
        }

        rebuildMenu()
        let timer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refreshTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard active || defaults.bool(forKey: Settings.markerKey) else { return .terminateNow }
        if system.sleepIsDisabled() == false {
            defaults.removeObject(forKey: Settings.markerKey)
            return .terminateNow
        }
        let result = system.setSleepDisabled(false)
        if result.status == 0 {
            active = false
            defaults.removeObject(forKey: Settings.markerKey)
            return .terminateNow
        }
        active = true
        restoringSleep = true
        lastMessage = "Could not restore normal sleep; retrying"
        rebuildMenu()
        showError("LidKeep could not restore normal sleep. It will remain open and retry.", result.output)
        return .terminateCancel
    }

    private var unlimitedWhilePluggedIn: Bool {
        defaults.object(forKey: Settings.unlimitedACKey) as? Bool ?? true
    }

    private var minutes: Int {
        let value = defaults.integer(forKey: Settings.durationKey)
        return Settings.durations.contains(value) ? value : Settings.defaultMinutes
    }

    private var batteryFloor: Int {
        let value = defaults.integer(forKey: Settings.batteryKey)
        return Settings.batteryFloors.contains(value) ? value : Settings.defaultBatteryFloor
    }

    func refresh() {
        guard active else { return }
        if restoringSleep {
            deactivate(reason: "Normal sleep restored")
            return
        }
        guard let battery = system.battery() else {
            deactivate(reason: "Could not read power status")
            return
        }
        updateTimeLimit(onBattery: battery.onBattery)
        if let deadline, now() >= deadline {
            deactivate(reason: "Time limit reached")
            return
        }
        if battery.onBattery, battery.percentage <= batteryFloor {
            deactivate(reason: "Battery reached \(batteryFloor)%")
            return
        }
        if ProcessInfo.processInfo.thermalState == .serious || ProcessInfo.processInfo.thermalState == .critical {
            deactivate(reason: "Mac temperature is high")
            return
        }
        if system.sleepIsDisabled() == false {
            active = false
            deadline = nil
            defaults.removeObject(forKey: Settings.markerKey)
            lastMessage = "Sleep setting changed outside LidKeep"
        }
        rebuildMenu()
    }

    func activate() {
        guard !active else { return }
        guard let battery = system.battery() else {
            showError("Could not read the Mac power status.", "Try again when the power source is available.")
            return
        }
        if battery.onBattery, battery.percentage <= batteryFloor {
            showError("Battery is at or below the \(batteryFloor)% safety limit.", "Charge the Mac or choose another limit.")
            return
        }
        if ProcessInfo.processInfo.thermalState == .serious || ProcessInfo.processInfo.thermalState == .critical {
            showError("Mac temperature is high.", "Let it cool down before enabling LidKeep.")
            return
        }
        guard system.sleepIsDisabled() == false else {
            showError("The Mac sleep setting is already changed.", "Turn off the other sleep utility before using LidKeep.")
            return
        }
        defaults.set(true, forKey: Settings.markerKey)
        let result = system.setSleepDisabled(true)
        if result.status != 0 {
            defaults.removeObject(forKey: Settings.markerKey)
            showError("Permission is required to keep the Mac awake with its lid closed.",
                      "Choose ‘Set Up Permission’ in the menu, then try again.\n\n\(result.output)")
            return
        }
        guard system.sleepIsDisabled() == true else {
            let restore = system.setSleepDisabled(false)
            if restore.status == 0 {
                defaults.removeObject(forKey: Settings.markerKey)
                showError("Could not verify the system sleep setting.", "The override was reverted.")
            } else {
                active = true
                restoringSleep = true
                lastMessage = "Could not verify sleep setting"
                rebuildMenu()
                showError("Could not restore the system sleep setting.", restore.output)
            }
            return
        }
        active = true
        remainingSeconds = Double(minutes * 60)
        deadline = now().addingTimeInterval(remainingSeconds)
        updateTimeLimit(onBattery: battery.onBattery)
        lastMessage = "Active"
        rebuildMenu()
    }

    private func updateTimeLimit(onBattery: Bool) {
        if unlimitedWhilePluggedIn && !onBattery {
            if let deadline { remainingSeconds = max(0, deadline.timeIntervalSince(now())) }
            deadline = nil
            unlimitedActive = true
        } else if unlimitedActive {
            deadline = now().addingTimeInterval(remainingSeconds)
            unlimitedActive = false
        }
    }

    func deactivate(reason: String = "Ready") {
        guard active || defaults.bool(forKey: Settings.markerKey) else { return }
        if system.sleepIsDisabled() != false {
            let result = system.setSleepDisabled(false)
            if result.status != 0 {
                let alreadyRestoring = restoringSleep
                active = true
                restoringSleep = true
                lastMessage = "Could not restore normal sleep; retrying"
                rebuildMenu()
                if !alreadyRestoring { showError("Could not restore normal sleep.", result.output) }
                return
            }
        }
        active = false
        restoringSleep = false
        unlimitedActive = false
        deadline = nil
        defaults.removeObject(forKey: Settings.markerKey)
        lastMessage = reason
        rebuildMenu()
    }

    @objc private func toggle() {
        if active { deactivate() } else { activate() }
    }

    @objc private func setDuration(_ sender: NSMenuItem) {
        guard Settings.durations.contains(sender.tag) else { return }
        defaults.set(sender.tag, forKey: Settings.durationKey)
        if active && !restoringSleep {
            remainingSeconds = Double(sender.tag * 60)
            deadline = unlimitedActive ? nil : now().addingTimeInterval(remainingSeconds)
        }
        rebuildMenu()
    }

    @objc private func toggleUnlimitedAC() {
        defaults.set(!unlimitedWhilePluggedIn, forKey: Settings.unlimitedACKey)
        if active { refresh() } else { rebuildMenu() }
    }

    @objc private func setBatteryFloor(_ sender: NSMenuItem) {
        defaults.set(sender.tag, forKey: Settings.batteryKey)
        refresh()
        rebuildMenu()
    }

    @objc private func setUpPermission() {
        let result = system.changePermission(remove: false)
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
        let result = system.changePermission(remove: true)
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
        alert.informativeText = "Keep a Mac awake with its lid closed. With ‘Unlimited while plugged in’ enabled, AC sessions stay on until you turn them off. Battery sessions keep their time and battery limits. Temperature protection remains active.\n\nLidKeep does not collect data or use a network connection."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc private func quit() { NSApp.terminate(nil) }

    private func showError(_ title: String, _ details: String) {
        if let errorHandler {
            errorHandler(title, details)
            return
        }
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
        if active && unlimitedActive && !restoringSleep {
            let item = NSMenuItem(title: "Plugged in · On until Turn Off", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        } else if active, let deadline, !restoringSleep {
            let remaining = max(0, Int(ceil(deadline.timeIntervalSince(now()) / 60)))
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

        let unlimited = actionItem("Unlimited while plugged in", #selector(toggleUnlimitedAC))
        unlimited.state = unlimitedWhilePluggedIn ? .on : .off
        menu.addItem(unlimited)

        let durationMenu = NSMenu()
        for option in Settings.durations {
            let item = actionItem("\(option) minutes", #selector(setDuration(_:)))
            item.tag = option
            item.state = minutes == option ? .on : .off
            durationMenu.addItem(item)
        }
        let durationItem = NSMenuItem(title: unlimitedWhilePluggedIn ? "Maximum time on battery" : "Maximum time", action: nil, keyEquivalent: "")
        durationItem.submenu = durationMenu
        menu.addItem(durationItem)

        let batteryMenu = NSMenu()
        for option in Settings.batteryFloors {
            let item = actionItem("\(option)%", #selector(setBatteryFloor(_:)))
            item.tag = option
            item.state = batteryFloor == option ? .on : .off
            batteryMenu.addItem(item)
        }
        let batteryItem = NSMenuItem(title: "Turn off on battery at", action: nil, keyEquivalent: "")
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

#if !LIDKEEP_TESTS
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

#endif
