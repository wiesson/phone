import Foundation
import PhoneAutomation
import Security

struct SipgatePATCredentials: Equatable, Sendable {
    let tokenID: String
    let token: String
}

struct SipgateCredentialsStatus: Equatable, Sendable {
    let configured: Bool
    let tokenIDLength: Int
}

enum SipgateCredentialStore {
    static let service = "sipgate-mcp"
    static let tokenIDAccount = "pat-token-id"
    static let tokenAccount = "pat-token"

    static func credentials() -> SipgatePATCredentials? {
        let tokenID = keychainValue(account: tokenIDAccount)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let token = keychainValue(account: tokenAccount)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let tokenID, !tokenID.isEmpty, let token, !token.isEmpty else { return nil }
        return SipgatePATCredentials(tokenID: tokenID, token: token)
    }

    static func status() -> SipgateCredentialsStatus {
        sipgateCredentialsStatus(
            tokenID: keychainValue(account: tokenIDAccount),
            token: keychainValue(account: tokenAccount)
        )
    }

    private static func keychainValue(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else { return nil }
        return value
    }
}

func sipgateCredentialsStatus(tokenID: String?, token: String?) -> SipgateCredentialsStatus {
    let tokenID = tokenID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let token = token?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return SipgateCredentialsStatus(
        configured: !tokenID.isEmpty && !token.isEmpty,
        tokenIDLength: tokenID.count
    )
}

enum SipgateProvisioningError: LocalizedError, Equatable, Sendable {
    case missingPAT
    case invalidArguments
    case invalidResponse(String)
    case networkUnavailable
    case requestDenied(status: Int, message: String?)
    case deviceNotFound(String)
    case notRegisterDevice(String)
    case credentialsMissing
    case rotatedWithoutProvisioning(deviceID: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .rotatedWithoutProvisioning(let deviceID, let reason):
            "The SIP password of sipgate device \(deviceID) was rotated, but the line was not provisioned: \(reason). That device's old password no longer works; provision it again to obtain the new one."
        case .missingPAT:
            "No sipgate PAT is available in Keychain. Run 'sipgate-mcp setup' and try again."
        case .invalidArguments:
            "Give exactly one existing sipgate device ID or request creation of a new register device."
        case .invalidResponse(let subject):
            "sipgate returned an invalid response for \(subject). Try again; if this continues, check the sipgate API status."
        case .networkUnavailable:
            "Could not reach the sipgate API. Check the network connection and try again."
        case .requestDenied(let status, let message):
            if status == 401 {
                "sipgate rejected the PAT (HTTP 401). Run 'sipgate-mcp setup --replace-credentials' and try again."
            } else if status == 429 {
                "sipgate rate-limited the request (HTTP 429). Wait a moment and try again."
            } else if let message {
                "sipgate denied the request (HTTP \(status)). sipgate says: \(message) Check that the PAT includes devices:read and, for creation or rotation, devices:write."
            } else {
                "sipgate denied the request (HTTP \(status)). Check that the PAT includes devices:read and, for creation or rotation, devices:write."
            }
        case .deviceNotFound(let deviceID):
            "No register device named '\(deviceID)' belongs to the authenticated sipgate user. Run list_provisioning_endpoints and use one of its IDs."
        case .notRegisterDevice(let deviceID):
            "sipgate device '\(deviceID)' is not a register device. Run list_provisioning_endpoints and use one of its IDs."
        case .credentialsMissing:
            "sipgate did not return complete SIP credentials for the register device. Try again or create a new register device."
        }
    }
}

struct SipgateDevice: Equatable, Sendable {
    let id: String
    let alias: String
    let online: Bool
    let type: String

    var isRegister: Bool { type.caseInsensitiveCompare("REGISTER") == .orderedSame }
}

struct SipgateDeviceCredentials: Equatable, Sendable {
    let username: String?
    let password: String?
    let sipServer: String?
    let outboundProxy: String?
}

struct SipgateDeviceDetails: Equatable, Sendable {
    let device: SipgateDevice
    let credentials: SipgateDeviceCredentials?
}

protocol SipgateClientProtocol: Sendable {
    func authenticatedUserID() async throws -> String
    func listRegisterDevices(userID: String) async throws -> [SipgateDevice]
    func createRegisterDevice(userID: String, alias: String?) async throws -> SipgateDevice
    func deviceDetails(deviceID: String) async throws -> SipgateDeviceDetails
    func rotatePassword(deviceID: String) async throws
}

struct SipgateProvisioningPlan: Sendable {
    let account: ManagedSIPAccount
    let password: String
    let device: SipgateDevice
}

