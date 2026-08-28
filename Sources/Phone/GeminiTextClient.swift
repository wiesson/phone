import Foundation

enum GeminiGenerateContentRequestBuilder {
    static func request(
        model: String,
        apiKey: String,
        systemInstruction: String,
        prompt: String
    ) throws -> URLRequest {
        guard let url = URL(
            string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent"
        ) else {
            throw GeminiTextClient.Error.invalidEndpoint
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.timeoutInterval = 20
        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": systemInstruction]]],
            "contents": [["role": "user", "parts": [["text": prompt]]]]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }
}

enum GeminiTextClient {
    static let defaultModel = "gemini-3.6-flash"

    enum Error: LocalizedError {
        case invalidEndpoint

        var errorDescription: String? {
            switch self {
            case .invalidEndpoint: "The Gemini endpoint is invalid."
            }
        }
    }

    static func generate(
        prompt: String,
        systemInstruction: String,
        model: String = defaultModel,
        apiKey: String,
        errorDomain: String = "GeminiText"
    ) async throws -> String {
        let request = try GeminiGenerateContentRequestBuilder.request(
            model: model,
            apiKey: apiKey,
            systemInstruction: systemInstruction,
            prompt: prompt
        )
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw NSError(
                domain: errorDomain,
                code: status,
                userInfo: [NSLocalizedDescriptionKey: "HTTP \(status)"]
            )
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = object["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let text = parts.compactMap({ $0["text"] as? String }).first,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NSError(
                domain: errorDomain,
                code: 0,
                userInfo: [NSLocalizedDescriptionKey: "Empty response"]
            )
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

let assistantCallPlanSystemInstruction = """
Du formulierst aus einem frei beschriebenen Anliegen einen knappen, eindeutigen Auftrag für einen deutschsprachigen Sprachassistenten.
"""

func assistantCallPlanPrompt(intent: String) -> String {
    """
    Erstelle auf Deutsch ausschließlich die aufgabenspezifische Kurzbeschreibung für einen Sprachassistenten, der diesen Anruf führt.
    Nenne das Ziel und alle vorhandenen Eckdaten wie Artikel, Mengen, Zeiten, Namen und Nummern. Der gewünschte Ton ist freundlich, natürlich und knapp. Rückfragen sind erlaubt; fehlende Angaben dürfen nicht erfunden werden.

    Gib nur diesen konkreten Auftrag aus. Füge keine allgemeinen Regeln zum Telefonieren hinzu, insbesondere nichts zum Gesprächsbeginn, Warten auf die angerufene Person, IVR-/DTMF-Bedienung oder zur Übergabe. Diese Regeln werden später automatisch ergänzt.

    Anliegen der Nutzerin oder des Nutzers:
    \(intent.trimmingCharacters(in: .whitespacesAndNewlines))
    """
}
