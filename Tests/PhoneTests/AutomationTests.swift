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

    let assistantCall = Data(#"{"cmd":"assistant_call","args":{"number":"+4930123456","task":" Bestelle eine Pizza. ","account":"sipgate"}}"#.utf8)
    #expect(try ControlRequestParser.parse(assistantCall).get() == .assistantCall("+4930123456", task: "Bestelle eine Pizza.", account: "sipgate"))
    let emptyTask = Data(#"{"cmd":"assistant_call","args":{"number":"+4930123456","task":"  "}}"#.utf8)
    #expect(throws: ControlError.self) { try ControlRequestParser.parse(emptyTask).get() }

    let history = Data(#"{"cmd":"get_history","args":{"limit":7}}"#.utf8)
    #expect(try ControlRequestParser.parse(history).get() == .getHistory(limit: 7, query: nil))

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
    #expect(names == [
        "dial", "assistant_call", "answer", "hangup", "send_dtmf", "get_state",
        "get_history", "get_last_summary", "list_lines",
        "list_provisioning_endpoints", "provisioning_status", "provision_line",
        "create_line", "update_line", "delete_line", "select_active_line",
        "get_registration_status", "set_line_enabled", "set_line_profile",
        "set_line_prompt", "create_assistant_profile", "update_assistant_profile",
        "delete_assistant_profile", "list_assistant_profiles", "set_line_answer_mode",
        "set_line_business_hours", "find_contact", "get_transcript"
    ])
    for tool in tools {
        guard case .object(let object) = tool, case .object(let schema) = object["inputSchema"] else {
            Issue.record("Tool is missing an input schema")
            continue
        }
        #expect(schema["type"] == .string("object"))
        #expect(schema["additionalProperties"] == .bool(false))
    }

    for name in ["create_line", "update_line"] {
        let tool = try #require(tools.first { tool in
            guard case .object(let object) = tool else { return false }
            return object["name"] == .string(name)
        })
        guard case .object(let object) = tool,
              case .object(let inputSchema) = object["inputSchema"],
              case .object(let properties) = inputSchema["properties"],
              case .object(let password) = properties["password"] else {
            Issue.record("\(name) must declare an input-only password")
            continue
        }
        #expect(password["type"] == .string("string"))
        #expect(password["writeOnly"] == .bool(true))
    }

    let sipgateProvision = try #require(tools.first { tool in
        guard case .object(let object) = tool else { return false }
        return object["name"] == .string("provision_line")
    })
    guard case .object(let provisionObject) = sipgateProvision,
          case .object(let provisionSchema) = provisionObject["inputSchema"],
          case .object(let provisionProperties) = provisionSchema["properties"] else {
        Issue.record("provision_line must have an input schema")
        return
    }
    #expect(provisionProperties["password"] == nil)
    #expect(provisionProperties["device_id"] == .object(["type": .string("string")]))
    #expect(provisionProperties["create_device"] == .object(["type": .string("boolean")]))
    #expect(provisionProperties["rotate_password"] == .object([
        "type": .string("boolean"),
        "default": .bool(false)
    ]))
}