struct SipgateProvisioningService: Sendable {
    let client: any SipgateClientProtocol

    func listDevices() async throws -> [SipgateDevice] {
        let userID = try await client.authenticatedUserID()
        return try await client.listRegisterDevices(userID: userID).filter(\.isRegister)
    }

    /// `preflight` runs the local checks that can still refuse the line — an
    /// active call, a duplicate account. It runs BEFORE any password rotation,
    /// because a rotation that is followed by a local refusal would leave the
    /// sipgate device with a password nobody holds.
    func provisioningPlan(
        for arguments: ControlProvisionLine,
        preflight: (ManagedSIPAccount) throws -> Void = { _ in }
    ) async throws -> SipgateProvisioningPlan {
        let existingID = normalizedText(arguments.deviceID)
        guard (existingID != nil) != arguments.createDevice else {
            throw SipgateProvisioningError.invalidArguments
        }

        let userID = try await client.authenticatedUserID()
        let selected: SipgateDevice
        if arguments.createDevice {
            selected = try await client.createRegisterDevice(
                userID: userID,
                alias: normalizedText(arguments.alias)
            )
            guard selected.isRegister else {
                throw SipgateProvisioningError.notRegisterDevice(selected.id)
            }
        } else if let existingID {
            let devices = try await client.listRegisterDevices(userID: userID)
            if let match = devices.first(where: { $0.id == existingID && $0.isRegister }) {
                selected = match
            } else {
                let details = try await deviceDetails(deviceID: existingID)
                guard details.device.isRegister else {
                    throw SipgateProvisioningError.notRegisterDevice(existingID)
                }
                throw SipgateProvisioningError.deviceNotFound(existingID)
            }
        } else {
            throw SipgateProvisioningError.invalidArguments
        }

        var details = try await deviceDetails(deviceID: selected.id)
        guard details.device.id == selected.id else {
            throw SipgateProvisioningError.invalidResponse("device credentials")
        }
        guard details.device.isRegister else {
            throw SipgateProvisioningError.notRegisterDevice(selected.id)
        }
        guard let credentials = details.credentials,
              let username = normalizedText(credentials.username),
              let password = credentials.password, !password.isEmpty,
              let sipServer = normalizedText(credentials.sipServer),
              let outboundProxy = normalizedText(credentials.outboundProxy) else {
            throw SipgateProvisioningError.credentialsMissing
        }

        func account(username: String, sipServer: String, outboundProxy: String) -> ManagedSIPAccount {
            let defaults = SIPProviderPreset.sipgate.defaults
            return ManagedSIPAccount(
                provider: .sipgate,
                username: username,
                domain: sipServer,
                outboundProxy: outboundProxy,
                stunServer: defaults.stunServer,
                mediaEncryption: defaults.mediaEncryption,
                label: normalizedText(arguments.label)
            )
        }

        var candidate = account(username: username, sipServer: sipServer, outboundProxy: outboundProxy)
        try preflight(candidate)

        var effectivePassword = password
        if arguments.rotatePassword {
            try await client.rotatePassword(deviceID: selected.id)
            // From here on the old password is dead. Any failure must say so,
            // otherwise the device is left unusable with no explanation.
            do {
                details = try await deviceDetails(deviceID: selected.id)
                guard let rotated = details.credentials,
                      let rotatedUsername = normalizedText(rotated.username),
                      let newPassword = rotated.password, !newPassword.isEmpty,
                      let rotatedServer = normalizedText(rotated.sipServer),
                      let rotatedProxy = normalizedText(rotated.outboundProxy) else {
                    throw SipgateProvisioningError.credentialsMissing
                }
                effectivePassword = newPassword
                candidate = account(
                    username: rotatedUsername,
                    sipServer: rotatedServer,
                    outboundProxy: rotatedProxy
                )
            } catch {
                throw SipgateProvisioningError.rotatedWithoutProvisioning(
                    deviceID: selected.id,
                    reason: (error as? SipgateProvisioningError)?.errorDescription
                        ?? "the new credentials could not be read"
                )
            }
        }
        return SipgateProvisioningPlan(account: candidate, password: effectivePassword, device: details.device)
    }

    private func deviceDetails(deviceID: String) async throws -> SipgateDeviceDetails {
        do {
            return try await client.deviceDetails(deviceID: deviceID)
        } catch let error as SipgateProvisioningError {
            if case .requestDenied(status: 404, message: _) = error {
                throw SipgateProvisioningError.deviceNotFound(deviceID)
            }
            throw error
        }
    }
}

