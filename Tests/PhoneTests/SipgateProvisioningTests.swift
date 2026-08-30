import Foundation
import PhoneAutomation
import Testing
@testable import Phone

private actor FakeSipgateClient: SipgateClientProtocol {
    enum Call: Equatable, Sendable {
        case authenticatedUser
        case listDevices(String)
        case createDevice(String, String?)
        case rotatePassword(String)
        case deviceDetails(String)
    }

    let userID: String
    let devices: [SipgateDevice]
    let createdDevice: SipgateDevice
    let detailsByID: [String: SipgateDeviceDetails]
    let missingDeviceIDs: Set<String>
    private var calls: [Call] = []

    init(
        userID: String = "w0",
        devices: [SipgateDevice] = [],
        createdDevice: SipgateDevice = SipgateDevice(
            id: "e-new",
            alias: "Phone Mac",
            online: false,
            type: "REGISTER"
        ),
        detailsByID: [String: SipgateDeviceDetails] = [:],
        missingDeviceIDs: Set<String> = []
    ) {
        self.userID = userID
        self.devices = devices
        self.createdDevice = createdDevice
        self.detailsByID = detailsByID
        self.missingDeviceIDs = missingDeviceIDs
    }

    func authenticatedUserID() async throws -> String {
        calls.append(.authenticatedUser)
        return userID
    }

    func listRegisterDevices(userID: String) async throws -> [SipgateDevice] {
        calls.append(.listDevices(userID))
        return devices
    }

    func createRegisterDevice(userID: String, alias: String?) async throws -> SipgateDevice {
        calls.append(.createDevice(userID, alias))
        return createdDevice
    }

    func deviceDetails(deviceID: String) async throws -> SipgateDeviceDetails {
        calls.append(.deviceDetails(deviceID))
        if missingDeviceIDs.contains(deviceID) {
            throw SipgateProvisioningError.requestDenied(status: 404, message: nil)
        }
        guard let details = detailsByID[deviceID] else {
            throw SipgateProvisioningError.invalidResponse("fake device")
        }
        return details
    }

    func rotatePassword(deviceID: String) async throws {
        calls.append(.rotatePassword(deviceID))
    }

    func recordedCalls() -> [Call] { calls }
}

private func registerDevice(
    id: String = "e0",
    alias: String = "Desk phone",
    online: Bool = false
) -> SipgateDevice {
    SipgateDevice(id: id, alias: alias, online: online, type: "REGISTER")
}

private func registerDetails(
    device: SipgateDevice,
    username: String? = "sip-user",
    password: String? = "sip-password",
    sipServer: String? = "sipgate.de",
    outboundProxy: String? = "sip:proxy.live.sipgate.de"
) -> SipgateDeviceDetails {
    SipgateDeviceDetails(
        device: device,
        credentials: SipgateDeviceCredentials(
            username: username,
            password: password,
            sipServer: sipServer,
            outboundProxy: outboundProxy
        )
    )
}

@Test func sipgateCredentialStatusRevealsOnlyPresenceAndTokenIDLength() throws {
    let tokenID = "pat-id-must-stay-secret"
    let token = "pat-must-stay-secret"
    let status = sipgateCredentialsStatus(tokenID: tokenID, token: token)
    let response = ControlResponse.success(controlSipgateCredentialsStatusPayload(status))
    let encoded = String(decoding: try response.jsonData(), as: UTF8.self)

    #expect(status == SipgateCredentialsStatus(configured: true, tokenIDLength: tokenID.count))
    #expect(encoded.contains("\"configured\":true"))
    #expect(encoded.contains("\"token_id_length\":\(tokenID.count)"))
    #expect(!encoded.contains(tokenID))
    #expect(!encoded.contains(token))

    #expect(sipgateCredentialsStatus(tokenID: tokenID, token: nil) == SipgateCredentialsStatus(
        configured: false,
        tokenIDLength: tokenID.count
    ))
}

