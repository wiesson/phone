import Foundation
import PhoneAutomation
import Testing

@Test func generatesWebhookHMACSignature() {
    let body = Data("The quick brown fox jumps over the lazy dog".utf8)
    #expect(WebhookSignature.hexDigest(body: body, secret: "key") == "f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8")
}

@Test func encodesPhoneEventWebhookShape() throws {
    let timestamp = try #require(ISO8601DateFormatter().date(from: "2026-08-28T09:44:58Z"))
    let event = PhoneEvent(
        id: 17,
        kind: .callHungup(peer: "+4930123456", duration: 12.5, missed: false),
        timestamp: timestamp
    )
    let object = try #require(JSONSerialization.jsonObject(with: event.jsonData()) as? [String: Any])
    let data = try #require(object["data"] as? [String: Any])

    #expect(Set(object.keys) == ["id", "type", "timestamp", "data"])
    #expect(object["id"] as? Int == 17)
    #expect(object["type"] as? String == "call.hungup")
    #expect(object["timestamp"] as? String == "2026-08-28T09:44:58Z")
    #expect(data["peer"] as? String == "+4930123456")
    #expect(data["duration"] as? Double == 12.5)
    #expect(data["missed"] as? Bool == false)
}

@Test func parsesAndValidatesControlRequests() throws {
    let dial = Data(#"{"cmd":"dial","args":{"number":" +4930123456 "}}"#.utf8)
    #expect(try ControlRequestParser.parse(dial).get() == .dial("+4930123456", account: nil))
    let dialAccount = Data(#"{"cmd":"dial","args":{"number":"+4930123456","account":" Privatnummer "}}"#.utf8)
    #expect(try ControlRequestParser.parse(dialAccount).get() == .dial("+4930123456", account: "Privatnummer"))
    let badAccount = Data(#"{"cmd":"dial","args":{"number":"+4930123456","account":"  "}}"#.utf8)
    #expect(throws: ControlError.self) { try ControlRequestParser.parse(badAccount).get() }

    let history = Data(#"{"cmd":"get_history","args":{"limit":7}}"#.utf8)
    #expect(try ControlRequestParser.parse(history).get() == .getHistory(7))

    let injected = Data("{\"cmd\":\"dial\",\"args\":{\"number\":\"123\\n/hangup\"}}".utf8)
    guard case .failure(let injectionError) = ControlRequestParser.parse(injected) else {
        Issue.record("Expected dial injection to be rejected")
        return
    }
    #expect(injectionError.code == "invalid_arguments")

    let extra = Data(#"{"cmd":"answer","args":{"unexpected":true}}"#.utf8)
    guard case .failure(let extraError) = ControlRequestParser.parse(extra) else {
        Issue.record("Expected extra arguments to be rejected")
        return
    }
    #expect(extraError.code == "invalid_arguments")

    let extraTopLevel = Data(#"{"cmd":"answer","args":{},"debug":true}"#.utf8)
    guard case .failure(let topLevelError) = ControlRequestParser.parse(extraTopLevel) else {
        Issue.record("Expected extra top-level fields to be rejected")
        return
    }
    #expect(topLevelError.code == "invalid_request")
}

@Test func returnsMCPInitializeAndToolsListShapes() throws {
    let initialize = Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#.utf8)
    let initializeData = try #require(MCPProtocol.response(for: initialize) { _, _ in .success() })
    guard case .object(let initializeObject) = try JSONDecoder().decode(JSONValue.self, from: initializeData),
          case .object(let initializeResult) = initializeObject["result"],
          case .object(let serverInfo) = initializeResult["serverInfo"] else {
        Issue.record("Invalid initialize response shape")
        return
    }
    #expect(initializeObject["jsonrpc"] == .string("2.0"))
    #expect(initializeObject["id"] == .integer(1))
    #expect(initializeResult["protocolVersion"] == .string("2025-06-18"))
    #expect(serverInfo["name"] == .string("phone-mcp"))
    #expect(initializeResult["capabilities"] == .object(["tools": .object([:])]))

    let list = Data(#"{"jsonrpc":"2.0","id":"tools","method":"tools/list"}"#.utf8)
    let listData = try #require(MCPProtocol.response(for: list) { _, _ in .success() })
    guard case .object(let listObject) = try JSONDecoder().decode(JSONValue.self, from: listData),
          case .object(let listResult) = listObject["result"],
          case .array(let tools) = listResult["tools"] else {
        Issue.record("Invalid tools/list response shape")
        return
    }
    let names = tools.compactMap { tool -> String? in
        guard case .object(let object) = tool, case .string(let name) = object["name"] else { return nil }
        return name
    }
    #expect(names == ["dial", "answer", "hangup", "send_dtmf", "get_state", "get_history", "get_last_summary"])
    for tool in tools {
        guard case .object(let object) = tool, case .object(let schema) = object["inputSchema"] else {
            Issue.record("Tool is missing an input schema")
            continue
        }
        #expect(schema["type"] == .string("object"))
        #expect(schema["additionalProperties"] == .bool(false))
    }
}
