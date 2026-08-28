import Foundation
import Testing
@testable import Phone

@Test func resolvesCalledProfileThenActiveThenGlobalFallback() {
    let active = profileAccount(
        username: "active",
        domain: "example.com",
        profile: .travelIntake,
        instructions: "Active instructions",
        context: "Active data"
    )
    let called = profileAccount(
        username: "called",
        domain: "example.net",
        profile: .hotelDemo,
        instructions: "Called instructions",
        context: "Called data"
    )
    let accounts = [active, called]

    let calledResult = resolveAssistantProfile(
        accounts: accounts,
        calledAOR: "sip:CALLED@example.net;user=phone",
        activeSIPAddress: active.sipAddress,
        globalInstructions: "Global"
    )
    let activeResult = resolveAssistantProfile(
        accounts: accounts,
        calledAOR: "unknown@example.org",
        activeSIPAddress: active.sipAddress,
        globalInstructions: "Global"
    )
    let globalResult = resolveAssistantProfile(
        accounts: accounts,
        calledAOR: "unknown@example.org",
        activeSIPAddress: "missing@example.org",
        globalInstructions: "Global"
    )

    #expect(calledResult.account == called)
    #expect(calledResult.instructions == "Called instructions")
    #expect(calledResult.contextData == "Called data")
    #expect(activeResult.account == active)
    #expect(activeResult.instructions == "Active instructions")
    #expect(activeResult.contextData == "Active data")
    #expect(globalResult.account == nil)
    #expect(globalResult.instructions == "Global")
    #expect(globalResult.contextData == nil)
}

@Test func personalProfileUsesGlobalInstructionsWhenNotOverridden() {
    let account = profileAccount(username: "personal", domain: "example.com", profile: .personalAssistant)
    let result = resolveAssistantProfile(
        accounts: [account],
        calledAOR: account.sipAddress,
        activeSIPAddress: nil,
        globalInstructions: "Global personal instructions"
    )

    #expect(result.instructions == "Global personal instructions")
    #expect(result.contextData == nil)
}

@Test func hotelAvailabilityHasFourteenDeterministicThreeRoomRows() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
    let date = try #require(calendar.date(from: DateComponents(year: 2026, month: 8, day: 28)))
    let first = hotelAvailabilityTable(startingAt: date, calendar: calendar)
    let second = hotelAvailabilityTable(startingAt: date, calendar: calendar)
    let lines = first.split(separator: "\n").map(String.init)
    let rows = Array(lines.dropFirst(2))

    #expect(first == second)
    #expect(lines.count == 16)
    #expect(rows.count == 14)
    #expect(rows.first?.hasPrefix("2026-08-28 | ") == true)
    #expect(rows.last?.hasPrefix("2026-09-10 | ") == true)
    #expect(rows.allSatisfy { $0.components(separatedBy: " | ").count == 4 })
    #expect(lines[1].contains("Doppelzimmer Meerblick (145 €/Nacht)"))
    #expect(lines[1].contains("Doppelzimmer Garten (115 €/Nacht)"))
    #expect(lines[1].contains("Suite (210 €/Nacht)"))
    #expect(rows.filter { $0.contains("ausgebucht") }.count >= 3)
}

@Test func composesAssistantInstructionsWithContextData() {
    #expect(
        composeAssistantSystemInstruction(instructions: "  Profilanweisung  ", contextData: "  Zimmer: frei  ") ==
        "Profilanweisung\n\nDaten:\nZimmer: frei"
    )
    #expect(
        composeAssistantSystemInstruction(instructions: "Profilanweisung", contextData: nil) ==
        "Profilanweisung"
    )
    #expect(
        composeAssistantSystemInstruction(instructions: "", contextData: "Kontakt: Beispiel") ==
        "Daten:\nKontakt: Beispiel"
    )
    #expect(
        composeAssistantSystemInstruction(
            instructions: "Profilanweisung",
            contextData: "Zimmer: frei",
            includesGreetingTrigger: true
        ) == "Profilanweisung\n\nDaten:\nZimmer: frei\n\n\(assistantGreetingTrigger)"
    )
}

private func profileAccount(
    username: String,
    domain: String,
    profile: AssistantProfile,
    instructions: String? = nil,
    context: String? = nil
) -> ManagedSIPAccount {
    ManagedSIPAccount(
        provider: .custom,
        username: username,
        domain: domain,
        outboundProxy: "",
        stunServer: "",
        mediaEncryption: "",
        assistantProfile: profile,
        assistantInstructionsOverride: instructions,
        assistantContextData: context
    )
}