@Test func transcriptCommandTakesAnOptionalCallIdentifier() throws {
    let bare = Data(#"{"cmd":"get_transcript","args":{}}"#.utf8)
    #expect(try ControlRequestParser.parse(bare).get() == .getTranscript(callID: nil, limit: 200))

    let identified = Data(#"{"cmd":"get_transcript","args":{"call_id":" abc "}}"#.utf8)
    #expect(try ControlRequestParser.parse(identified).get() == .getTranscript(callID: "abc", limit: 200))

    let empty = Data(#"{"cmd":"get_transcript","args":{"call_id":"  "}}"#.utf8)
    guard case .failure = ControlRequestParser.parse(empty) else {
        Issue.record("an empty call_id must be rejected")
        return
    }

    let unknown = Data(#"{"cmd":"get_transcript","args":{"other":"x"}}"#.utf8)
    guard case .failure = ControlRequestParser.parse(unknown) else {
        Issue.record("an unknown argument must be rejected")
        return
    }
}

@Test func lineCommandsRequireTheArgumentsTheirDescriptionsPromise() throws {
    let list = Data(#"{"cmd":"list_lines","args":{}}"#.utf8)
    #expect(try ControlRequestParser.parse(list).get() == .listLines)

    let enable = Data(#"{"cmd":"set_line_enabled","args":{"line":" nordwerk Test ","enabled":false}}"#.utf8)
    #expect(try ControlRequestParser.parse(enable).get() == .setLineEnabled(line: "nordwerk Test", enabled: false))

    // A missing or non-boolean flag must not be guessed at: it decides whether
    // a line stops receiving calls.
    for body in [
        #"{"cmd":"set_line_enabled","args":{"line":"a"}}"#,
        #"{"cmd":"set_line_enabled","args":{"line":"a","enabled":"yes"}}"#,
        #"{"cmd":"set_line_enabled","args":{"line":"","enabled":true}}"#
    ] {
        guard case .failure = ControlRequestParser.parse(Data(body.utf8)) else {
            Issue.record("must reject: \(body)")
            return
        }
    }

    let profile = Data(#"{"cmd":"set_line_profile","args":{"line":"TM Travel","profile":"Mia · Take Memories"}}"#.utf8)
    #expect(try ControlRequestParser.parse(profile).get() == .setLineProfile(line: "TM Travel", profile: "Mia · Take Memories"))
}

@Test func provisioningCommandsPreservePasswordsOnlyAsInputs() throws {
    let create = Data(#"{"cmd":"create_line","args":{"provider":"telekom","username":" +49123 ","password":"  private value  ","label":" Home "}}"#.utf8)
    #expect(try ControlRequestParser.parse(create).get() == .createLine(ControlCreateLine(
        provider: "telekom",
        username: "+49123",
        password: "  private value  ",
        domain: nil,
        outboundProxy: nil,
        stunServer: nil,
        mediaEncryption: nil,
        label: "Home",
        sipDisplayName: nil,
        outboundCallerID: nil
    )))

    let update = Data(#"{"cmd":"update_line","args":{"line":" Home ","domain":"sip.example.test"}}"#.utf8)
    #expect(try ControlRequestParser.parse(update).get() == .updateLine(ControlUpdateLine(
        line: "Home",
        provider: nil,
        password: nil,
        domain: "sip.example.test",
        outboundProxy: nil,
        stunServer: nil,
        mediaEncryption: nil,
        label: nil,
        sipDisplayName: nil,
        outboundCallerID: nil
    )))

    let existingSipgate = Data(#"{"cmd":"provision_line","args":{"device_id":" e0 ","label":" Desk ","rotate_password":true}}"#.utf8)
    #expect(try ControlRequestParser.parse(existingSipgate).get() == .provisionLine(
        ControlProvisionLine(
            deviceID: "e0",
            createDevice: false,
            alias: nil,
            label: "Desk",
            rotatePassword: true
        )
    ))

    let newSipgate = Data(#"{"cmd":"provision_line","args":{"create_device":true,"alias":" Phone Mac "}}"#.utf8)
    #expect(try ControlRequestParser.parse(newSipgate).get() == .provisionLine(
        ControlProvisionLine(
            deviceID: nil,
            createDevice: true,
            alias: "Phone Mac",
            label: nil,
            rotatePassword: false
        )
    ))

    #expect(try ControlRequestParser.parse(Data(#"{"cmd":"list_provisioning_endpoints","args":{}}"#.utf8)).get() == .listProvisioningEndpoints)
    #expect(try ControlRequestParser.parse(Data(#"{"cmd":"provisioning_status","args":{}}"#.utf8)).get() == .provisioningStatus)

    for body in [
        #"{"cmd":"create_line","args":{"provider":"unknown","username":"u","password":"p"}}"#,
        #"{"cmd":"create_line","args":{"username":"u"}}"#,
        #"{"cmd":"update_line","args":{"line":"Home"}}"#,
        #"{"cmd":"provision_line","args":{}}"#,
        #"{"cmd":"provision_line","args":{"create_device":false}}"#,
        #"{"cmd":"provision_line","args":{"device_id":"e0","create_device":true}}"#,
        #"{"cmd":"provision_line","args":{"device_id":"e0","create_device":false}}"#,
        #"{"cmd":"provision_line","args":{"device_id":"e0","alias":"New"}}"#,
        #"{"cmd":"provision_line","args":{"create_device":"yes"}}"#
    ] {
        guard case .failure = ControlRequestParser.parse(Data(body.utf8)) else {
            Issue.record("must reject: \(body)")
            return
        }
    }
}

@Test func assistantConfigurationCommandsRoundTripTheirWireArguments() throws {
    let answerMode = Data(#"{"cmd":"set_line_answer_mode","args":{"line":" Work ","mode":"outside_business_hours","answer_delay_seconds":45}}"#.utf8)
    #expect(try ControlRequestParser.parse(answerMode).get() == .setLineAnswerMode(
        line: "Work",
        mode: .outsideBusinessHours,
        answerDelaySeconds: 45
    ))

    let hours = Data(#"{"cmd":"set_line_business_hours","args":{"line":"Work","weekdays":{"open":true,"start_minute":510,"end_minute":1050},"weekend":{"open":false,"start_minute":600,"end_minute":840}}}"#.utf8)
    #expect(try ControlRequestParser.parse(hours).get() == .setLineBusinessHours(
        line: "Work",
        weekdays: .init(open: true, startMinute: 510, endMinute: 1050),
        weekend: .init(open: false, startMinute: 600, endMinute: 840)
    ))

    let prompt = Data(#"{"cmd":"set_line_prompt","args":{"line":"Work","instructions":" Answer as support. ","context_data":" Tier: gold "}}"#.utf8)
    #expect(try ControlRequestParser.parse(prompt).get() == .setLinePrompt(
        line: "Work",
        instructions: "Answer as support.",
        contextData: "Tier: gold"
    ))
}

