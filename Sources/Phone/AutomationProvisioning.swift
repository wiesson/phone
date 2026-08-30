import Foundation
import PhoneAutomation

extension SIPProviderPreset {
    var controlIdentifier: String {
        switch self {
        case .telekom: "telekom"
        case .fritzBox: "fritzBox"
        case .sipgate: "sipgate"
        case .easybell: "easybell"
        case .custom: "custom"
        }
    }

    init?(controlIdentifier: String) {
        switch controlIdentifier {
        case "telekom": self = .telekom
        case "fritzBox": self = .fritzBox
        case "sipgate": self = .sipgate
        case "easybell": self = .easybell
        case "custom": self = .custom
        default: return nil
        }
    }
}

func managedSIPAccount(from arguments: ControlCreateLine) throws -> ManagedSIPAccount {
    let provider: SIPProviderPreset
    if let identifier = arguments.provider {
        guard let match = SIPProviderPreset(controlIdentifier: identifier) else {
            throw SIPAccountError.invalidProviderSettings
        }
        provider = match
    } else {
        provider = .custom
    }
    let defaults = provider.defaults
    return ManagedSIPAccount(
        provider: provider,
        username: arguments.username.trimmingCharacters(in: .whitespacesAndNewlines),
        domain: arguments.domain ?? defaults.domain,
        outboundProxy: arguments.outboundProxy ?? defaults.outboundProxy,
        stunServer: arguments.stunServer ?? defaults.stunServer,
        mediaEncryption: arguments.mediaEncryption ?? defaults.mediaEncryption,
        label: normalizedOptionalText(arguments.label),
        sipDisplayName: normalizedOptionalText(arguments.sipDisplayName),
        outboundCallerID: normalizedOptionalText(arguments.outboundCallerID)
    )
}

func managedSIPAccount(
    applying arguments: ControlUpdateLine,
    to original: ManagedSIPAccount
) throws -> ManagedSIPAccount {
    var updated = original
    if let identifier = arguments.provider {
        guard let provider = SIPProviderPreset(controlIdentifier: identifier) else {
            throw SIPAccountError.invalidProviderSettings
        }
        updated.provider = provider
        let defaults = provider.defaults
        updated.domain = defaults.domain
        updated.outboundProxy = defaults.outboundProxy
        updated.stunServer = defaults.stunServer
        updated.mediaEncryption = defaults.mediaEncryption
    }
    if let domain = arguments.domain { updated.domain = domain }
    if let outboundProxy = arguments.outboundProxy { updated.outboundProxy = outboundProxy }
    if let stunServer = arguments.stunServer { updated.stunServer = stunServer }
    if let mediaEncryption = arguments.mediaEncryption { updated.mediaEncryption = mediaEncryption }
    if let label = arguments.label { updated.label = normalizedOptionalText(label) }
    if let sipDisplayName = arguments.sipDisplayName {
        updated.sipDisplayName = normalizedOptionalText(sipDisplayName)
    }
    if let outboundCallerID = arguments.outboundCallerID {
        updated.outboundCallerID = normalizedOptionalText(outboundCallerID)?
            .replacingOccurrences(of: " ", with: "")
    }
    return updated
}

func accountSettingCustomPrompt(
    _ account: ManagedSIPAccount,
    instructions: String,
    contextData: String?
) -> ManagedSIPAccount {
    var updated = account
    updated.assistantProfile = .custom
    updated.assistantProfileName = nil
    updated.savedProfileID = nil
    updated.assistantInstructionsOverride = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
    updated.assistantContextData = normalizedOptionalText(contextData)
    return updated
}

func accountSettingAnswerMode(
    _ account: ManagedSIPAccount,
    mode: ControlAssistantAnswerMode,
    answerDelaySeconds: Int?
) -> ManagedSIPAccount {
    var updated = account
    switch mode {
    case .never: updated.assistantAnswerMode = .never
    case .always: updated.assistantAnswerMode = .always
    case .outsideBusinessHours: updated.assistantAnswerMode = .outsideBusinessHours
    }
    if let answerDelaySeconds {
        updated.assistantAnswerDelay = ManagedSIPAccount.clampedAnswerDelay(answerDelaySeconds)
    }
    return updated
}

func accountSettingBusinessHours(
    _ account: ManagedSIPAccount,
    weekdays: ControlBusinessHoursDayGroup,
    weekend: ControlBusinessHoursDayGroup
) -> ManagedSIPAccount {
    var updated = account
    updated.businessHours = BusinessHoursSchedule(
        weekdays: .init(open: weekdays.open, start: weekdays.startMinute, end: weekdays.endMinute),
        weekend: .init(open: weekend.open, start: weekend.startMinute, end: weekend.endMinute)
    )
    return updated
}

func controlError(for error: SIPAccountError) -> ControlError {
    let code: String
    switch error {
    case .accountOffline: code = "line_offline"
    case .activeCall: code = "active_call"
    case .duplicateAccount: code = "duplicate_line"
    case .invalidOutboundCallerID: code = "invalid_outbound_caller_id"
    case .invalidProviderSettings: code = "invalid_provider_settings"
    case .invalidUsername: code = "invalid_username"
    case .invalidPassword: code = "invalid_password"
    case .keychain: code = "keychain_error"
    case .lineBusy: code = "line_busy"
    case .missingDomain: code = "missing_domain"
    case .missingManagedAccount: code = "missing_managed_account"
    case .missingPassword: code = "missing_password"
    case .missingSavedAssistantProfile: code = "missing_assistant_profile"
    case .missingStoredPassword: code = "missing_stored_password"
    case .missingUsername: code = "missing_username"
    }
    return ControlError(code: code, message: error.localizedDescription)
}

