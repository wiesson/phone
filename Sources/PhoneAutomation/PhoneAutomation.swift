import CryptoKit
import Foundation

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
    case callSummary(text: String)

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
        case .callSummary(let text): ["text": .string(text)]
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

public enum ControlCommand: Equatable, Sendable {
    case dial(String, account: String?)
    case assistantCall(String, task: String, account: String?)
    case answer
    case hangup
    case sendDTMF(String)
    case getState
    case getHistory(Int)
    case getLastSummary
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
        case "get_history":
            guard Set(args.keys).isSubset(of: ["limit"]) else {
                return .failure(ControlError(code: "invalid_arguments", message: "get_history accepts only the optional limit argument."))
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
            return .success(.getHistory(limit))
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
        tool("dial", "Dial a phone number or SIP address. Optionally select the outgoing line first via account (label, username, or SIP address of a configured account).", properties: ["number": schema("string"), "account": schema("string")], required: ["number"]),
        tool("assistant_call", "Place an outbound call handled by the AI voice assistant. The task describes what the assistant should accomplish on the call (goal, tone, key details); it navigates IVR menus itself and hands over to the user when a human answers.", properties: ["number": schema("string"), "task": schema("string"), "account": schema("string")], required: ["number", "task"]),
        tool("answer", "Answer the incoming call."),
        tool("hangup", "Hang up the active call."),
        tool("send_dtmf", "Send a DTMF digit during the active call.", properties: ["digit": .object(["type": .string("string"), "pattern": .string("^[0-9*#]$")])], required: ["digit"]),
        tool("get_state", "Get the current registration and call state."),
        tool("get_history", "Get recent call history.", properties: ["limit": .object(["type": .string("integer"), "minimum": .integer(1), "maximum": .integer(50), "default": .integer(20)])]),
        tool("get_last_summary", "Get the most recent local call summary.")
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
                "serverInfo": .object(["name": .string("phone-mcp"), "version": .string("0.1.0")])
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

    private static func tool(
        _ name: String,
        _ description: String,
        properties: [String: JSONValue] = [:],
        required: [String] = []
    ) -> JSONValue {
        var inputSchema: [String: JSONValue] = [
            "type": .string("object"),
            "properties": .object(properties),
            "additionalProperties": .bool(false)
        ]
        if !required.isEmpty { inputSchema["required"] = .array(required.map(JSONValue.string)) }
        return .object([
            "name": .string(name),
            "description": .string(description),
            "inputSchema": .object(inputSchema)
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