@Test func historySearchIsOptionalAndValidated() throws {
    let plain = Data(#"{"cmd":"get_history","args":{"limit":3}}"#.utf8)
    #expect(try ControlRequestParser.parse(plain).get() == .getHistory(limit: 3, query: nil))

    let searched = Data(#"{"cmd":"get_history","args":{"query":" Oman "}}"#.utf8)
    #expect(try ControlRequestParser.parse(searched).get() == .getHistory(limit: 20, query: "Oman"))

    let blank = Data(#"{"cmd":"get_history","args":{"query":"  "}}"#.utf8)
    guard case .failure = ControlRequestParser.parse(blank) else {
        Issue.record("a blank query must be rejected rather than returning everything")
        return
    }
}

@Test func contactLookupNeedsAName() throws {
    let found = Data(#"{"cmd":"find_contact","args":{"name":" Heike "}}"#.utf8)
    #expect(try ControlRequestParser.parse(found).get() == .findContact("Heike"))

    guard case .failure = ControlRequestParser.parse(Data(#"{"cmd":"find_contact","args":{}}"#.utf8)) else {
        Issue.record("find_contact without a name must be rejected")
        return
    }
}

@Test func transcriptPagingIsBoundedSoTheReplyStaysReadable() throws {
    // The control client reads at most 64 KiB, so an unbounded transcript would
    // come back as truncated, invalid JSON.
    let paged = Data(#"{"cmd":"get_transcript","args":{"limit":10}}"#.utf8)
    #expect(try ControlRequestParser.parse(paged).get() == .getTranscript(callID: nil, limit: 10))

    for body in [
        #"{"cmd":"get_transcript","args":{"limit":0}}"#,
        #"{"cmd":"get_transcript","args":{"limit":501}}"#,
        #"{"cmd":"get_transcript","args":{"limit":"20"}}"#
    ] {
        guard case .failure = ControlRequestParser.parse(Data(body.utf8)) else {
            Issue.record("must reject: \(body)")
            return
        }
    }
}

@Test func everyToolDeclaresHowDangerousItIs() throws {
    // A client decides from these hints what to run without asking. dial rings
    // a real phone; get_history reads a local database.
    var byName: [String: [String: JSONValue]] = [:]
    for tool in MCPProtocol.tools {
        guard case .object(let object) = tool,
              case .string(let name)? = object["name"],
              case .object(let annotations)? = object["annotations"] else {
            Issue.record("a tool is missing its annotations")
            return
        }
        byName[name] = annotations
    }

    for name in ["dial", "assistant_call", "answer", "hangup", "send_dtmf"] {
        #expect(byName[name]?["readOnlyHint"] == .bool(false), "\(name) is not read-only")
        #expect(byName[name]?["idempotentHint"] == .bool(false), "\(name) twice means twice")
        #expect(byName[name]?["openWorldHint"] == .bool(true), "\(name) reaches the network")
    }
    for name in [
        "get_state", "get_history", "get_last_summary", "get_transcript", "list_lines",
        "provisioning_status", "get_registration_status", "list_assistant_profiles", "find_contact"
    ] {
        #expect(byName[name]?["readOnlyHint"] == .bool(true), "\(name) must be read-only")
        #expect(byName[name]?["destructiveHint"] == .bool(false), "\(name) must not be destructive")
    }
    for name in [
        "create_line", "update_line", "delete_line", "select_active_line",
        "set_line_enabled", "set_line_profile", "set_line_prompt", "create_assistant_profile",
        "update_assistant_profile", "delete_assistant_profile", "set_line_answer_mode",
        "set_line_business_hours"
    ] {
        #expect(byName[name]?["readOnlyHint"] == .bool(false), "\(name) changes configuration")
        #expect(byName[name]?["idempotentHint"] == .bool(true), "\(name) settles on the same state")
    }
    #expect(byName["list_provisioning_endpoints"]?["readOnlyHint"] == .bool(true))
    #expect(byName["list_provisioning_endpoints"]?["destructiveHint"] == .bool(false))
    #expect(byName["list_provisioning_endpoints"]?["openWorldHint"] == .bool(true))
    #expect(byName["provision_line"]?["readOnlyHint"] == .bool(false))
    #expect(byName["provision_line"]?["idempotentHint"] == .bool(false))
    #expect(byName["provision_line"]?["openWorldHint"] == .bool(true))
}

@Test func provisioningToolsWarnAboutWhatTheyChangeAtTheProvider() throws {
    var byName: [String: [String: JSONValue]] = [:]
    for tool in MCPProtocol.tools {
        guard case .object(let object) = tool, case .string(let name)? = object["name"] else { continue }
        byName[name] = object
    }

    guard case .string(let provision)? = byName["provision_line"]?["description"] else {
        Issue.record("provision_line must describe itself")
        return
    }
    // An agent cannot infer any of these from a schema, and each one has a
    // consequence at the provider that outlives the call.
    #expect(provision.contains("rotate_password"))
    #expect(provision.lowercased().contains("invalidates"))
    #expect(provision.lowercased().contains("online"))
    #expect(provision.contains("alias"))

    // The exclusive or is enforceable only if it is in the schema.
    guard case .object(let schema)? = byName["provision_line"]?["inputSchema"],
          case .array(let alternatives)? = schema["oneOf"] else {
        Issue.record("device_id and create_device must exclude each other in the schema")
        return
    }
    #expect(alternatives.count == 2)
}
