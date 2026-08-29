import Foundation
import Testing
@testable import Phone

private struct AccountLineCase: Sendable {
    let account: ManagedSIPAccount
    let expected: String
}

private let accountLineCases = [
    accountCase(
        .telekom,
        expected: #"<sip:user@tel.t-online.de>;auth_pass="secret";regint=300;outbound="sip:tel.t-online.de";stunserver=stun:stun.t-online.de;mediaenc=srtp-mand"# + "\n"
    ),
    accountCase(.fritzBox, expected: #"<sip:user@fritz.box>;auth_pass="secret";regint=300"# + "\n"),
    accountCase(
        .sipgate,
        expected: #"<sip:user@sipgate.de>;auth_pass="secret";regint=300;outbound="sip:proxy.live.sipgate.de""# + "\n"
    ),
    accountCase(.easybell, expected: #"<sip:user@sip.easybell.de>;auth_pass="secret";regint=300"# + "\n"),
    AccountLineCase(
        account: ManagedSIPAccount(
            provider: .custom,
            username: "user",
            domain: "sip.example.com",
            outboundProxy: "",
            stunServer: "",
            mediaEncryption: ""
        ),
        expected: #"<sip:user@sip.example.com>;auth_pass="secret";regint=300"# + "\n"
    )
]

private struct InvalidAccountCase: Sendable {
    let account: ManagedSIPAccount
    let password: String
}

private let invalidAccountCases = [
    invalidAccount(username: ""),
    invalidAccount(domain: ""),
    invalidAccount(password: ""),
    invalidAccount(username: "user;admin"),
    invalidAccount(username: "user\nadmin"),
    invalidAccount(username: "<user>"),
    invalidAccount(username: "user@example.com"),
    invalidAccount(domain: "sip;example.com"),
    invalidAccount(domain: "sip\nexample.com"),
    invalidAccount(domain: "<sip.example.com>"),
    invalidAccount(password: "secret\nvalue")
]

private struct RedactionCase: Sendable {
    let input: String
    let expected: String
}

private let redactionCases = [
    RedactionCase(
        input: #"account auth_pass="pa\"ss\\word";regint=300"#,
        expected: "account auth_pass=••••;regint=300"
    ),
    RedactionCase(input: "auth_pass=secret;regint=300", expected: "auth_pass=••••;regint=300"),
    RedactionCase(
        input: "first line\nauth_pass=\"secret\";one\nlast auth_pass=plain\n",
        expected: "first line\nauth_pass=••••;one\nlast auth_pass=••••\n"
    ),
    RedactionCase(input: "registration failed: Forbidden", expected: "registration failed: Forbidden")
]

@Test(arguments: accountLineCases)
private func generatesProviderAccountLines(testCase: AccountLineCase) throws {
    #expect(try testCase.account.accountLine(password: "secret") == testCase.expected)
}

@Test func quotesManagedAccountPassword() throws {
    let account = accountLineCases[1].account
    let line = try account.accountLine(password: #"pa"ss\word"#)
    #expect(line.contains(#"auth_pass="pa\"ss\\word""#))
}

@Test(arguments: invalidAccountCases)
private func rejectsInvalidManagedAccounts(testCase: InvalidAccountCase) {
    #expect(throws: SIPAccountError.self) {
        try testCase.account.validate(password: testCase.password)
    }
}

@Test(arguments: redactionCases)
private func redactsAuthenticationPasswords(testCase: RedactionCase) {
    #expect(redactSensitiveValues(in: testCase.input) == testCase.expected)
}

@Test func migratesLegacyManagedAccountData() throws {
    let legacyData = try #require(
        #"{"provider":"Deutsche Telekom","username":"+49123","domain":"tel.t-online.de","outboundProxy":"sip:tel.t-online.de","stunServer":"stun:stun.t-online.de","mediaEncryption":"srtp-mand"}"#.data(using: .utf8)
    )

    let result = decodeManagedSIPAccounts(
        accountsData: nil,
        legacyAccountData: legacyData,
        activeSIPAddress: nil
    )

    #expect(result.migratedLegacyAccount)
    #expect(result.state.accounts.count == 1)
    #expect(result.state.activeAccount?.sipAddress == "+49123@tel.t-online.de")
    #expect(result.state.activeAccount?.label == nil)
    #expect(result.state.activeAccount?.assistantProfile == .personalAssistant)
    #expect(result.state.activeAccount?.assistantInstructionsOverride == nil)
    #expect(result.state.activeAccount?.assistantContextData == nil)
    #expect(result.state.activeAccount?.outboundCallerID == nil)
}

@Test func outboundCallerIDEncodeDecodeRoundTripNormalizesSpaces() throws {
    let account = ManagedSIPAccount(
        provider: .sipgate,
        username: "user",
        domain: "sipgate.de",
        outboundProxy: "sip:proxy.live.sipgate.de",
        stunServer: "",
        mediaEncryption: "",
        label: "Mobile identity",
        outboundCallerID: "+49 170 1234567",
        assistantContextData: "Custom data"
    )

    let data = try JSONEncoder().encode(account)
    let decoded = try JSONDecoder().decode(ManagedSIPAccount.self, from: data)

    #expect(decoded == account)
    #expect(decoded.outboundCallerID == "+491701234567")
}

@Test func ordersActiveAccountFirstAndWritesEveryAccount() throws {
    let first = ManagedSIPAccount(
        provider: .custom,
        username: "first",
        domain: "example.com",
        outboundProxy: "",
        stunServer: "",
        mediaEncryption: ""
    )
    let active = ManagedSIPAccount(
        provider: .custom,
        username: "active",
        domain: "example.net",
        outboundProxy: "",
        stunServer: "",
        mediaEncryption: ""
    )
    let third = ManagedSIPAccount(
        provider: .custom,
        username: "third",
        domain: "example.org",
        outboundProxy: "",
        stunServer: "",
        mediaEncryption: ""
    )
    let accounts = [first, active, third]
    let ordered = orderedManagedAccounts(accounts, activeSIPAddress: active.sipAddress)
    let content = try managedAccountsFileContent(
        accounts: accounts,
        activeSIPAddress: active.sipAddress,
        passwordFor: { "password-for-\($0.username)" }
    )
    let lines = content.split(separator: "\n").map(String.init)

    #expect(ordered.map(\.sipAddress) == [active.sipAddress, first.sipAddress, third.sipAddress])
    #expect(lines.count == 3)
    #expect(lines[0].hasPrefix("<sip:\(active.sipAddress)>") )
    #expect(lines[1].hasPrefix("<sip:\(first.sipAddress)>") )
    #expect(lines[2].hasPrefix("<sip:\(third.sipAddress)>") )
    #expect(content.contains("password-for-active"))
    #expect(content.contains("password-for-first"))
    #expect(content.contains("password-for-third"))
}

@Test func maintainsOneActiveManagedAccount() {
    let privateAccount = accountCase(.telekom, expected: "").account
    let workAccount = ManagedSIPAccount(
        provider: .sipgate,
        username: "work",
        domain: "sipgate.de",
        outboundProxy: "",
        stunServer: "",
        mediaEncryption: "",
        label: "Work"
    )
    var state = ManagedSIPAccountsState(
        accounts: [privateAccount, workAccount, privateAccount],
        activeSIPAddress: "missing@example.com"
    )

    #expect(state.accounts.count == 2)
    #expect(activeCount(in: state) == 1)
    state.select(workAccount)
    #expect(state.activeAccount == workAccount)
    #expect(activeCount(in: state) == 1)
    state.remove(workAccount)
    #expect(state.activeAccount == privateAccount)
    #expect(activeCount(in: state) == 1)
    state.remove(privateAccount)
    #expect(state.activeAccount == nil)
    #expect(activeCount(in: state) == 0)
}

@Test func accountLineIncludesQuotedDisplayName() throws {
    let account = ManagedSIPAccount(
        provider: .custom,
        username: "user",
        domain: "example.test",
        outboundProxy: "",
        stunServer: "",
        mediaEncryption: "",
        sipDisplayName: #"Support "Desk""#
    )

    #expect(
        try account.accountLine(password: "secret")
            == #""Support \"Desk\"" <sip:user@example.test>;auth_pass="secret";regint=300"# + "\n"
    )
}