func controlError(for error: Error, fallbackCode: String = "invalid_state") -> ControlError {
    if let accountError = error as? SIPAccountError { return controlError(for: accountError) }
    return ControlError(code: fallbackCode, message: error.localizedDescription)
}

func controlRegistrationPayload(
    for account: ManagedSIPAccount,
    status: RegistrationStatus,
    sensitiveValues: [String] = []
) -> JSONValue {
    let state: String
    let registered: Bool
    let lastError: JSONValue
    if !account.isEnabled {
        state = "offline"
        registered = false
        lastError = .null
    } else {
        switch status {
        case .registered:
            state = "registered"
            registered = true
            lastError = .null
        case .registering:
            state = "registering"
            registered = false
            lastError = .null
        case .failed(let message):
            state = "failed"
            registered = false
            lastError = .string(redactedControlMessage(message, sensitiveValues: sensitiveValues))
        case .idle:
            state = "idle"
            registered = false
            lastError = .null
        }
    }
    return .object([
        "line": .string(account.displayName),
        "sip_address": .string(account.sipAddress),
        "enabled": .bool(account.isEnabled),
        "registered": .bool(registered),
        "registration": .string(state),
        "last_error": lastError
    ])
}

func controlLinePayload(
    for account: ManagedSIPAccount,
    status: RegistrationStatus,
    activeSIPAddress: String?,
    assistantProfileDisplay: String,
    sensitiveValues: [String] = []
) -> JSONValue {
    guard case .object(var payload) = controlRegistrationPayload(
        for: account,
        status: status,
        sensitiveValues: sensitiveValues
    ) else {
        return .object([:])
    }
    payload.merge([
        "provider": .string(account.provider.controlIdentifier),
        "domain": .string(account.domain),
        "outbound_proxy": .string(account.outboundProxy),
        "stun_server": .string(account.stunServer),
        "media_encryption": .string(account.mediaEncryption),
        "sip_display_name": account.sipDisplayName.map(JSONValue.string) ?? .null,
        "outbound_caller_id": account.outboundCallerID.map(JSONValue.string) ?? .null,
        "assistant_profile": .string(assistantProfileDisplay),
        "answer_mode": .string(controlAnswerMode(account.assistantAnswerMode)),
        "answers_incoming": .string(account.assistantAnswerMode.rawValue),
        "answer_delay_seconds": .integer(account.assistantAnswerDelay),
        "business_hours": controlBusinessHoursPayload(account.businessHours),
        "is_outgoing_line": .bool(account.sipAddress == activeSIPAddress)
    ], uniquingKeysWith: { _, new in new })
    return .object(payload)
}

func controlAssistantConfigurationPayload(
    for account: ManagedSIPAccount,
    savedProfile: SavedAssistantProfile?
) -> JSONValue {
    .object([
        "line": .string(account.displayName),
        "sip_address": .string(account.sipAddress),
        "profile": .string(savedProfile?.name ?? account.assistantProfileDisplay),
        "saved_profile_id": account.savedProfileID.map { .string($0.uuidString) } ?? .null,
        "instructions": .string(savedProfile?.instructions ?? account.assistantInstructionsOverride ?? ""),
        "context_data": (savedProfile?.contextData ?? account.assistantContextData).map(JSONValue.string) ?? .null,
        "answer_mode": .string(controlAnswerMode(account.assistantAnswerMode)),
        "answer_delay_seconds": .integer(account.assistantAnswerDelay),
        "business_hours": controlBusinessHoursPayload(account.businessHours)
    ])
}

func controlAssistantProfilePayload(_ profile: SavedAssistantProfile) -> JSONValue {
    .object([
        "profile_id": .string(profile.id.uuidString),
        "name": .string(profile.name),
        "instructions": .string(profile.instructions),
        "context_data": profile.contextData.map(JSONValue.string) ?? .null
    ])
}

private func controlAnswerMode(_ mode: AssistantAnswerMode) -> String {
    switch mode {
    case .never: "never"
    case .always: "always"
    case .outsideBusinessHours: "outside_business_hours"
    }
}

private func controlBusinessHoursPayload(_ schedule: BusinessHoursSchedule) -> JSONValue {
    func dayGroup(_ group: BusinessHoursSchedule.DayGroup) -> JSONValue {
        .object([
            "open": .bool(group.open),
            "start_minute": .integer(group.start),
            "end_minute": .integer(group.end)
        ])
    }
    return .object([
        "weekdays": dayGroup(schedule.weekdays),
        "weekend": dayGroup(schedule.weekend)
    ])
}

private func normalizedOptionalText(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

private func redactedControlMessage(_ message: String, sensitiveValues: [String]) -> String {
    sensitiveValues.reduce(redactSensitiveValues(in: message)) { result, value in
        value.isEmpty ? result : result.replacingOccurrences(of: value, with: "••••")
    }
}
