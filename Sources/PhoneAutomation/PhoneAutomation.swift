import CryptoKit
import Foundation
import Security

public enum JSONValue: Codable, Equatable, Sendable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case integer(Int)
    case double(Double)
    case bool(Bool)
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Int.self) { self = .integer(value) }
        else if let value = try? container.decode(Double.self) { self = .double(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
        else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value") }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

public enum PhoneEventKind: Equatable, Sendable {
    case callIncoming(peer: String?)
    case callOutgoing(target: String)
    case callAnswered(peer: String?)
    case callHungup(peer: String?, duration: TimeInterval, missed: Bool)
    case callDTMF(digit: String)
    case transcriptFinal(speaker: String, text: String)
    case callSummary(text: String, fields: [String: String])

    public var type: String {
        switch self {
        case .callIncoming: "call.incoming"
        case .callOutgoing: "call.outgoing"
        case .callAnswered: "call.answered"
        case .callHungup: "call.hungup"
        case .callDTMF: "call.dtmf"
        case .transcriptFinal: "transcript.final"
        case .callSummary: "call.summary"
        }
    }

    public var isConversationContent: Bool {
        switch self {
        case .transcriptFinal, .callSummary: true
        default: false
        }
    }

    var data: [String: JSONValue] {
        switch self {
        case .callIncoming(let peer): ["peer": peer.map(JSONValue.string) ?? .null]
        case .callOutgoing(let target): ["target": .string(target)]
        case .callAnswered(let peer): ["peer": peer.map(JSONValue.string) ?? .null]
        case .callHungup(let peer, let duration, let missed):
            ["peer": peer.map(JSONValue.string) ?? .null, "duration": .double(duration), "missed": .bool(missed)]
        case .callDTMF(let digit): ["digit": .string(digit)]
        case .transcriptFinal(let speaker, let text): ["speaker": .string(speaker), "text": .string(text)]
        case .callSummary(let text, let fields):
            [
                "text": .string(text),
                "fields": .object(fields.mapValues(JSONValue.string))
            ]
        }
    }
}

public struct PhoneEvent: Encodable, Equatable, Sendable {
    public let id: UInt64
    public let kind: PhoneEventKind
    public let timestamp: Date

    public init(id: UInt64, kind: PhoneEventKind, timestamp: Date) {
        self.id = id
        self.kind = kind
        self.timestamp = timestamp
    }

    enum CodingKeys: String, CodingKey {
        case id
        case type
        case timestamp
        case data
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind.type, forKey: .type)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(kind.data, forKey: .data)
    }

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}

@MainActor
public final class PhoneEventBus {
    public typealias Subscriber = (PhoneEvent) -> Void

    private var nextID: UInt64 = 1
    private var subscribers: [UUID: Subscriber] = [:]

    public init() {}

    @discardableResult
    public func subscribe(_ subscriber: @escaping Subscriber) -> UUID {
        let token = UUID()
        subscribers[token] = subscriber
        return token
    }

    public func unsubscribe(_ token: UUID) {
        subscribers[token] = nil
    }

    @discardableResult
    public func publish(_ kind: PhoneEventKind, at timestamp: Date = Date()) -> PhoneEvent {
        let event = PhoneEvent(id: nextID, kind: kind, timestamp: timestamp)
        nextID += 1
        for subscriber in subscribers.values { subscriber(event) }
        return event
    }
}

public enum WebhookSignature {
    public static func hexDigest(body: Data, secret: String) -> String {
        let key = SymmetricKey(data: Data(secret.utf8))
        let digest = HMAC<SHA256>.authenticationCode(for: body, using: key)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

public func validatedDialTarget(_ value: String) -> String? {
    let target = value.trimmingCharacters(in: .whitespacesAndNewlines)
    let forbidden = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
    guard !target.isEmpty,
          target.utf8.count <= 256,
          target.unicodeScalars.allSatisfy({ !forbidden.contains($0) }) else { return nil }
    return target
}

public struct ControlCreateLine: Equatable, Sendable {
    public let provider: String?
    public let username: String
    public let password: String
    public let domain: String?
    public let outboundProxy: String?
    public let stunServer: String?
    public let mediaEncryption: String?
    public let label: String?
    public let sipDisplayName: String?
    public let outboundCallerID: String?

    public init(
        provider: String?,
        username: String,
        password: String,
        domain: String?,
        outboundProxy: String?,
        stunServer: String?,
        mediaEncryption: String?,
        label: String?,
        sipDisplayName: String?,
        outboundCallerID: String?
    ) {
        self.provider = provider
        self.username = username
        self.password = password
        self.domain = domain
        self.outboundProxy = outboundProxy
        self.stunServer = stunServer
        self.mediaEncryption = mediaEncryption
        self.label = label
        self.sipDisplayName = sipDisplayName
        self.outboundCallerID = outboundCallerID
    }
}

public struct ControlUpdateLine: Equatable, Sendable {
    public let line: String
    public let provider: String?
    public let password: String?
    public let domain: String?
    public let outboundProxy: String?
    public let stunServer: String?
    public let mediaEncryption: String?
    public let label: String?
    public let sipDisplayName: String?
    public let outboundCallerID: String?

    public init(
        line: String,
        provider: String?,
        password: String?,
        domain: String?,
        outboundProxy: String?,
        stunServer: String?,
        mediaEncryption: String?,
        label: String?,
        sipDisplayName: String?,
        outboundCallerID: String?
    ) {
        self.line = line
        self.provider = provider
        self.password = password
        self.domain = domain
        self.outboundProxy = outboundProxy
        self.stunServer = stunServer
        self.mediaEncryption = mediaEncryption
        self.label = label
        self.sipDisplayName = sipDisplayName
        self.outboundCallerID = outboundCallerID
    }
}

public struct ControlProvisionLine: Equatable, Sendable {
    public let deviceID: String?
    public let createDevice: Bool
    public let alias: String?
    public let label: String?
    public let rotatePassword: Bool

    public init(
        deviceID: String?,
        createDevice: Bool,
        alias: String?,
        label: String?,
        rotatePassword: Bool
    ) {
        self.deviceID = deviceID
        self.createDevice = createDevice
        self.alias = alias
        self.label = label
        self.rotatePassword = rotatePassword
    }
}

public enum ControlAssistantAnswerMode: String, Equatable, Sendable {
    case never
    case always
    case outsideBusinessHours = "outside_business_hours"
}

public struct ControlBusinessHoursDayGroup: Equatable, Sendable {
    public let open: Bool
    public let startMinute: Int
    public let endMinute: Int

    public init(open: Bool, startMinute: Int, endMinute: Int) {
        self.open = open
        self.startMinute = startMinute
        self.endMinute = endMinute
    }
}

public enum ControlCommand: Equatable, Sendable {
    case dial(String, account: String?)
    case assistantCall(String, task: String, account: String?)
    case answer
    case hangup
    case sendDTMF(String)
    case getState
    case getHistory(limit: Int, query: String?)
    case getLastSummary
    case getTranscript(callID: String?, limit: Int)
    case listLines
    case listProvisioningEndpoints
    case provisionLine(ControlProvisionLine)
    case provisioningStatus
    case createLine(ControlCreateLine)
    case updateLine(ControlUpdateLine)
    case deleteLine(line: String)
    case selectActiveLine(line: String)
    case getRegistrationStatus(line: String?)
    case setLineEnabled(line: String, enabled: Bool)
    case setLineProfile(line: String, profile: String)
    case setLinePrompt(line: String, instructions: String, contextData: String?)
    case createAssistantProfile(name: String, instructions: String, contextData: String?)
    case updateAssistantProfile(profileID: String, name: String?, instructions: String?, contextData: String?)
    case deleteAssistantProfile(profileID: String)
    case listAssistantProfiles
    case setLineAnswerMode(line: String, mode: ControlAssistantAnswerMode, answerDelaySeconds: Int?)
    case setLineBusinessHours(
        line: String,
        weekdays: ControlBusinessHoursDayGroup,
        weekend: ControlBusinessHoursDayGroup
    )
    case findContact(String)
}

public struct ControlError: Error, Codable, Equatable, Sendable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

public enum ControlRequestParser {
    public static func parse(_ data: Data) -> Result<ControlCommand, ControlError> {
        guard case .object(let request) = try? JSONDecoder().decode(JSONValue.self, from: data),
              Set(request.keys).isSubset(of: ["cmd", "args"]),
              case .string(let command) = request["cmd"] else {
            return .failure(ControlError(code: "invalid_request", message: "Request must be a JSON object with cmd and args."))
        }
        let args: [String: JSONValue]
        if let value = request["args"] {
            guard case .object(let object) = value else {
                return .failure(ControlError(code: "invalid_request", message: "args must be a JSON object."))
            }
            args = object
        } else {
            args = [:]
        }
        switch command {
        case "dial":
            guard Set(args.keys).isSubset(of: ["number", "account"]), case .string(let number) = args["number"],
                  let target = validatedDialTarget(number) else {
                return .failure(ControlError(code: "invalid_arguments", message: "dial requires a valid string argument number and optionally account."))
            }
            let account: String?
            if let value = args["account"] {
                guard case .string(let name) = value, !name.trimmingCharacters(in: .whitespaces).isEmpty else {
                    return .failure(ControlError(code: "invalid_arguments", message: "account must be a non-empty string."))
                }
                account = name.trimmingCharacters(in: .whitespaces)
            } else {
                account = nil
            }
            return .success(.dial(target, account: account))
        case "assistant_call":
            guard Set(args.keys).isSubset(of: ["number", "task", "account"]),
                  case .string(let number) = args["number"],
                  let target = validatedDialTarget(number),
                  case .string(let rawTask) = args["task"] else {
                return .failure(ControlError(code: "invalid_arguments", message: "assistant_call requires number and task, optionally account."))
            }
            let task = rawTask.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !task.isEmpty, task.utf8.count <= 4096 else {
                return .failure(ControlError(code: "invalid_arguments", message: "task must be a non-empty string of at most 4096 bytes."))
            }
            let account: String?
            if let value = args["account"] {
                guard case .string(let name) = value, !name.trimmingCharacters(in: .whitespaces).isEmpty else {
                    return .failure(ControlError(code: "invalid_arguments", message: "account must be a non-empty string."))
                }
                account = name.trimmingCharacters(in: .whitespaces)
            } else {
                account = nil
            }
            return .success(.assistantCall(target, task: task, account: account))
        case "answer":
            return noArguments(args, command: .answer)
        case "hangup":
            return noArguments(args, command: .hangup)
        case "send_dtmf":
            guard Set(args.keys) == ["digit"], case .string(let digit) = args["digit"],
                  digit.count == 1, "0123456789*#".contains(digit) else {
                return .failure(ControlError(code: "invalid_arguments", message: "send_dtmf requires one digit from 0-9, *, or #."))
            }
            return .success(.sendDTMF(digit))
        case "get_state":
            return noArguments(args, command: .getState)
        case "list_lines":
            return noArguments(args, command: .listLines)
        case "list_provisioning_endpoints":
            return noArguments(args, command: .listProvisioningEndpoints)
        case "provisioning_status":
            return noArguments(args, command: .provisioningStatus)
        case "provision_line":
            let allowed = Set(["device_id", "create_device", "alias", "label", "rotate_password"])
            guard Set(args.keys).isSubset(of: allowed),
                  optionalStrings(in: args, keys: ["device_id", "alias", "label"]),
                  optionalBooleans(in: args, keys: ["create_device", "rotate_password"]) else {
                return .failure(ControlError(
                    code: "invalid_arguments",
                    message: "provision_line accepts string device_id, alias, and label arguments plus boolean create_device and rotate_password arguments."
                ))
            }
            let deviceID = trimmedString(args["device_id"])
            let createDevice = boolean(args["create_device"]) ?? false
            let hasDeviceID = args["device_id"] != nil
            let hasCreateDevice = args["create_device"] != nil
            guard hasDeviceID != hasCreateDevice else {
                return .failure(ControlError(
                    code: "invalid_arguments",
                    message: "Give exactly one of device_id or create_device."
                ))
            }
            guard !hasDeviceID || deviceID?.isEmpty == false else {
                return .failure(ControlError(code: "invalid_arguments", message: "device_id must be a non-empty string."))
            }
            guard !hasCreateDevice || createDevice else {
                return .failure(ControlError(code: "invalid_arguments", message: "create_device must be true when provided."))
            }
            let alias = trimmedString(args["alias"])
            guard createDevice || args["alias"] == nil else {
                return .failure(ControlError(
                    code: "invalid_arguments",
                    message: "alias is only valid when create_device is true."
                ))
            }
            return .success(.provisionLine(ControlProvisionLine(
                deviceID: deviceID,
                createDevice: createDevice,
                alias: alias?.isEmpty == false ? alias : nil,
                label: trimmedString(args["label"]),
                rotatePassword: boolean(args["rotate_password"]) ?? false
            )))
        case "create_line":
            let allowed = Set([
                "provider", "username", "password", "domain", "outbound_proxy", "stun_server",
                "media_encryption", "label", "sip_display_name", "outbound_caller_id"
            ])
            guard Set(args.keys).isSubset(of: allowed),
                  optionalStrings(in: args, keys: allowed.subtracting(["username", "password"])),
                  case .string(let rawUsername)? = args["username"],
                  case .string(let password)? = args["password"] else {
                return .failure(ControlError(
                    code: "invalid_arguments",
                    message: "create_line requires string username and password arguments; all provider and display settings must also be strings."
                ))
            }
            let username = rawUsername.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !username.isEmpty else {
                return .failure(ControlError(code: "invalid_arguments", message: "username must be a non-empty string."))
            }
            if let error = validateProviderArgument(args["provider"]) { return .failure(error) }
            return .success(.createLine(ControlCreateLine(
                provider: trimmedString(args["provider"]),
                username: username,
                password: password,
                domain: trimmedString(args["domain"]),
                outboundProxy: trimmedString(args["outbound_proxy"]),
                stunServer: trimmedString(args["stun_server"]),
                mediaEncryption: trimmedString(args["media_encryption"]),
                label: trimmedString(args["label"]),
                sipDisplayName: trimmedString(args["sip_display_name"]),
                outboundCallerID: trimmedString(args["outbound_caller_id"])
            )))
        case "update_line":
            let mutable = Set([
                "provider", "password", "domain", "outbound_proxy", "stun_server", "media_encryption",
                "label", "sip_display_name", "outbound_caller_id"
            ])
            let allowed = mutable.union(["line"])
            guard Set(args.keys).isSubset(of: allowed),
                  !Set(args.keys).intersection(mutable).isEmpty,
                  optionalStrings(in: args, keys: mutable),
                  case .string(let rawLine)? = args["line"] else {
                return .failure(ControlError(
                    code: "invalid_arguments",
                    message: "update_line requires line and at least one string setting to change."
                ))
            }
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else {
                return .failure(ControlError(code: "invalid_arguments", message: "line must be a non-empty string."))
            }
            if let error = validateProviderArgument(args["provider"]) { return .failure(error) }
            return .success(.updateLine(ControlUpdateLine(
                line: line,
                provider: trimmedString(args["provider"]),
                password: string(args["password"]),
                domain: trimmedString(args["domain"]),
                outboundProxy: trimmedString(args["outbound_proxy"]),
                stunServer: trimmedString(args["stun_server"]),
                mediaEncryption: trimmedString(args["media_encryption"]),
                label: trimmedString(args["label"]),
                sipDisplayName: trimmedString(args["sip_display_name"]),
                outboundCallerID: trimmedString(args["outbound_caller_id"])
            )))
        case "delete_line":
            return singleLineArgument(args) { .deleteLine(line: $0) }
        case "select_active_line":
            return singleLineArgument(args) { .selectActiveLine(line: $0) }
        case "get_registration_status":
            guard Set(args.keys).isSubset(of: ["line"]), optionalStrings(in: args, keys: ["line"]) else {
                return .failure(ControlError(code: "invalid_arguments", message: "get_registration_status accepts only an optional string line."))
            }
            if let rawLine = string(args["line"]) {
                let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !line.isEmpty else {
                    return .failure(ControlError(code: "invalid_arguments", message: "line must be a non-empty string."))
                }
                return .success(.getRegistrationStatus(line: line))
            }
            return .success(.getRegistrationStatus(line: nil))
        case "set_line_enabled":
            guard Set(args.keys).isSubset(of: ["line", "enabled"]),
                  case .string(let line)? = args["line"],
                  !line.trimmingCharacters(in: .whitespaces).isEmpty,
                  case .bool(let enabled)? = args["enabled"] else {
                return .failure(ControlError(
                    code: "invalid_arguments",
                    message: "set_line_enabled requires a non-empty string line and a boolean enabled."
                ))
            }
            return .success(.setLineEnabled(line: line.trimmingCharacters(in: .whitespaces), enabled: enabled))
        case "set_line_profile":
            guard Set(args.keys).isSubset(of: ["line", "profile"]),
                  case .string(let line)? = args["line"],
                  !line.trimmingCharacters(in: .whitespaces).isEmpty,
                  case .string(let profile)? = args["profile"],
                  !profile.trimmingCharacters(in: .whitespaces).isEmpty else {
                return .failure(ControlError(
                    code: "invalid_arguments",
                    message: "set_line_profile requires non-empty string arguments line and profile."
                ))
            }
            return .success(.setLineProfile(
                line: line.trimmingCharacters(in: .whitespaces),
                profile: profile.trimmingCharacters(in: .whitespaces)
            ))
        case "set_line_prompt":
            guard Set(args.keys).isSubset(of: ["line", "instructions", "context_data"]),
                  optionalStrings(in: args, keys: ["context_data"]),
                  case .string(let rawLine)? = args["line"],
                  case .string(let rawInstructions)? = args["instructions"] else {
                return .failure(ControlError(
                    code: "invalid_arguments",
                    message: "set_line_prompt requires string line and instructions arguments and optionally context_data."
                ))
            }
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            let instructions = rawInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !instructions.isEmpty else {
                return .failure(ControlError(code: "invalid_arguments", message: "line and instructions must be non-empty strings."))
            }
            return .success(.setLinePrompt(
                line: line,
                instructions: instructions,
                contextData: trimmedString(args["context_data"])
            ))
        case "create_assistant_profile":
            guard Set(args.keys).isSubset(of: ["name", "instructions", "context_data"]),
                  optionalStrings(in: args, keys: ["context_data"]),
                  case .string(let rawName)? = args["name"],
                  case .string(let rawInstructions)? = args["instructions"] else {
                return .failure(ControlError(
                    code: "invalid_arguments",
                    message: "create_assistant_profile requires string name and instructions arguments and optionally context_data."
                ))
            }
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            let instructions = rawInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !instructions.isEmpty else {
                return .failure(ControlError(code: "invalid_arguments", message: "name and instructions must be non-empty strings."))
            }
            return .success(.createAssistantProfile(
                name: name,
                instructions: instructions,
                contextData: trimmedString(args["context_data"])
            ))
        case "update_assistant_profile":
            let mutable = Set(["name", "instructions", "context_data"])
            guard Set(args.keys).isSubset(of: mutable.union(["profile_id"])),
                  !Set(args.keys).intersection(mutable).isEmpty,
                  optionalStrings(in: args, keys: mutable),
                  case .string(let rawID)? = args["profile_id"] else {
                return .failure(ControlError(
                    code: "invalid_arguments",
                    message: "update_assistant_profile requires profile_id and at least one string setting to change."
                ))
            }
            let profileID = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = trimmedString(args["name"])
            let instructions = trimmedString(args["instructions"])
            guard !profileID.isEmpty,
                  args["name"] == nil || !(name ?? "").isEmpty,
                  args["instructions"] == nil || !(instructions ?? "").isEmpty else {
                return .failure(ControlError(
                    code: "invalid_arguments",
                    message: "profile_id, name, and instructions must be non-empty when provided."
                ))
            }
            return .success(.updateAssistantProfile(
                profileID: profileID,
                name: name,
                instructions: instructions,
                contextData: trimmedString(args["context_data"])
            ))
        case "delete_assistant_profile":
            guard Set(args.keys) == ["profile_id"],
                  case .string(let rawID)? = args["profile_id"],
                  !rawID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .failure(ControlError(code: "invalid_arguments", message: "delete_assistant_profile requires a non-empty string profile_id."))
            }
            return .success(.deleteAssistantProfile(profileID: rawID.trimmingCharacters(in: .whitespacesAndNewlines)))
        case "list_assistant_profiles":
            return noArguments(args, command: .listAssistantProfiles)
        case "set_line_answer_mode":
            guard Set(args.keys).isSubset(of: ["line", "mode", "answer_delay_seconds"]),
                  case .string(let rawLine)? = args["line"],
                  case .string(let rawMode)? = args["mode"],
                  let mode = ControlAssistantAnswerMode(rawValue: rawMode),
                  args["answer_delay_seconds"] == nil || integer(args["answer_delay_seconds"]) != nil else {
                return .failure(ControlError(
                    code: "invalid_arguments",
                    message: "set_line_answer_mode requires line, mode (never, always, or outside_business_hours), and optionally an integer answer_delay_seconds."
                ))
            }
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else {
                return .failure(ControlError(code: "invalid_arguments", message: "line must be a non-empty string."))
            }
            return .success(.setLineAnswerMode(
                line: line,
                mode: mode,
                answerDelaySeconds: integer(args["answer_delay_seconds"])
            ))
        case "set_line_business_hours":
            guard Set(args.keys) == ["line", "weekdays", "weekend"],
                  case .string(let rawLine)? = args["line"],
                  let weekdays = businessHoursDayGroup(args["weekdays"]),
                  let weekend = businessHoursDayGroup(args["weekend"]) else {
                return .failure(ControlError(
                    code: "invalid_arguments",
                    message: "set_line_business_hours requires line plus weekdays and weekend objects containing open, start_minute, and end_minute (0 through 1439)."
                ))
            }
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else {
                return .failure(ControlError(code: "invalid_arguments", message: "line must be a non-empty string."))
            }
            return .success(.setLineBusinessHours(line: line, weekdays: weekdays, weekend: weekend))
        case "find_contact":
            guard Set(args.keys).isSubset(of: ["name"]),
                  case .string(let name)? = args["name"],
                  !name.trimmingCharacters(in: .whitespaces).isEmpty else {
                return .failure(ControlError(code: "invalid_arguments", message: "find_contact requires a non-empty string name."))
            }
            return .success(.findContact(name.trimmingCharacters(in: .whitespaces)))
        case "get_transcript":
            guard Set(args.keys).isSubset(of: ["call_id", "limit"]) else {
                return .failure(ControlError(code: "invalid_arguments", message: "get_transcript accepts only the optional call_id and limit arguments."))
            }
            var callID: String?
            if let value = args["call_id"] {
                guard case .string(let identifier) = value,
                      !identifier.trimmingCharacters(in: .whitespaces).isEmpty else {
                    return .failure(ControlError(code: "invalid_arguments", message: "call_id must be a non-empty string."))
                }
                callID = identifier.trimmingCharacters(in: .whitespaces)
            }
            var limit = 200
            if let value = args["limit"] {
                guard case .integer(let requested) = value, (1...500).contains(requested) else {
                    return .failure(ControlError(code: "invalid_arguments", message: "limit must be an integer from 1 through 500."))
                }
                limit = requested
            }
            return .success(.getTranscript(callID: callID, limit: limit))
        case "get_history":
            guard Set(args.keys).isSubset(of: ["limit", "query"]) else {
                return .failure(ControlError(code: "invalid_arguments", message: "get_history accepts only the optional limit and query arguments."))
            }
            let limit: Int
            if let value = args["limit"] {
                guard case .integer(let requested) = value, (1...50).contains(requested) else {
                    return .failure(ControlError(code: "invalid_arguments", message: "limit must be an integer from 1 through 50."))
                }
                limit = requested
            } else {
                limit = 20
            }
            var query: String?
            if let value = args["query"] {
                guard case .string(let text) = value, !text.trimmingCharacters(in: .whitespaces).isEmpty else {
                    return .failure(ControlError(code: "invalid_arguments", message: "query must be a non-empty string."))
                }
                query = text.trimmingCharacters(in: .whitespaces)
            }
            return .success(.getHistory(limit: limit, query: query))
        case "get_last_summary":
            return noArguments(args, command: .getLastSummary)
        default:
            return .failure(ControlError(code: "unknown_command", message: "Unknown control command."))
        }
    }

    private static func noArguments(_ args: [String: JSONValue], command: ControlCommand) -> Result<ControlCommand, ControlError> {
        guard args.isEmpty else {
            return .failure(ControlError(code: "invalid_arguments", message: "This command does not accept arguments."))
        }
        return .success(command)
    }

    private static func singleLineArgument(
        _ args: [String: JSONValue],
        command: (String) -> ControlCommand
    ) -> Result<ControlCommand, ControlError> {
        guard Set(args.keys) == ["line"],
              case .string(let rawLine)? = args["line"],
              !rawLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(ControlError(code: "invalid_arguments", message: "This command requires a non-empty string line."))
        }
        return .success(command(rawLine.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    private static func validateProviderArgument(_ value: JSONValue?) -> ControlError? {
        guard let value else { return nil }
        guard case .string(let provider) = value,
              ["telekom", "fritzBox", "sipgate", "easybell", "custom"].contains(provider) else {
            return ControlError(
                code: "invalid_arguments",
                message: "provider must be telekom, fritzBox, sipgate, easybell, or custom."
            )
        }
        return nil
    }

    private static func optionalStrings(in args: [String: JSONValue], keys: Set<String>) -> Bool {
        keys.allSatisfy { key in args[key] == nil || string(args[key]) != nil }
    }

    private static func optionalBooleans(in args: [String: JSONValue], keys: Set<String>) -> Bool {
        keys.allSatisfy { key in args[key] == nil || boolean(args[key]) != nil }
    }

    private static func string(_ value: JSONValue?) -> String? {
        guard case .string(let value) = value else { return nil }
        return value
    }

    private static func trimmedString(_ value: JSONValue?) -> String? {
        string(value)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func integer(_ value: JSONValue?) -> Int? {
        guard case .integer(let value) = value else { return nil }
        return value
    }

    private static func boolean(_ value: JSONValue?) -> Bool? {
        guard case .bool(let value) = value else { return nil }
        return value
    }

    private static func businessHoursDayGroup(_ value: JSONValue?) -> ControlBusinessHoursDayGroup? {
        guard case .object(let object) = value,
              Set(object.keys) == ["open", "start_minute", "end_minute"],
              case .bool(let open)? = object["open"],
              case .integer(let start)? = object["start_minute"],
              case .integer(let end)? = object["end_minute"],
              (0...1439).contains(start),
              (0...1439).contains(end) else { return nil }
        return ControlBusinessHoursDayGroup(open: open, startMinute: start, endMinute: end)
    }
}

public struct ControlResponse: Codable, Equatable, Sendable {
    public let ok: Bool
    public let result: JSONValue?
    public let error: ControlError?

    public static func success(_ result: JSONValue = .object([:])) -> ControlResponse {
        ControlResponse(ok: true, result: result, error: nil)
    }

    public static func failure(_ error: ControlError) -> ControlResponse {
        ControlResponse(ok: false, result: nil, error: error)
    }

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}

public enum MCPProtocol {
    public static let protocolVersion = "2025-06-18"

    public static let tools: [JSONValue] = [
        tool("dial", "Dial a phone number or SIP address. Optionally select the outgoing line first via account (label, username, or SIP address of a configured account).", access: .action, properties: ["number": schema("string"), "account": schema("string")], required: ["number"]),
        tool("assistant_call", "Place an outbound call handled by the AI voice assistant. The task describes what the assistant should accomplish on the call (goal, tone, key details); it navigates IVR menus itself and hands over to the user when a human answers.", access: .action, properties: ["number": schema("string"), "task": schema("string"), "account": schema("string")], required: ["number", "task"]),
        tool("answer", "Answer the incoming call.", access: .action),
        tool("hangup", "Hang up the active call. The call is archived a moment later, so a get_history immediately afterwards may not list it yet.", access: .action),
        tool("send_dtmf", "Send a DTMF digit during the active call.", access: .action, properties: ["digit": .object(["type": .string("string"), "pattern": .string("^[0-9*#]$")])], required: ["digit"]),
        tool("get_state", "Get the current registration and call state.", access: .read),
        tool(
            "get_history",
            "Get recent calls from the on-device call archive, newest first: call_id, direction, peer, caller name, timestamp, duration, whether it was missed, and whether a summary exists. With query, search names, numbers, summaries and transcript text instead of returning the newest calls.",
            access: .read,
            properties: [
                "limit": .object(["type": .string("integer"), "minimum": .integer(1), "maximum": .integer(50), "default": .integer(20)]),
                "query": schema("string")
            ]
        ),
        tool(
            "get_last_summary",
            "Get the most recent call summary, including its structured fields (caller, request, callbackNumber, nextSteps, outcome, details) when the summary is in the labelled format.",
            access: .read,
            properties: [:]
        ),
        tool(
            "list_lines",
            "List the configured SIP lines: label, SIP address, provider, whether the line is online, its registration state, its assistant profile, and which line outgoing calls use. Call this before dial or set_line_* so you know the exact line names.",
            access: .read
        ),
        tool(
            "list_provisioning_endpoints",
            "List the SIP endpoints the telephony provider can hand out, each with id, alias and online state, plus which provider answered. Pass an entry's id to provision_line as device_id. Credentials are never returned. An endpoint reported as online is already in use. Only sipgate can provision today; a line at any other provider is entered by hand with create_line.",
            access: .externalRead
        ),
        tool(
            "provisioning_status",
            "Report which telephony provider can provision lines and whether its API credentials are present in the macOS Keychain. Returns no credential content. Call this before provision_line: without credentials nothing can be provisioned, and a line then has to be entered by hand with create_line.",
            access: .read
        ),
        tool(
            "provision_line",
            "Create a Phone SIP line from an endpoint at the telephony provider. Phone fetches the credentials from the provider itself, stores the SIP password in the Keychain, waits for the line to register, and never returns a secret. Give exactly one of device_id (an existing endpoint from list_provisioning_endpoints) or create_device: true. WHAT THIS CHANGES AT THE PROVIDER: create_device creates a real endpoint on the account, and rotate_password immediately invalidates the password of every other client already using that endpoint — a desk phone or softphone on it stops working at once. An endpoint reported as online is in use by someone; do not take it over or rotate it without being asked to. alias is the name at the provider, label is the name this line gets in Phone.",
            access: .externalWrite,
            properties: [
                "device_id": schema("string"),
                "create_device": .object(["type": .string("boolean")]),
                "alias": schema("string"),
                "label": schema("string"),
                "rotate_password": .object(["type": .string("boolean"), "default": .bool(false)])
            ],
            oneOf: [
                .object(["required": .array([.string("device_id")]), "not": .object(["required": .array([.string("create_device")])])]),
                .object(["required": .array([.string("create_device")])])
            ]
        ),
        tool(
            "create_line",
            "Create and save a SIP line, store its password in Keychain, restart registration, and report whether it registered plus any provider error. Choose a provider preset or omit provider and supply an explicit domain. The password is input-only and is never returned.",
            access: .write,
            properties: [
                "provider": enumSchema(["telekom", "fritzBox", "sipgate", "easybell", "custom"]),
                "username": schema("string"),
                "password": secretSchema,
                "domain": schema("string"),
                "outbound_proxy": schema("string"),
                "stun_server": schema("string"),
                "media_encryption": schema("string"),
                "label": schema("string"),
                "sip_display_name": schema("string"),
                "outbound_caller_id": schema("string")
            ],
            required: ["username", "password"]
        ),
        tool(
            "update_line",
            "Change an existing SIP line's label, display name, caller ID, password, provider, registrar, proxy, STUN server, or media encryption. Omitted fields, including password, are kept; empty optional display or server fields are cleared. Registration-relevant changes restart and report registration.",
            access: .write,
            properties: [
                "line": schema("string"),
                "provider": enumSchema(["telekom", "fritzBox", "sipgate", "easybell", "custom"]),
                "password": secretSchema,
                "domain": schema("string"),
                "outbound_proxy": schema("string"),
                "stun_server": schema("string"),
                "media_encryption": schema("string"),
                "label": schema("string"),
                "sip_display_name": schema("string"),
                "outbound_caller_id": schema("string")
            ],
            required: ["line"]
        ),
        tool(
            "delete_line",
            "Permanently remove a configured SIP line and its Keychain password. Refuses while a call is active.",
            access: .write,
            properties: ["line": schema("string")],
            required: ["line"]
        ),
        tool(
            "select_active_line",
            "Choose which configured online SIP line outgoing calls use.",
            access: .write,
            properties: ["line": schema("string")],
            required: ["line"]
        ),
        tool(
            "get_registration_status",
            "Get enabled, registered, registration state, and last provider error for every SIP line or for one matching line.",
            access: .read,
            properties: ["line": schema("string")]
        ),
        tool(
            "set_line_enabled",
            "Take one SIP line online or offline. An offline line keeps its configuration but does not register, so it receives no calls and cannot place any. Other lines keep their registration. Refuses while that line is on a call.",
            access: .write,
            properties: ["line": schema("string"), "enabled": .object(["type": .string("boolean")])],
            required: ["line", "enabled"]
        ),
        tool(
            "set_line_profile",
            "Switch the assistant profile of one SIP line. The profile decides what the assistant says when it answers that number. Use list_lines for the available line names and the profile each line currently uses.",
            access: .write,
            properties: ["line": schema("string"), "profile": schema("string")],
            required: ["line", "profile"]
        ),
        tool(
            "set_line_prompt",
            "Replace one SIP line's assistant prompt with free-text instructions and optional context data. The line switches to a custom per-line override and no saved profile is required.",
            access: .write,
            properties: [
                "line": schema("string"),
                "instructions": schema("string"),
                "context_data": schema("string")
            ],
            required: ["line", "instructions"]
        ),
        tool(
            "create_assistant_profile",
            "Create a reusable saved assistant profile with a name, prompt instructions, and optional context data. A name that is already taken updates that profile instead of adding a second one under the same name, so the call can be repeated safely.",
            access: .write,
            properties: [
                "name": schema("string"),
                "instructions": schema("string"),
                "context_data": schema("string")
            ],
            required: ["name", "instructions"]
        ),
        tool(
            "update_assistant_profile",
            "Change the name, instructions, or context data of a reusable saved assistant profile. Lines using it see the updated prompt.",
            access: .write,
            properties: [
                "profile_id": schema("string"),
                "name": schema("string"),
                "instructions": schema("string"),
                "context_data": schema("string")
            ],
            required: ["profile_id"]
        ),
        tool(
            "delete_assistant_profile",
            "Delete a reusable saved assistant profile. Lines using it retain a custom copy of its prompt and context.",
            access: .write,
            properties: ["profile_id": schema("string")],
            required: ["profile_id"]
        ),
        tool(
            "list_assistant_profiles",
            "List reusable saved assistant profiles with their IDs, names, instructions, and context data.",
            access: .read
        ),
        tool(
            "set_line_answer_mode",
            "Set whether one line's assistant answers never, always, or only outside business hours, and optionally set its answer delay. The delay is clamped to 0 through 30 seconds.",
            access: .write,
            properties: [
                "line": schema("string"),
                "mode": enumSchema(["never", "always", "outside_business_hours"]),
                "answer_delay_seconds": schema("integer")
            ],
            required: ["line", "mode"]
        ),
        tool(
            "set_line_business_hours",
            "Replace one line's weekday and weekend business-hours windows. Times are minutes after midnight (0 through 1439); an open window may cross midnight.",
            access: .write,
            properties: [
                "line": schema("string"),
                "weekdays": businessHoursDayGroupSchema,
                "weekend": businessHoursDayGroupSchema
            ],
            required: ["line", "weekdays", "weekend"]
        ),
        tool(
            "find_contact",
            "Look up numbers for a contact by name, so a call can be placed to the right number instead of guessing. Returns display name, number, and label per match.",
            access: .read,
            properties: ["name": schema("string")],
            required: ["name"]
        ),
        tool(
            "get_transcript",
            "Get the transcript of a call as an ordered list of utterances with speaker and text, oldest first. Without call_id this returns the most recent call. Use get_history to find a call_id. The reply reports utterance_count and truncated; if truncated is true, ask again with a larger limit or work from get_last_summary instead.",
            access: .read,
            properties: [
                "call_id": schema("string"),
                "limit": .object(["type": .string("integer"), "minimum": .integer(1), "maximum": .integer(500), "default": .integer(200)])
            ]
        )
    ]

    public static func response(
        for data: Data,
        callTool: (String, [String: JSONValue]) -> ControlResponse
    ) -> Data? {
        guard case .object(let request) = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            return encode(errorResponse(id: .null, code: -32700, message: "Parse error"))
        }
        let id = request["id"] ?? .null
        guard request["jsonrpc"] == .string("2.0"), case .string(let method) = request["method"] else {
            return encode(errorResponse(id: id, code: -32600, message: "Invalid Request"))
        }
        if method.hasPrefix("notifications/") { return nil }
        switch method {
        case "initialize":
            return encode(successResponse(id: id, result: .object([
                "protocolVersion": .string(protocolVersion),
                "capabilities": .object(["tools": .object([:])]),
                "serverInfo": .object(["name": .string("phone-mcp"), "version": .string("1.0.0")])
            ])))
        case "tools/list":
            return encode(successResponse(id: id, result: .object(["tools": .array(tools)])))
        case "tools/call":
            guard case .object(let params) = request["params"], case .string(let name) = params["name"] else {
                return encode(errorResponse(id: id, code: -32602, message: "Invalid params"))
            }
            let arguments: [String: JSONValue]
            if let value = params["arguments"] {
                guard case .object(let object) = value else {
                    return encode(errorResponse(id: id, code: -32602, message: "Invalid params"))
                }
                arguments = object
            } else {
                arguments = [:]
            }
            guard tools.contains(where: { toolName($0) == name }) else {
                return encode(errorResponse(id: id, code: -32602, message: "Unknown tool"))
            }
            let control = callTool(name, arguments)
            let text = String(data: (try? control.jsonData()) ?? Data(), encoding: .utf8) ?? "{}"
            return encode(successResponse(id: id, result: .object([
                "content": .array([.object(["type": .string("text"), "text": .string(text)])]),
                "isError": .bool(!control.ok)
            ])))
        default:
            return encode(errorResponse(id: id, code: -32601, message: "Method not found"))
        }
    }

    public static func controlRequest(tool name: String, arguments: [String: JSONValue]) -> Data? {
        let object: JSONValue = .object(["cmd": .string(name), "args": .object(arguments)])
        return try? JSONEncoder().encode(object)
    }

    private static func schema(_ type: String) -> JSONValue {
        .object(["type": .string(type)])
    }

    private static func enumSchema(_ values: [String]) -> JSONValue {
        .object([
            "type": .string("string"),
            "enum": .array(values.map(JSONValue.string))
        ])
    }

    private static let secretSchema = JSONValue.object([
        "type": .string("string"),
        "writeOnly": .bool(true)
    ])

    private static let businessHoursDayGroupSchema = JSONValue.object([
        "type": .string("object"),
        "properties": .object([
            "open": .object(["type": .string("boolean")]),
            "start_minute": .object([
                "type": .string("integer"),
                "minimum": .integer(0),
                "maximum": .integer(1439)
            ]),
            "end_minute": .object([
                "type": .string("integer"),
                "minimum": .integer(0),
                "maximum": .integer(1439)
            ])
        ]),
        "required": .array(["open", "start_minute", "end_minute"].map(JSONValue.string)),
        "additionalProperties": .bool(false)
    ])

    /// How a client should treat a tool when it decides what to run without
    /// asking. Without these a caller cannot tell `dial`, which rings a real
    /// phone, apart from `get_history`, which reads a local database.
    enum ToolAccess {
        /// Reads local state and changes nothing.
        case read
        /// Reads provider state over the network and changes nothing.
        case externalRead
        /// Changes configuration; running it twice lands in the same place.
        case write
        /// Changes provider state over the network and may create or rotate twice.
        case externalWrite
        /// Reaches the telephone network. Not idempotent: twice means two calls.
        case action

        var annotations: [String: JSONValue] {
            switch self {
            case .read:
                ["readOnlyHint": .bool(true), "destructiveHint": .bool(false), "idempotentHint": .bool(true), "openWorldHint": .bool(false)]
            case .externalRead:
                ["readOnlyHint": .bool(true), "destructiveHint": .bool(false), "idempotentHint": .bool(true), "openWorldHint": .bool(true)]
            case .write:
                ["readOnlyHint": .bool(false), "destructiveHint": .bool(true), "idempotentHint": .bool(true), "openWorldHint": .bool(false)]
            case .externalWrite, .action:
                ["readOnlyHint": .bool(false), "destructiveHint": .bool(true), "idempotentHint": .bool(false), "openWorldHint": .bool(true)]
            }
        }
    }

    private static func tool(
        _ name: String,
        _ description: String,
        access: ToolAccess,
        properties: [String: JSONValue] = [:],
        required: [String] = [],
        // An either-or between arguments belongs in the schema, where a client
        // can enforce it, not only in a sentence it may or may not read.
        oneOf: [JSONValue] = []
    ) -> JSONValue {
        var inputSchema: [String: JSONValue] = [
            "type": .string("object"),
            "properties": .object(properties),
            "additionalProperties": .bool(false)
        ]
        if !required.isEmpty { inputSchema["required"] = .array(required.map(JSONValue.string)) }
        if !oneOf.isEmpty { inputSchema["oneOf"] = .array(oneOf) }
        return .object([
            "name": .string(name),
            "description": .string(description),
            "inputSchema": .object(inputSchema),
            "annotations": .object(access.annotations)
        ])
    }

    private static func toolName(_ value: JSONValue) -> String? {
        guard case .object(let object) = value, case .string(let name) = object["name"] else { return nil }
        return name
    }

    private static func successResponse(id: JSONValue, result: JSONValue) -> JSONValue {
        .object(["jsonrpc": .string("2.0"), "id": id, "result": result])
    }

    private static func errorResponse(id: JSONValue, code: Int, message: String) -> JSONValue {
        .object([
            "jsonrpc": .string("2.0"),
            "id": id,
            "error": .object(["code": .integer(code), "message": .string(message)])
        ])
    }

    private static func encode(_ value: JSONValue) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(value)
    }
}


/// Where the app listens for `phone-mcp` and other local clients.
///
/// Inside the App Sandbox the two processes have separate containers, so the
/// socket lives in the app group both are entitled to — named in the app's
/// Info.plist under `PhoneAppGroup`, because the group carries the team
/// identifier and belongs to the build, not the code. Without a group (a
/// development build, or a helper that cannot find its app) the socket stays
/// where it always was, under Application Support.
public enum PhoneControlSocket {
    public static let fileName = "control.sock"
    public static let infoPlistKey = "PhoneAppGroup"

    public static func url() -> URL {
        if let group = appGroupIdentifier(),
           let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) {
            return container.appendingPathComponent(fileName)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Phone", isDirectory: true)
            .appendingPathComponent(fileName)
    }

    /// The group this process is entitled to. Read from the process's own
    /// code signature rather than from a plist on disk: the sandboxed helper
    /// may not read the app bundle it sits in, and the entitlement is the one
    /// thing that is guaranteed to name the group it can actually open.
    public static func appGroupIdentifier() -> String? {
        if let override = ProcessInfo.processInfo.environment["PHONE_APP_GROUP"], !override.isEmpty {
            return override
        }
        if let group = entitledAppGroups().first { return group }
        if let group = Bundle.main.object(forInfoDictionaryKey: infoPlistKey) as? String, !group.isEmpty {
            return group
        }
        return nil
    }

    private static func entitledAppGroups() -> [String] {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(
                task,
                "com.apple.security.application-groups" as CFString,
                nil
              ) else { return [] }
        return (value as? [String]) ?? []
    }
}
