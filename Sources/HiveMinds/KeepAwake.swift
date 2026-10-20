import Foundation
import IOKit.pwr_mgt

/// Keeps the display (and so the Mac) from going to sleep while any agent is working, when that's
/// turned on in Settings > Agents. It holds a power assertion only while needed and drops it as soon
/// as the last agent finishes, so normal sleep comes back by itself. Nothing runs on a timer.
@MainActor
enum KeepAwake {
    private static var assertion: IOPMAssertionID?
    private static var working = false

    static var enabled: Bool {
        UserDefaults.standard.object(forKey: SettingKey.keepAwake) as? Bool ?? SettingDefault.keepAwake
    }

    /// Called whenever agent states change.
    static func update(working: Bool) {
        self.working = working
        apply()
    }

    /// Takes or drops the assertion to match the setting and whether anything is working.
    static func apply() {
        let want = enabled && working
        if want, assertion == nil {
            var id = IOPMAssertionID(0)
            let result = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                                     IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                     "HiveMinds agents are working" as CFString, &id)
            if result == kIOReturnSuccess { assertion = id }
        } else if !want, let id = assertion {
            IOPMAssertionRelease(id)
            assertion = nil
        }
    }
}
