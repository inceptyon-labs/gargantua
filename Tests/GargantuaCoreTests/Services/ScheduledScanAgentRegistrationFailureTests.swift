import Foundation
import Testing
@testable import GargantuaCore

@Suite("ScheduledScanAgentRegistrationFailure")
struct AgentRegistrationFailureTests {
    private func error(_ code: Int, domain: String = "SMAppServiceErrorDomain") -> NSError {
        NSError(domain: domain, code: code, userInfo: [
            NSLocalizedFailureReasonErrorKey:
                "Codesigning failure loading plist: com.inceptyon.gargantua.scheduler.plist code: -67028",
        ])
    }

    @Test("invalid signature maps to the unsigned wording without raw text")
    func unsigned() {
        let message = ScheduledScanAgentRegistrationFailure.message(for: error(3))
        #expect(message == ScheduledScanAgentRegistrationFailure.unsigned)
        #expect(!message.contains("-67028"))
        #expect(!message.contains("Codesigning"))
    }

    @Test("launch denied maps to the Login Items note")
    func loginItems() {
        #expect(ScheduledScanAgentRegistrationFailure.message(for: error(11))
            == ScheduledScanAgentRegistrationFailure.loginItemsApproval)
    }

    @Test("missing plist codes map to the missing-agent wording", arguments: [8, 108])
    func missingAgent(code: Int) {
        #expect(ScheduledScanAgentRegistrationFailure.message(for: error(code))
            == ScheduledScanAgentRegistrationFailure.missingAgent)
    }

    @Test("unknown codes and domains map to the generic wording")
    func generic() {
        #expect(ScheduledScanAgentRegistrationFailure.message(for: error(999))
            == ScheduledScanAgentRegistrationFailure.generic)
        #expect(ScheduledScanAgentRegistrationFailure.message(for: error(3, domain: NSPOSIXErrorDomain))
            == ScheduledScanAgentRegistrationFailure.generic)
    }
}