@Test func listsOnlyRegisterDeviceMetadataThroughAnInjectedClient() async throws {
    let pat = "pat-must-not-escape-list"
    let register = registerDevice(alias: "Desk phone \(pat)", online: true)
    let mobile = SipgateDevice(id: "y0", alias: "Mobile", online: true, type: "MOBILE")
    let fake = FakeSipgateClient(devices: [register, mobile])

    let devices = try await SipgateProvisioningService(client: fake).listDevices()
    let payload = controlSipgateDevicesPayload(devices, sensitiveValues: [pat])
    let encoded = String(decoding: try JSONEncoder().encode(payload), as: UTF8.self)
    let calls = await fake.recordedCalls()

    #expect(devices == [register])
    #expect(calls == [.authenticatedUser, .listDevices("w0")])
    #expect(encoded.contains("Desk phone"))
    #expect(encoded.contains("••••"))
    #expect(!encoded.contains(pat))
    #expect(!encoded.lowercased().contains("credential"))
    #expect(!encoded.lowercased().contains("password"))
}

@Test func provisionsAnExistingRegisterDeviceWithSipgateDefaults() async throws {
    let device = registerDevice(online: true)
    let password = "internal-sip-secret"
    let fake = FakeSipgateClient(
        devices: [device],
        detailsByID: [device.id: registerDetails(device: device, password: password)]
    )
    let arguments = ControlProvisionFromSipgate(
        deviceID: device.id,
        createDevice: false,
        alias: nil,
        label: "Reception",
        rotatePassword: false
    )

    let plan = try await SipgateProvisioningService(client: fake).provisioningPlan(for: arguments)
    let calls = await fake.recordedCalls()

    #expect(plan.password == password)
    #expect(plan.device == device)
    #expect(plan.account.provider == .sipgate)
    #expect(plan.account.username == "sip-user")
    #expect(plan.account.domain == "sipgate.de")
    #expect(plan.account.outboundProxy == "sip:proxy.live.sipgate.de")
    #expect(plan.account.label == "Reception")
    #expect(calls == [.authenticatedUser, .listDevices("w0"), .deviceDetails(device.id)])
}

@Test func createsThenRotatesBeforeReadingSipgateCredentials() async throws {
    let created = registerDevice(id: "e-new", alias: "Phone Mac")
    let current = registerDevice(id: created.id, alias: created.alias, online: true)
    let fake = FakeSipgateClient(
        createdDevice: created,
        detailsByID: [created.id: registerDetails(device: current, password: "rotated-secret")]
    )
    let arguments = ControlProvisionFromSipgate(
        deviceID: nil,
        createDevice: true,
        alias: " Phone Mac ",
        label: nil,
        rotatePassword: true
    )

    let plan = try await SipgateProvisioningService(client: fake).provisioningPlan(for: arguments)
    let calls = await fake.recordedCalls()

    #expect(plan.password == "rotated-secret")
    #expect(plan.device.online)
    #expect(calls == [
        .authenticatedUser,
        .createDevice("w0", "Phone Mac"),
        .rotatePassword(created.id),
        .deviceDetails(created.id)
    ])
}

