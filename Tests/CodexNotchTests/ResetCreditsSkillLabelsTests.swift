import Foundation
import Testing
@testable import CodexNotch

@Test func resetCreditsListsEveryKnownRemainingTime() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let display = try #require(
        ResetCreditsDisplay(
            resetCredits: RateLimitResetCredits(
                availableCount: 3,
                credits: [
                    RateLimitResetCredit(
                        id: "first",
                        expiresAt: now.addingTimeInterval(9 * 86_400 + 2 * 3_600)
                    ),
                    RateLimitResetCredit(
                        id: "second",
                        expiresAt: now.addingTimeInterval(22 * 86_400 + 5 * 3_600)
                    ),
                    RateLimitResetCredit(
                        id: "third",
                        expiresAt: now.addingTimeInterval(23 * 86_400 + 2 * 3_600)
                    )
                ],
                fetchedAt: now
            )
        )
    )

    #expect(display.remainingExpiryText(at: now) == "9d 2h · 22d 5h · 23d 2h")
    #expect(display.nearestExpiryText(at: now) == "最近到期 9天2小时")
}

@Test func skillInsightsKeepsSkillTermAndExplainsDisabledMatches() {
    #expect(SkillInsightsDisplayLabels.nameColumn == "Skill")
    #expect(SkillInsightsDisplayLabels.shadowEvidence == "关闭匹配")
    #expect(SkillInsightsDisplayLabels.shadowExplanation.contains("不代表该 Skill 实际执行"))
    #expect(SkillInsightsDisplayLabels.shadowExplanation.contains("复测或恢复"))
}
