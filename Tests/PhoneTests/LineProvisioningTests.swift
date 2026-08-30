import Foundation
import PhoneAutomation
import Testing
@testable import Phone

private func provisioningTestAccount(
    profile: AssistantProfile = .personalAssistant,
    savedProfileID: UUID? = nil
) -> ManagedSIPAccount {
    ManagedSIPAccount(
        provider: .custom,
        username: "agent",
        domain: "sip.example.test",
        outboundProxy: "",
        stunServer: "",
        mediaEncryption: "",
        label: "Support",
        assistantProfile: profile,
        savedProfileID: savedProfileID
    )
}

@Test func provisioningArgumentsApplyPresetDefaultsAndExplicitOverrides() throws {
    let created = try managedSIPAccount(from: ControlCreateLine(
        provider: "telekom",
        username: "+49123",
        password: "secret",
        domain: nil,
        outboundProxy: "sip:edge.example.test",
        stunServer: nil,
        mediaEncryption: nil,
        label: " Home ",
        sipDisplayName: "Arne",
        outboundCallerID: "+49 123"
    ))

    #expect(created.provider == .telekom)
    #expect(created.domain == "tel.t-online.de")
    #expect(created.outboundProxy == "sip:edge.example.test")
    #expect(created.stunServer == "stun:stun.t-online.de")
    #expect(created.mediaEncryption == "srtp-mand")
    #expect(created.label == "Home")
    #expect(created.outboundCallerID == "+49123")
    try created.validate(password: "secret")

    let updated = try managedSIPAccount(
        applying: ControlUpdateLine(
            line: "Home",
            provider: "easybell",
            password: nil,
            domain: "registrar.example.test",
            outboundProxy: nil,
            stunServer: nil,
            mediaEncryption: nil,
            label: "",
            sipDisplayName: nil,
            outboundCallerID: nil
        ),
        to: created
    )
    #expect(updated.provider == .easybell)
    #expect(updated.domain == "registrar.example.test")
    #expect(updated.outboundProxy.isEmpty)
    #expect(updated.stunServer.isEmpty)
    #expect(updated.mediaEncryption.isEmpty)
    #expect(updated.label == nil)
}

@Test func linePayloadReportsRegistrationWithoutCredentials() throws {
    let account = provisioningTestAccount()
    let payload = controlLinePayload(
        for: account,
        status: .failed(#"Forbidden auth_pass="super-secret""#),
        activeSIPAddress: account.sipAddress,
        assistantProfileDisplay: "Personal"
    )
    guard case .object(let object) = payload else {
        Issue.record("Expected a line object")
        return
    }

    #expect(object["provider"] == .string("custom"))
    #expect(object["registered"] == .bool(false))
    #expect(object["registration"] == .string("failed"))
    #expect(object["last_error"] == .string("Forbidden auth_pass=••••"))
    #expect(object["is_outgoing_line"] == .bool(true))

    let encoded = String(decoding: try JSONEncoder().encode(payload), as: UTF8.self)
    #expect(!encoded.contains("super-secret"))
    #expect(!encoded.contains("password"))
}

@Test func createLineMCPResponseNeverEchoesItsPassword() throws {
    let password = "mcp-only-super-secret"
    let request = Data(#"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"create_line","arguments":{"provider":"custom","username":"agent","password":"mcp-only-super-secret","domain":"sip.example.test"}}}"#.utf8)
    let account = provisioningTestAccount()
    let response = try #require(MCPProtocol.response(for: request) { name, arguments in
        #expect(name == "create_line")
        #expect(arguments["password"] == .string(password))
        return .success(controlLinePayload(
            for: account,
            status: .failed("Provider reflected \(password) unexpectedly"),
            activeSIPAddress: account.sipAddress,
            assistantProfileDisplay: "Personal",
            sensitiveValues: [password]
        ))
    })
    let text = String(decoding: response, as: UTF8.self)

    #expect(!text.contains(password))
    #expect(!text.contains("\"password\""))
    #expect(text.contains("last_error"))
    #expect(text.contains("••••"))
}

