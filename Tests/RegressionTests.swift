import AppKit
import CoreFoundation

@MainActor
private final class Machine {
    var sleepDisabled = false
    var sleepReadable = true
    var canSetSleep = true
    var onBattery = false
    var percentage = 100
    var time = Date(timeIntervalSince1970: 1_800_000_000)
    var writes: [Bool] = []
    var errors: [String] = []

    var control: SystemControl {
        SystemControl(execute: { [self] path, args in
            if path == "/usr/bin/pmset", args == ["-g"] {
                return CommandResult(status: sleepReadable ? 0 : 1,
                                     output: sleepReadable ? "SleepDisabled\t\t\(sleepDisabled ? 1 : 0)\n" : "read failed")
            }
            if path == "/usr/bin/pmset", args == ["-g", "batt"] {
                return CommandResult(status: 0, output: "Now drawing from '\(onBattery ? "Battery Power" : "AC Power")'\n -InternalBattery-0\t\(percentage)%; \(onBattery ? "discharging" : "charged"); present: true\n")
            }
            if path == "/usr/bin/sudo", args.contains("disablesleep") {
                let value = args.last == "1"
                writes.append(value)
                if canSetSleep { sleepDisabled = value }
                return CommandResult(status: canSetSleep ? 0 : 1, output: canSetSleep ? "" : "permission denied")
            }
            return CommandResult(status: 1, output: "Unexpected command: \(path) \(args)")
        })
    }
}

@MainActor
private func withApp(_ body: (LidKeepApp, Machine, UserDefaults) throws -> Void,
                     owned: Bool = false) rethrows {
    let suite = "LidKeep.RegressionTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.set(owned, forKey: "ownsSleepOverride")
    let machine = Machine()
    machine.sleepDisabled = owned
    if owned {
        machine.sleepReadable = false
        machine.canSetSleep = false
    }
    let app = LidKeepApp(defaults: defaults, system: machine.control, now: { machine.time },
                         errorHandler: { title, _ in machine.errors.append(title) })
    app.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
    defer {
        app.refreshTimer?.invalidate()
        defaults.removePersistentDomain(forName: suite)
    }
    try body(app, machine, defaults)
}

private struct Failure: Error, CustomStringConvertible {
    let description: String
}

private func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw Failure(description: message) }
}

