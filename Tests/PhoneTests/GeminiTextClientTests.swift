import Foundation
import Testing
@testable import Phone

@Test func composesGermanAssistantCallPlanPrompt() {
    let intent = "  2 Pizzen bei Luigi bestellen, Abholung 19 Uhr  "
    let prompt = assistantCallPlanPrompt(intent: intent)

    #expect(prompt.contains("2 Pizzen bei Luigi bestellen, Abholung 19 Uhr"))
    #expect(prompt.contains("auf Deutsch"))
    #expect(prompt.contains("ausschließlich die aufgabenspezifische Kurzbeschreibung"))
    #expect(prompt.contains("freundlich, natürlich und knapp"))
    #expect(prompt.contains("Rückfragen sind erlaubt"))
    #expect(prompt.contains("nicht erfunden"))
    #expect(prompt.contains("keine allgemeinen Regeln zum Telefonieren"))
    #expect(prompt.contains("werden später automatisch ergänzt"))
}

@Test func buildsGeminiGenerateContentRequest() throws {
    let request = try GeminiGenerateContentRequestBuilder.request(
        model: "gemini-test-model",
        apiKey: "test-api-key",
        systemInstruction: "System instruction",
        prompt: "User prompt"
    )

    #expect(request.url?.absoluteString == "https://generativelanguage.googleapis.com/v1beta/models/gemini-test-model:generateContent")
    #expect(request.httpMethod == "POST")
    #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == "test-api-key")
    #expect(request.timeoutInterval == 20)

    let data = try #require(request.httpBody)
    let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let systemInstruction = try #require(body["systemInstruction"] as? [String: Any])
    let systemParts = try #require(systemInstruction["parts"] as? [[String: Any]])
    #expect(systemParts.first?["text"] as? String == "System instruction")

    let contents = try #require(body["contents"] as? [[String: Any]])
    let content = try #require(contents.first)
    #expect(content["role"] as? String == "user")
    let parts = try #require(content["parts"] as? [[String: Any]])
    #expect(parts.first?["text"] as? String == "User prompt")
}