@Test func everySIPAccountErrorHasASpecificControlMapping() {
    let cases: [(SIPAccountError, String)] = [
        (.accountOffline, "line_offline"),
        (.activeCall, "active_call"),
        (.duplicateAccount, "duplicate_line"),
        (.invalidOutboundCallerID, "invalid_outbound_caller_id"),
        (.invalidProviderSettings, "invalid_provider_settings"),
        (.invalidUsername, "invalid_username"),
        (.invalidPassword, "invalid_password"),
        (.keychain(-25293), "keychain_error"),
        (.lineBusy, "line_busy"),
        (.missingDomain, "missing_domain"),
        (.missingManagedAccount, "missing_managed_account"),
        (.missingPassword, "missing_password"),
        (.missingSavedAssistantProfile, "missing_assistant_profile"),
        (.missingStoredPassword, "missing_stored_password"),
        (.missingUsername, "missing_username")
    ]

    for (error, expectedCode) in cases {
        let mapped = controlError(for: error)
        #expect(mapped.code == expectedCode)
        #expect(!mapped.message.isEmpty)
    }
}

@Test func linePromptBecomesAnIndependentCustomOverride() {
    let saved = SavedAssistantProfile(name: "Old shared profile", instructions: "Old prompt")
    let original = provisioningTestAccount(profile: .custom, savedProfileID: saved.id)
    let updated = accountSettingCustomPrompt(
        original,
        instructions: " Answer as the local support desk. ",
        contextData: " Customer tier: gold "
    )
    let resolved = resolveAssistantProfile(
        accounts: [updated],
        savedProfiles: [saved],
        calledAOR: updated.sipAddress,
        activeSIPAddress: nil,
        globalInstructions: "Global"
    )

    #expect(updated.assistantProfile == .custom)
    #expect(updated.savedProfileID == nil)
    #expect(updated.assistantProfileName == nil)
    #expect(updated.assistantInstructionsOverride == "Answer as the local support desk.")
    #expect(updated.assistantContextData == "Customer tier: gold")
    #expect(resolved.instructions == "Answer as the local support desk.")
    #expect(resolved.contextData == "Customer tier: gold")
}

@Test func answerModeClampsAndRoundTripsThroughTheControlPayload() throws {
    let updated = accountSettingAnswerMode(
        provisioningTestAccount(),
        mode: .outsideBusinessHours,
        answerDelaySeconds: 45
    )
    let decoded = try JSONDecoder().decode(
        ManagedSIPAccount.self,
        from: JSONEncoder().encode(updated)
    )
    guard case .object(let payload) = controlAssistantConfigurationPayload(for: decoded, savedProfile: nil) else {
        Issue.record("Expected assistant configuration object")
        return
    }

    #expect(decoded.assistantAnswerMode == .outsideBusinessHours)
    #expect(decoded.assistantAnswerDelay == 30)
    #expect(payload["answer_mode"] == .string("outside_business_hours"))
    #expect(payload["answer_delay_seconds"] == .integer(30))
}

@Test func businessHoursRoundTripThroughTheModelAndControlPayload() throws {
    let updated = accountSettingBusinessHours(
        provisioningTestAccount(),
        weekdays: .init(open: true, startMinute: 8 * 60 + 30, endMinute: 18 * 60),
        weekend: .init(open: false, startMinute: 10 * 60, endMinute: 14 * 60)
    )
    let decoded = try JSONDecoder().decode(
        ManagedSIPAccount.self,
        from: JSONEncoder().encode(updated)
    )
    guard case .object(let payload) = controlAssistantConfigurationPayload(for: decoded, savedProfile: nil),
          case .object(let hours) = payload["business_hours"],
          case .object(let weekdays) = hours["weekdays"],
          case .object(let weekend) = hours["weekend"] else {
        Issue.record("Expected nested business-hours payload")
        return
    }

    #expect(decoded.businessHours.weekdays == .init(open: true, start: 510, end: 1080))
    #expect(decoded.businessHours.weekend == .init(open: false, start: 600, end: 840))
    #expect(weekdays["start_minute"] == .integer(510))
    #expect(weekdays["end_minute"] == .integer(1080))
    #expect(weekend["open"] == .bool(false))
}