@Test func accountLineUsesNormalizedOutboundCallerIDAsDisplayName() throws {
    let account = ManagedSIPAccount(
        provider: .sipgate,
        username: "user",
        domain: "sipgate.de",
        outboundProxy: "sip:proxy.live.sipgate.de",
        stunServer: "",
        mediaEncryption: "",
        sipDisplayName: "Support Desk",
        outboundCallerID: "+49 170 1234567"
    )

    #expect(
        try account.accountLine(password: "secret")
            == #""+491701234567" <sip:user@sipgate.de>;auth_pass="secret";regint=300;outbound="sip:proxy.live.sipgate.de""# + "\n"
    )
}

@Test func accountLineHasNoCallerIDDisplayNameWhenUnset() throws {
    let account = ManagedSIPAccount(
        provider: .custom,
        username: "user",
        domain: "example.test",
        outboundProxy: "",
        stunServer: "",
        mediaEncryption: ""
    )

    #expect(
        try account.accountLine(password: "secret")
            == #"<sip:user@example.test>;auth_pass="secret";regint=300"# + "\n"
    )
}

@Test(arguments: ["+", "+49-170", "0049 (170)", "+49\t170", "caller"])
private func rejectsInvalidOutboundCallerIDs(value: String) {
    var account = accountCase(.sipgate, expected: "").account
    account.outboundCallerID = value

    #expect(throws: SIPAccountError.self) {
        try account.validate(password: "secret")
    }
}

