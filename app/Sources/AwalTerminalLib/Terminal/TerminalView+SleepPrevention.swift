import AppKit
import IOKit
import IOKit.pwr_mgt

// MARK: - Sleep Prevention

extension TerminalView {

    func acquireSleepAssertion() {
        guard sleepAssertionID == IOPMAssertionID(kIOPMNullAssertionID) else { return }
        IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Awal Terminal: active terminal output" as CFString,
            &sleepAssertionID
        )
        onSleepPreventionChanged?(true)
    }

    func releaseSleepAssertion() {
        guard sleepAssertionID != IOPMAssertionID(kIOPMNullAssertionID) else { return }
        IOPMAssertionRelease(sleepAssertionID)
        sleepAssertionID = IOPMAssertionID(kIOPMNullAssertionID)
        onSleepPreventionChanged?(false)
    }
}
