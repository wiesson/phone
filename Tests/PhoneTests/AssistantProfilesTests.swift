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

@Test func migratesCustomOverrideIntoSavedProfile() throws {
    let account = ManagedSIPAccount(
        provider: .custom,
        username: "reception",
        domain: "example.com",
        outboundProxy: "",
        stunServer: "",
        mediaEncryption: "",
        label: "Front desk",
        assistantProfile: .custom,
        assistantInstructionsOverride: "Answer as the front desk",
        assistantContextData: "Hours: 09:00–17:00"
    )

    let migrated = migrateSavedAssistantProfiles(
        in: ManagedAccountsFile(accounts: [account], activeSIPAddress: account.sipAddress)
    )
    let profile = try #require(migrated.savedProfiles?.first)

    #expect(migrated.savedProfiles?.count == 1)
    #expect(profile.name == "Custom (Front desk)")
    #expect(profile.instructions == "Answer as the front desk")
    #expect(profile.contextData == "Hours: 09:00–17:00")
    #expect(migrated.accounts.first?.savedProfileID == profile.id)
    #expect(migrated.accounts.first?.assistantInstructionsOverride == "Answer as the front desk")
}

@Test func migrationDeduplicatesIdenticalInstructions() throws {
    let first = profileAccount(
        username: "first",
        domain: "example.com",
        profile: .custom,
        instructions: "Shared instructions"
    )
    let second = profileAccount(
        username: "second",
        domain: "example.net",
        profile: .custom,
        instructions: "Shared instructions"
    )

    let migrated = migrateSavedAssistantProfiles(
        in: ManagedAccountsFile(accounts: [first, second], activeSIPAddress: first.sipAddress)
    )

    #expect(migrated.savedProfiles?.count == 1)
    #expect(migrated.accounts[0].savedProfileID != nil)
    #expect(migrated.accounts[0].savedProfileID == migrated.accounts[1].savedProfileID)
}

@Test func migrationRunsOnlyWhenSavedProfilesFieldIsAbsent() {
    let fallbackAccount = profileAccount(
        username: "fallback",
        domain: "example.com",
        profile: .custom,
        instructions: "Keep this private fallback"
    )
    let alreadyMigrated = ManagedAccountsFile(
        accounts: [fallbackAccount],
        activeSIPAddress: fallbackAccount.sipAddress,
        savedProfiles: []
    )

    let loaded = migrateSavedAssistantProfiles(in: alreadyMigrated)

    #expect(loaded.savedProfiles == [])
    #expect(loaded.accounts.first?.savedProfileID == nil)
    #expect(loaded.accounts.first?.assistantInstructionsOverride == "Keep this private fallback")
}

@Test func savedProfileReferenceResolvesNameInstructionsAndContext() {
    let profile = SavedAssistantProfile(
        name: "Shared reception",
        instructions: "Use the shared prompt",
        contextData: "Shared context"
    )
    let account = ManagedSIPAccount(
        provider: .custom,
        username: "reception",
        domain: "example.com",
        outboundProxy: "",
        stunServer: "",
        mediaEncryption: "",
        assistantProfile: .custom,
        savedProfileID: profile.id
    )
    let result = resolveAssistantProfile(
        accounts: [account],
        savedProfiles: [profile],
        calledAOR: account.sipAddress,
        activeSIPAddress: nil,
        globalInstructions: "Global"
    )

    #expect(account.assistantProfileDisplay(savedProfiles: [profile]) == "Shared reception")
    #expect(result.instructions == "Use the shared prompt")
    #expect(result.contextData == "Shared context")
}

@Test func savedProfileInstructionsTakePrecedenceOverAccountOverride() {
    let profile = SavedAssistantProfile(name: "Saved", instructions: "Saved instructions")
    let account = ManagedSIPAccount(
        provider: .custom,
        username: "user",
        domain: "example.com",
        outboundProxy: "",
        stunServer: "",
        mediaEncryption: "",
        assistantProfile: .custom,
        savedProfileID: profile.id,
        assistantInstructionsOverride: "Legacy fallback"
    )
    let result = resolveAssistantProfile(
        accounts: [account],
        savedProfiles: [profile],
        calledAOR: account.sipAddress,
        activeSIPAddress: nil,
        globalInstructions: "Global"
    )

    #expect(result.instructions == "Saved instructions")
}

@Test func managedAccountsFileRoundTripsSavedProfiles() throws {
    let profile = SavedAssistantProfile(
        name: "Reception",
        instructions: "Answer professionally",
        contextData: "Open weekdays"
    )
    let account = profileAccount(
        username: "user",
        domain: "example.com",
        profile: .custom
    )
    let file = ManagedAccountsFile(
        accounts: [account],
        activeSIPAddress: account.sipAddress,
        savedProfiles: [profile]
    )

    let data = try JSONEncoder().encode(file)
    let decoded = try JSONDecoder().decode(ManagedAccountsFile.self, from: data)

    #expect(decoded == file)
}

@Test func managedAccountsFileDecodesAndEncodesWithoutSavedProfiles() throws {
    let json = """
    {
      "accounts": [],
      "activeSIPAddress": null
    }
    """
    let decoded = try JSONDecoder().decode(
        ManagedAccountsFile.self,
        from: try #require(json.data(using: .utf8))
    )
    let encoded = try JSONEncoder().encode(decoded)
    let encodedObject = try #require(
        JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )

    #expect(decoded.savedProfiles == nil)
    #expect(encodedObject["savedProfiles"] == nil)
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
        phoneEtiquettePreamble + "\n\nProfilanweisung\n\nDaten:\nZimmer: frei"
    )
    #expect(
        composeAssistantSystemInstruction(instructions: "Profilanweisung", contextData: nil) ==
        phoneEtiquettePreamble + "\n\nProfilanweisung"
    )
    #expect(
        composeAssistantSystemInstruction(instructions: "", contextData: "Kontakt: Beispiel") ==
        phoneEtiquettePreamble + "\n\nDaten:\nKontakt: Beispiel"
    )
    #expect(
        composeAssistantSystemInstruction(
            instructions: "Profilanweisung",
            contextData: "Zimmer: frei",
            includesGreetingTrigger: true
        ) == phoneEtiquettePreamble + "\n\nProfilanweisung\n\nDaten:\nZimmer: frei\n\n\(assistantGreetingTrigger)"
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