@Test func sipgatePresetIncludesOutboundProxy() {
    #expect(SIPProviderPreset.sipgate.defaults.outboundProxy == "sip:proxy.live.sipgate.de")
}

@Test func editReplacesAccountInPlaceAndKeepsProfileSettings() throws {
    let original = ManagedSIPAccount(
        provider: .custom,
        username: "old-user",
        domain: "example.test",
        outboundProxy: "",
        stunServer: "",
        mediaEncryption: "",
        label: "Work",
        assistantProfile: .custom,
        assistantInstructionsOverride: "Custom instructions",
        assistantContextData: "Custom data"
    )
    var updated = original
    updated.username = "new-user"
    updated.outboundProxy = "sip:proxy.example.test"
    var state = ManagedSIPAccountsState(accounts: [original], activeSIPAddress: original.sipAddress)

    try state.replace(accountAt: original.sipAddress, with: updated)

    #expect(state.accounts == [updated])
    #expect(state.activeSIPAddress == updated.sipAddress)
    #expect(state.activeAccount?.assistantProfile == .custom)
    #expect(state.activeAccount?.assistantInstructionsOverride == "Custom instructions")
    #expect(state.activeAccount?.assistantContextData == "Custom data")
}

@Test func editKeepsOrReplacesPasswordAtSameAddress() throws {
    let address = "user@example.test"

    #expect(
        try managedSIPPasswordEdit(
            originalSIPAddress: address,
            updatedSIPAddress: address,
            replacementPassword: "",
            storedPassword: "stored-secret"
        ) == .keep(account: address)
    )
    #expect(
        try managedSIPPasswordEdit(
            originalSIPAddress: address,
            updatedSIPAddress: address,
            replacementPassword: "replacement-secret",
            storedPassword: nil
        ) == .save(password: "replacement-secret", account: address)
    )
}

@Test func addressChangeMovesStoredOrReplacementPassword() throws {
    let oldAddress = "old-user@example.test"
    let newAddress = "new-user@example.test"

    #expect(
        try managedSIPPasswordEdit(
            originalSIPAddress: oldAddress,
            updatedSIPAddress: newAddress,
            replacementPassword: "",
            storedPassword: "stored-secret"
        ) == .move(password: "stored-secret", from: oldAddress, to: newAddress)
    )
    #expect(
        try managedSIPPasswordEdit(
            originalSIPAddress: oldAddress,
            updatedSIPAddress: newAddress,
            replacementPassword: "replacement-secret",
            storedPassword: nil
        ) == .move(password: "replacement-secret", from: oldAddress, to: newAddress)
    )
}

private struct AccountFieldClassificationCase: Sendable {
    let field: ManagedSIPAccountField
    let isRegistrationRelevant: Bool
}

private let accountFieldClassificationCases = [
    AccountFieldClassificationCase(field: .provider, isRegistrationRelevant: false),
    AccountFieldClassificationCase(field: .username, isRegistrationRelevant: true),
    AccountFieldClassificationCase(field: .domain, isRegistrationRelevant: true),
    AccountFieldClassificationCase(field: .password, isRegistrationRelevant: true),
    AccountFieldClassificationCase(field: .outboundProxy, isRegistrationRelevant: true),
    AccountFieldClassificationCase(field: .stunServer, isRegistrationRelevant: true),
    AccountFieldClassificationCase(field: .mediaEncryption, isRegistrationRelevant: true),
    AccountFieldClassificationCase(field: .label, isRegistrationRelevant: false),
    AccountFieldClassificationCase(field: .sipDisplayName, isRegistrationRelevant: true),
    AccountFieldClassificationCase(field: .outboundCallerID, isRegistrationRelevant: true),
    AccountFieldClassificationCase(field: .assistantProfile, isRegistrationRelevant: false),
    AccountFieldClassificationCase(field: .assistantProfileName, isRegistrationRelevant: false),
    AccountFieldClassificationCase(field: .savedProfileID, isRegistrationRelevant: false),
    AccountFieldClassificationCase(field: .assistantInstructionsOverride, isRegistrationRelevant: false),
    AccountFieldClassificationCase(field: .assistantContextData, isRegistrationRelevant: false)
]

