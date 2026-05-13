import Testing
import Foundation
@testable import GargantuaCore

@Suite("MCP status tool handler uptime formatting")
struct MCPStatusToolHandlerUptimeTests {

    @Test("uptime formats as days+hours when >= 1 day")
    func uptimeDaysAndHours() {
        let formatted = MCPStatusToolHandler.formatUptime(6 * 86_400 + 12 * 3_600)
        #expect(formatted == "6d 12h")
    }

    @Test("uptime formats as hours+minutes when < 1 day")
    func uptimeHoursAndMinutes() {
        let formatted = MCPStatusToolHandler.formatUptime(3 * 3_600 + 15 * 60)
        #expect(formatted == "3h 15m")
    }

    @Test("uptime formats as minutes when < 1 hour")
    func uptimeMinutesOnly() {
        let formatted = MCPStatusToolHandler.formatUptime(42 * 60)
        #expect(formatted == "42m")
    }

    @Test("uptime at exactly 1 day renders 1d 0h")
    func uptimeExactlyOneDay() {
        let formatted = MCPStatusToolHandler.formatUptime(86_400)
        #expect(formatted == "1d 0h")
    }

    @Test("uptime zero renders 0m")
    func uptimeZero() {
        let formatted = MCPStatusToolHandler.formatUptime(0)
        #expect(formatted == "0m")
    }

    @Test("negative uptime clamps to 0m")
    func uptimeNegativeClamped() {
        let formatted = MCPStatusToolHandler.formatUptime(-100)
        #expect(formatted == "0m")
    }

    @Test("NaN uptime falls back to 0m instead of trapping")
    func uptimeNaN() {
        let formatted = MCPStatusToolHandler.formatUptime(.nan)
        #expect(formatted == "0m")
    }

    @Test("infinite uptime falls back to 0m instead of trapping")
    func uptimeInfinite() {
        #expect(MCPStatusToolHandler.formatUptime(.infinity) == "0m")
        #expect(MCPStatusToolHandler.formatUptime(-.infinity) == "0m")
    }

    @Test("uptime larger than Int.max saturates instead of trapping")
    func uptimeBeyondIntMax() {
        // 1e20 seconds is far beyond Int64.max; must not trap on Int(_:).
        let formatted = MCPStatusToolHandler.formatUptime(1e20)
        // Expect some days-formatted value (non-empty, non-"0m" — saturation
        // lands us at Int.max seconds which is ~106 quadrillion days).
        #expect(formatted.hasSuffix("h"))
        #expect(!formatted.isEmpty)
    }
}
