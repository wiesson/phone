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
    accountCase(.sipgate, expected: #"<sip:user@sipgate.de>;auth_pass="secret";regint=300"# + "\n"),
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
