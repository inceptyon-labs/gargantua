import Foundation
import Testing
@testable import GargantuaCore

@Suite("Cloud AI personal-detail redaction")
struct CloudAIPersonalDetailRedactionTests {
    @Test("The home folder becomes ~ and email addresses are masked")
    func homeAndEmailRedacted() {
        let home = NSHomeDirectory()
        let input = "\(home)/Library/Caches/com.acme from jane.doe@example.com"

        let output = CloudAIRedactor.sanitizeContent(input)

        #expect(output == "~/Library/Caches/com.acme from [REDACTED_EMAIL]")
    }

    @Test("Organizer prompts scrub folder and file names")
    func organizerPromptScrubbed() {
        let prompt = CloudOrganizerProposer.buildPrompt(folderName: "\(NSHomeDirectory())/Downloads", clusters: [])
        #expect(!prompt.contains(NSHomeDirectory()))
    }
}
