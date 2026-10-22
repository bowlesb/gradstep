import Foundation
import Testing
@testable import ScienceReaderCore

@Suite struct FreeAITests {
    private func decode(_ json: String) throws -> FreeAI { try JSONDecoder().decode(FreeAI.self, from: Data(json.utf8)) }
    private let november = ISO8601DateFormatter().date(from: "2026-11-01T00:00:00Z")!

    @Test func decodesTheServerShape() throws {
        let usable = try decode(#"{"monthly":50,"available":32,"usable":true,"reason":null,"resumes_at":"2026-11-01T00:00:00+00:00","daily":20}"#)
        #expect(usable == FreeAI(monthly: 50, available: 32, usable: true, reason: nil, resumesAt: november, daily: 20))
        let pool = try decode(#"{"monthly":50,"available":40,"usable":false,"reason":"pool","resumes_at":"2026-11-01T00:00:00.000000+00:00","daily":20}"#)
        #expect(pool.reason == .pool && pool.resumesAt == november && !pool.usable)
        let paused = try decode(#"{"monthly":50,"available":40,"usable":false,"reason":"paused","resumes_at":null}"#)
        #expect(paused.reason == .paused && paused.resumesAt == nil && paused.daily == nil)
        // An unknown reason from a later server is not an error: it reads as the generic message.
        let unknown = try decode(#"{"monthly":50,"available":0,"usable":false,"reason":"rationed","resumes_at":null,"daily":20}"#)
        #expect(unknown.reason == nil)
        #expect(FreeAIText.message(for: unknown, premiumModel: false) == nil)
        #expect(throws: (any Error).self) { try decode(#"{"monthly":"50","available":0,"usable":false}"#) }
    }

    @Test func everyReasonHasItsMessage() {
        #expect(FreeAIText.message(reason: .pool, resumesAt: november, premiumModel: false)
                == "This month’s free AI has all been used. It comes back on November 1. Reading is unaffected, and a plan or credit pack works right away.")
        for reason in [FreeAI.Reason.used, .account] {
            #expect(FreeAIText.message(reason: reason, resumesAt: november, premiumModel: false)
                    == "You’ve used this month’s free AI. It comes back on November 1. Reading is unaffected, and a plan or credit pack works right away.")
        }
        #expect(FreeAIText.message(reason: .daily, resumesAt: november, premiumModel: false)
                == "You’ve used today’s free AI. More tomorrow, or a plan or credit pack works right away.")
        #expect(FreeAIText.message(reason: .paused, resumesAt: nil, premiumModel: false)
                == "Free AI is paused for now. Reading is unaffected, and a plan or credit pack works right away.")
        #expect(FreeAIText.message(reason: nil, resumesAt: nil, premiumModel: true)
                == "Free AI covers the fast models (Gemini Flash, DeepSeek and Haiku). Choose one in AI options, or get credits for Sonnet and Opus.")
        #expect(FreeAIText.message(reason: nil, resumesAt: nil, premiumModel: false) == nil)
    }

    @Test func theBalanceDecidesWhichMessage() {
        let usable = FreeAI(monthly: 50, available: 30, usable: true)
        #expect(FreeAIText.message(for: usable, premiumModel: false) == nil, "usable free credits: the generic message")
        #expect(FreeAIText.message(for: usable, premiumModel: true) == FreeAIText.premium)
        #expect(FreeAIText.message(for: nil, premiumModel: true) == nil, "not on the free tier")
        let used = FreeAI(monthly: 50, available: 50, usable: false, reason: .pool, resumesAt: november)
        #expect(FreeAIText.message(for: used, premiumModel: true)?.hasPrefix("This month’s free AI has all been used.") == true)
    }

    @Test func datesAreUTCAndSettingsRowsAreShort() {
        // 23:30 on October 31 in California is already November 1 UTC: free AI resets on UTC days.
        #expect(FreeAIText.day(november) == "November 1")
        #expect(FreeAIText.shortDay(november) == "Nov 1")
        #expect(FreeAIText.settingsValue(FreeAI(monthly: 50, available: 32, usable: true)) == "32 of 50 left")
        #expect(FreeAIText.settingsValue(FreeAI(monthly: 50, available: 40, usable: false, reason: .pool, resumesAt: november)) == "Used up · back Nov 1")
        #expect(FreeAIText.settingsValue(FreeAI(monthly: 50, available: 0, usable: false, reason: .used, resumesAt: november)) == "Used up · back Nov 1")
        #expect(FreeAIText.settingsValue(FreeAI(monthly: 50, available: 10, usable: false, reason: .daily)) == "Back tomorrow")
        #expect(FreeAIText.settingsValue(FreeAI(monthly: 50, available: 10, usable: false, reason: .paused)) == "Paused")
        #expect(FreeAIText.planInfo.hasPrefix("Reading papers is always free. AI uses credits.\n\nFree: 50 credits a month"))
        #expect(FreeAIText.planInfo.hasSuffix("Prices are shown in Get credits."))
    }
}