final class SipgateAPIClient: SipgateClientProtocol, @unchecked Sendable {
    private let credentials: SipgatePATCredentials
    private let baseURL: URL
    private let session: URLSession

    init(
        credentials: SipgatePATCredentials,
        baseURL: URL = URL(string: "https://api.sipgate.com/v2")!,
        session: URLSession = .shared
    ) {
        self.credentials = credentials
        self.baseURL = baseURL
        self.session = session
    }

    func authenticatedUserID() async throws -> String {
        let response: UserInfoResponse = try await decodedRequest(
            path: ["authorization", "userinfo"],
            subject: "authenticated user"
        )
        guard let userID = normalizedText(response.sub), validSipgateID(userID) else {
            throw SipgateProvisioningError.invalidResponse("authenticated user")
        }
        return userID
    }

    func listRegisterDevices(userID: String) async throws -> [SipgateDevice] {
        guard validSipgateID(userID) else {
            throw SipgateProvisioningError.invalidResponse("authenticated user")
        }
        let response: DevicesResponse = try await decodedRequest(
            path: [userID, "devices"],
            queryItems: [URLQueryItem(name: "type", value: "register")],
            subject: "register devices"
        )
        guard let items = response.items else {
            throw SipgateProvisioningError.invalidResponse("register devices")
        }
        return try items.map { try device(from: $0, subject: "register devices") }
    }

    func createRegisterDevice(userID: String, alias: String?) async throws -> SipgateDevice {
        guard validSipgateID(userID) else {
            throw SipgateProvisioningError.invalidResponse("authenticated user")
        }
        let body = try JSONEncoder().encode(CreateRegisterDeviceRequest(alias: alias))
        let response: DeviceResponse = try await decodedRequest(
            path: [userID, "devices", "register"],
            method: "POST",
            body: body,
            subject: "new register device",
            echoesErrorBody: false
        )
        return try device(from: response, subject: "new register device")
    }

    func deviceDetails(deviceID: String) async throws -> SipgateDeviceDetails {
        guard validSipgateID(deviceID) else {
            throw SipgateProvisioningError.deviceNotFound(deviceID)
        }
        let response: DeviceDetailsResponse = try await decodedRequest(
            path: ["devices", deviceID],
            subject: "device credentials",
            echoesErrorBody: false
        )
        let device = try device(from: response.deviceResponse, subject: "device credentials")
        let credentials = response.credentials.map {
            SipgateDeviceCredentials(
                username: $0.username,
                password: $0.password,
                sipServer: $0.sipServer,
                outboundProxy: $0.outboundProxy
            )
        }
        return SipgateDeviceDetails(device: device, credentials: credentials)
    }

    func rotatePassword(deviceID: String) async throws {
        guard validSipgateID(deviceID) else {
            throw SipgateProvisioningError.deviceNotFound(deviceID)
        }
        _ = try await request(
            path: ["devices", deviceID, "credentials", "password"],
            method: "POST"
        )
    }

    private func decodedRequest<Response: Decodable>(
        path: [String],
        queryItems: [URLQueryItem] = [],
        method: String = "GET",
        body: Data? = nil,
        subject: String,
        echoesErrorBody: Bool = true
    ) async throws -> Response {
        let data = try await request(
            path: path,
            queryItems: queryItems,
            method: method,
            body: body,
            echoesErrorBody: echoesErrorBody
        )
        guard !data.isEmpty else { throw SipgateProvisioningError.invalidResponse(subject) }
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw SipgateProvisioningError.invalidResponse(subject)
        }
    }

    private func request(
        path: [String],
        queryItems: [URLQueryItem] = [],
        method: String = "GET",
        body: Data? = nil,
        echoesErrorBody: Bool = true
    ) async throws -> Data {
        var url = baseURL
        for component in path { url.appendPathComponent(component) }
        if !queryItems.isEmpty {
            guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                throw SipgateProvisioningError.invalidResponse("request URL")
            }
            components.queryItems = queryItems
            guard let queryURL = components.url else {
                throw SipgateProvisioningError.invalidResponse("request URL")
            }
            url = queryURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let basicValue = Data("\(credentials.tokenID):\(credentials.token)".utf8).base64EncodedString()
        request.setValue("Basic \(basicValue)", forHTTPHeaderField: "Authorization")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw SipgateProvisioningError.networkUnavailable
        }
        guard let http = response as? HTTPURLResponse else {
            throw SipgateProvisioningError.invalidResponse("HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            // A credential endpoint can name the very password being fetched,
            // which is not yet known to any scrubber. Never quote those bodies.
            let safeMessage = echoesErrorBody
                ? safeSipgateAPIMessage(
                    body: data,
                    contentType: http.value(forHTTPHeaderField: "Content-Type"),
                    sensitiveValues: [credentials.tokenID, credentials.token, basicValue]
                )
                : nil
            throw SipgateProvisioningError.requestDenied(status: http.statusCode, message: safeMessage)
        }
        return data
    }

    private func device(from response: DeviceResponse, subject: String) throws -> SipgateDevice {
        guard let id = normalizedText(response.id), validSipgateID(id),
              let type = normalizedText(response.type) else {
            throw SipgateProvisioningError.invalidResponse(subject)
        }
        return SipgateDevice(
            id: id,
            alias: normalizedText(response.alias) ?? "",
            online: response.online ?? false,
            type: type
        )
    }
}