@Test func sipgateProvisioningResponseScrubsTheSIPPasswordEverywhere() async throws {
    let password = "sip-response-must-not-leak"
    let device = registerDevice(alias: "Desk \(password)")
    let fake = FakeSipgateClient(
        devices: [device],
        detailsByID: [device.id: registerDetails(device: device, password: password)]
    )
    let plan = try await SipgateProvisioningService(client: fake).provisioningPlan(for: .init(
        deviceID: device.id,
        createDevice: false,
        alias: nil,
        label: nil,
        rotatePassword: false
    ))
    let line = controlLinePayload(
        for: plan.account,
        status: .failed("Provider reflected \(password)"),
        activeSIPAddress: plan.account.sipAddress,
        assistantProfileDisplay: "Personal",
        sensitiveValues: [password]
    )
    let payload = controlSipgateProvisioningPayload(
        linePayload: line,
        device: plan.device,
        sensitiveValues: [password]
    )
    let request = Data(#"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"provision_from_sipgate","arguments":{"device_id":"e0"}}}"#.utf8)
    let response = try #require(MCPProtocol.response(for: request) { _, _ in .success(payload) })
    let encoded = String(decoding: response, as: UTF8.self)

    #expect(!encoded.contains(password))
    #expect(!encoded.lowercased().contains("password"))
    #expect(encoded.contains("••••"))
    #expect(encoded.contains("sipgate_device_id"))
    #expect(encoded.contains("sipgate_device_alias"))
}

@Test func incompleteSipgateCredentialErrorNeverContainsTheReturnedPassword() async throws {
    let password = "partial-response-secret"
    let device = registerDevice()
    let fake = FakeSipgateClient(
        devices: [device],
        detailsByID: [device.id: registerDetails(device: device, username: nil, password: password)]
    )
    do {
        _ = try await SipgateProvisioningService(client: fake).provisioningPlan(for: .init(
            deviceID: device.id,
            createDevice: false,
            alias: nil,
            label: nil,
            rotatePassword: false
        ))
        Issue.record("Expected incomplete credentials to fail")
    } catch {
        let response = ControlResponse.failure(controlError(for: error))
        let encoded = String(decoding: try response.jsonData(), as: UTF8.self)
        #expect(response.error?.code == "sipgate_device_credentials_missing")
        #expect(!encoded.contains(password))
        #expect(!response.error!.message.lowercased().contains("password"))
    }
}

@Test func provisioningErrorScrubsAReflectedSIPPassword() throws {
    struct ReflectedError: LocalizedError {
        let secret: String
        var errorDescription: String? { "Persistence failed after \(secret)" }
    }
    let password = "error-response-must-not-leak"
    let error = controlError(
        for: ReflectedError(secret: password),
        fallbackCode: "sipgate_provisioning_failed",
        sensitiveValues: [password]
    )
    let encoded = String(decoding: try ControlResponse.failure(error).jsonData(), as: UTF8.self)

    #expect(!encoded.contains(password))
    #expect(error.message.contains("••••"))
}

@Test func distinguishesMissingAndNonRegisterSipgateDevices() async throws {
    let missing = FakeSipgateClient(missingDeviceIDs: ["e404"])
    do {
        _ = try await SipgateProvisioningService(client: missing).provisioningPlan(for: .init(
            deviceID: "e404",
            createDevice: false,
            alias: nil,
            label: nil,
            rotatePassword: false
        ))
        Issue.record("Expected an unknown device to fail")
    } catch let error as SipgateProvisioningError {
        #expect(error == .deviceNotFound("e404"))
        #expect(controlError(for: error).code == "sipgate_device_not_found")
    }

    let mobile = SipgateDevice(id: "y0", alias: "Mobile", online: true, type: "MOBILE")
    let nonRegister = FakeSipgateClient(
        detailsByID: [mobile.id: SipgateDeviceDetails(device: mobile, credentials: nil)]
    )
    do {
        _ = try await SipgateProvisioningService(client: nonRegister).provisioningPlan(for: .init(
            deviceID: mobile.id,
            createDevice: false,
            alias: nil,
            label: nil,
            rotatePassword: false
        ))
        Issue.record("Expected a mobile device to fail")
    } catch let error as SipgateProvisioningError {
        #expect(error == .notRegisterDevice(mobile.id))
        #expect(controlError(for: error).code == "sipgate_device_not_register")
    }
}

@Test func sipgateDenialMessagesAcceptOnlyShortPlainNonSecretText() {
    let tokenID = "secret-token-id"
    let token = "secret-token"
    let sensitive = [tokenID, token]

    #expect(safeSipgateAPIMessage(
        body: Data("This endpoint requires a sipgate Classic PBX Account".utf8),
        contentType: "text/plain; charset=utf-8",
        sensitiveValues: sensitive
    ) == "This endpoint requires a sipgate Classic PBX Account")
    #expect(safeSipgateAPIMessage(
        body: Data("Denied \(token)".utf8),
        contentType: "text/plain",
        sensitiveValues: sensitive
    ) == nil)
    #expect(safeSipgateAPIMessage(
        body: Data(#"{"message":"denied"}"#.utf8),
        contentType: "application/json",
        sensitiveValues: sensitive
    ) == nil)
    #expect(safeSipgateAPIMessage(
        body: Data("Denied: request body".utf8),
        contentType: "text/plain",
        sensitiveValues: sensitive
    ) == nil)
}