@main
private enum RegressionTests {
    @MainActor
    static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let tests: [(String, () throws -> Void)] = [
            ("unreadable sleep setting retains crash-recovery ownership", {
                try withApp({ app, machine, defaults in
                    try expect(defaults.bool(forKey: "ownsSleepOverride"), "Lost ownership while the system setting was unreadable")
                    try expect(app.active, "Recovery failure must remain visible as On")
                    machine.sleepReadable = true
                    machine.canSetSleep = true
                    app.refresh()
                    try expect(!machine.sleepDisabled && !app.active, "Recovery must retry and restore normal sleep")
                    try expect(!defaults.bool(forKey: "ownsSleepOverride"), "Successful recovery must clear ownership")
                }, owned: true)
            }),
            ("plugged-in sessions stay on without time or battery limits until Off", {
                try withApp { app, machine, _ in
                    machine.percentage = 1
                    app.activate()
                    machine.time.addTimeInterval(7 * 24 * 60 * 60)
                    app.refresh()
                    try expect(app.active && machine.sleepDisabled, "Plugged-in session expired automatically")
                    app.deactivate()
                    try expect(!app.active && !machine.sleepDisabled, "Off must restore normal sleep")
                }
            }),
            ("plugging in pauses battery time and unplugging resumes the remainder", {
                try withApp { app, machine, _ in
                    machine.onBattery = true
                    app.activate()
                    machine.time.addTimeInterval(30 * 60)
                    machine.onBattery = false
                    app.refresh()
                    machine.time.addTimeInterval(3 * 24 * 60 * 60)
                    app.refresh()
                    try expect(app.active, "AC power must pause the battery timer")
                    machine.onBattery = true
                    app.refresh()
                    machine.time.addTimeInterval(89 * 60)
                    app.refresh()
                    try expect(app.active, "Battery time expired before its remaining 90 minutes")
                    machine.time.addTimeInterval(2 * 60)
                    app.refresh()
                    try expect(!app.active && !machine.sleepDisabled, "Battery time limit must resume after unplugging")
                }
            }),
            ("battery floor still stops an unplugged unlimited session", {
                try withApp { app, machine, defaults in
                    defaults.set(25, forKey: "batteryFloor")
                    app.activate()
                    machine.onBattery = true
                    machine.percentage = 25
                    app.refresh()
                    try expect(!app.active && !machine.sleepDisabled, "Battery floor was ignored after unplugging")
                }
            }),
            ("disabling unlimited mode keeps the original plugged-in time limit", {
                try withApp { app, machine, defaults in
                    defaults.set(false, forKey: "unlimitedWhilePluggedIn")
                    app.activate()
                    machine.time.addTimeInterval(121 * 60)
                    app.refresh()
                    try expect(!app.active && !machine.sleepDisabled, "Timed AC sessions must still expire")
                }
            }),
            ("failed Off is retried without repeated error dialogs", {
                try withApp { app, machine, defaults in
                    app.activate()
                    machine.canSetSleep = false
                    app.deactivate()
                    app.refresh()
                    try expect(app.active && defaults.bool(forKey: "ownsSleepOverride"), "Failed Off lost ownership")
                    try expect(machine.errors.count == 1, "Retry must not repeatedly open error dialogs")
                    machine.canSetSleep = true
                    app.refresh()
                    try expect(!app.active && !machine.sleepDisabled, "Off was not retried")
                }
            }),
            ("external sleep restoration completes a failed Off without sudo permission", {
                try withApp { app, machine, defaults in
                    app.activate()
                    machine.canSetSleep = false
                    app.deactivate()
                    machine.sleepDisabled = false
                    app.refresh()
                    try expect(!app.active, "Normal sleep was restored externally but the app still reports On")
                    try expect(!defaults.bool(forKey: "ownsSleepOverride"), "External restoration must clear ownership")
                }
            }),
            ("failed Quit retries sleep restoration when permission recovers", {
                try withApp { app, machine, defaults in
                    app.activate()
                    machine.canSetSleep = false
                    let reply = app.applicationShouldTerminate(NSApp)
                    try expect(reply == .terminateCancel, "Quit must wait until normal sleep is restored")
                    try expect(defaults.bool(forKey: "ownsSleepOverride"), "Failed Quit must retain ownership")
                    machine.canSetSleep = true
                    app.refresh()
                    try expect(!app.active && !machine.sleepDisabled, "Failed Quit did not retry restoration")
                }
            }),
            ("safety timer runs while a menu is tracking", {
                try withApp { app, machine, defaults in
                    defaults.set(false, forKey: "unlimitedWhilePluggedIn")
                    app.activate()
                    try expect(app.active, "Session failed to start")
                    machine.time.addTimeInterval(121 * 60)
                    app.refreshTimer?.fireDate = Date()
                    CFRunLoopAddCommonMode(CFRunLoopGetCurrent(), CFRunLoopMode(rawValue: RunLoop.Mode.eventTracking.rawValue as CFString))
                    _ = CFRunLoopRunInMode(CFRunLoopMode(rawValue: RunLoop.Mode.eventTracking.rawValue as CFString), 0.1, false)
                    try expect(!app.active && !machine.sleepDisabled, "Open menu suspended the time-limit check")
                }
            })
        ]
        var failures = 0
        for (name, test) in tests {
            do { try test(); print("PASS: \(name)") }
            catch { failures += 1; print("FAIL: \(name): \(error)") }
        }
        print("\(tests.count - failures)/\(tests.count) tests passed")
        if failures != 0 { exit(1) }
    }
}