private struct UserInfoResponse: Decodable {
    let sub: String?
}

private struct DevicesResponse: Decodable {
    let items: [DeviceResponse]?
}

private struct DeviceResponse: Decodable {
    let id: String?
    let alias: String?
    let online: Bool?
    let type: String?
}

private struct DeviceDetailsResponse: Decodable {
    let id: String?
    let alias: String?
    let online: Bool?
    let type: String?
    let credentials: CredentialsResponse?

    var deviceResponse: DeviceResponse {
        DeviceResponse(id: id, alias: alias, online: online, type: type)
    }
}

private struct CredentialsResponse: Decodable {
    let username: String?
    let password: String?
    let sipServer: String?
    let outboundProxy: String?
}

private struct CreateRegisterDeviceRequest: Encodable {
    let alias: String?
}

func safeSipgateAPIMessage(
    body: Data,
    contentType: String?,
    sensitiveValues: [String]
) -> String? {
    guard contentType?.lowercased().hasPrefix("text/plain") == true,
          let message = String(data: body, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
          (1...200).contains(message.count) else { return nil }
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " ,.'()-"))
    guard message.unicodeScalars.allSatisfy({ allowed.contains($0) }),
          sensitiveValues.filter({ !$0.isEmpty }).allSatisfy({
              message.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) == nil
          }) else { return nil }
    return message
}

func controlSipgateDevicePayload(_ device: SipgateDevice) -> JSONValue {
    .object([
        "id": .string(device.id),
        "alias": .string(device.alias),
        "online": .bool(device.online)
    ])
}

/// The one provider that can hand out SIP endpoints today. Named in every
/// answer so a caller learns who replied from the data rather than from a tool
/// name it would have to relearn when a second provider arrives.
let provisioningProviderName = "sipgate"

func controlProvisioningEndpointsPayload(
    _ devices: [SipgateDevice],
    sensitiveValues: [String]
) -> JSONValue {
    redactingJSONValue(
        .object([
            "provider": .string(provisioningProviderName),
            "devices": .array(devices.map(controlSipgateDevicePayload))
        ]),
        sensitiveValues: sensitiveValues
    )
}

func controlSipgateCredentialsStatusPayload(_ status: SipgateCredentialsStatus) -> JSONValue {
    .object([
        "provider": .string(provisioningProviderName),
        "configured": .bool(status.configured),
        "token_id_length": .integer(status.tokenIDLength)
    ])
}

func controlSipgateProvisioningPayload(
    linePayload: JSONValue,
    device: SipgateDevice,
    sensitiveValues: [String]
) -> JSONValue {
    guard case .object(var result) = linePayload else { return .object([:]) }
    result["endpoint_id"] = .string(device.id)
    result["endpoint_alias"] = .string(device.alias)
    return redactingJSONValue(.object(result), sensitiveValues: sensitiveValues)
}

private func redactingJSONValue(_ value: JSONValue, sensitiveValues: [String]) -> JSONValue {
    switch value {
    case .object(let object):
        .object(object.mapValues { redactingJSONValue($0, sensitiveValues: sensitiveValues) })
    case .array(let array):
        .array(array.map { redactingJSONValue($0, sensitiveValues: sensitiveValues) })
    case .string(let string):
        .string(sensitiveValues.reduce(string) { result, secret in
            secret.isEmpty ? result : result.replacingOccurrences(of: secret, with: "••••")
        })
    case .integer, .double, .bool, .null:
        value
    }
}

private func normalizedText(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

private func validSipgateID(_ value: String) -> Bool {
    guard !value.isEmpty, value.count <= 128 else { return false }
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
    return value.unicodeScalars.allSatisfy { allowed.contains($0) }
}