@Test(arguments: accountFieldClassificationCases)
private func classifiesManagedAccountFields(testCase: AccountFieldClassificationCase) {
    #expect(testCase.field.isRegistrationRelevant == testCase.isRegistrationRelevant)
}

@Test func classificationCoversEveryManagedAccountField() {
    #expect(Set(accountFieldClassificationCases.map(\.field)) == Set(ManagedSIPAccountField.allCases))
}

@Test func metadataOnlyEditRequiresNoRestartOrRegistrationTest() {
    let original = editableAccount()
    var updated = original
    updated.label = "Front desk"
    updated.assistantProfile = .custom
    updated.assistantInstructionsOverride = "Answer briefly"
    updated.assistantContextData = "Hours: 09:00–17:00"

    let plan = managedSIPAccountEditPlan(
        original: original,
        updated: updated,
        replacementPassword: ""
    )

    #expect(
        plan.changedFields == [
            .label,
            .assistantProfile,
            .assistantInstructionsOverride,
            .assistantContextData
        ]
    )
    #expect(!plan.requiresEngineRestart)
    #expect(!plan.requiresRegistrationTest)
}

@Test func displayNameOnlyEditRestartsWithoutRegistrationTest() {
    let original = editableAccount()
    var updated = original
    updated.sipDisplayName = "Support Desk"

    let plan = managedSIPAccountEditPlan(
        original: original,
        updated: updated,
        replacementPassword: ""
    )

    #expect(plan.changedFields == [.sipDisplayName])
    #expect(plan.requiresEngineRestart)
    #expect(!plan.requiresRegistrationTest)
}

@Test func outboundCallerIDOnlyEditRestartsWithoutRegistrationTest() {
    let original = editableAccount()
    var updated = original
    updated.outboundCallerID = "+491701234567"

    let plan = managedSIPAccountEditPlan(
        original: original,
        updated: updated,
        replacementPassword: ""
    )

    #expect(plan.changedFields == [.outboundCallerID])
    #expect(plan.requiresEngineRestart)
    #expect(!plan.requiresRegistrationTest)
}

@Test func accountLineOrPasswordEditRestartsWithRegistrationTest() {
    let original = editableAccount()
    var updated = original
    updated.outboundProxy = "sip:new-proxy.example.test"

    let accountLinePlan = managedSIPAccountEditPlan(
        original: original,
        updated: updated,
        replacementPassword: ""
    )
    let passwordPlan = managedSIPAccountEditPlan(
        original: original,
        updated: original,
        replacementPassword: "new-secret"
    )

    #expect(accountLinePlan.requiresEngineRestart)
    #expect(accountLinePlan.requiresRegistrationTest)
    #expect(passwordPlan.changedFields == [.password])
    #expect(passwordPlan.requiresEngineRestart)
    #expect(passwordPlan.requiresRegistrationTest)
}

private func editableAccount() -> ManagedSIPAccount {
    ManagedSIPAccount(
        provider: .custom,
        username: "user",
        domain: "example.test",
        outboundProxy: "",
        stunServer: "",
        mediaEncryption: "",
        label: "Office",
        assistantProfile: .personalAssistant
    )
}

private func accountCase(_ provider: SIPProviderPreset, expected: String) -> AccountLineCase {
    let defaults = provider.defaults
    return AccountLineCase(
        account: ManagedSIPAccount(
            provider: provider,
            username: "user",
            domain: defaults.domain,
            outboundProxy: defaults.outboundProxy,
            stunServer: defaults.stunServer,
            mediaEncryption: defaults.mediaEncryption
        ),
        expected: expected
    )
}

private func invalidAccount(
    username: String = "user",
    domain: String = "sip.example.com",
    password: String = "secret"
) -> InvalidAccountCase {
    InvalidAccountCase(
        account: ManagedSIPAccount(
            provider: .custom,
            username: username,
            domain: domain,
            outboundProxy: "",
            stunServer: "",
            mediaEncryption: ""
        ),
        password: password
    )
}

private func activeCount(in state: ManagedSIPAccountsState) -> Int {
    state.accounts.count { $0.sipAddress == state.activeSIPAddress }
}
