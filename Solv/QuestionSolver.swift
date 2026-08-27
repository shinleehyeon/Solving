import AppKit
import Foundation

enum SolveResult {
    case answer(Int, x: Double, y: Double)
    case notFiveChoice
    case unclear
}

final class QuestionSolver {
    private(set) static var lastEncodeInfo: String = ""

    /// - Parameter needLocation: true면 마우스용 좌표까지. Caps Lock은 false 권장(정답률↑).
    func solveFiveChoice(
        image: NSImage,
        apiKey: String,
        needLocation: Bool
    ) async throws -> SolveResult {
        guard let payload = VisionImageEncoder.encode(image) else {
            throw SolverError.encodeFailed
        }
        Self.lastEncodeInfo = "\(payload.width)x\(payload.height) \(payload.format) \(payload.bytes / 1024)KB"

        let provider = APIProvider.detect(apiKey: apiKey)
        let modelId = SolvModel.current.resolvedId(forOpenRouter: provider == .openRouter)
        let dataURL = "data:\(payload.mime);base64,\(payload.data.base64EncodedString())"

        // 1) 정답만 — 좌표/레이아웃 신경 끄고 내용만
        let answerRaw = try await chat(
            modelId: modelId,
            apiKey: apiKey,
            provider: provider,
            purpose: .answer,
            system: """
            You are a meticulous exam solver (Korean and English).
            Your ONLY job is to pick the correct multiple-choice answer from the screenshot.

            Read the full stem and EVERY option carefully. Prefer reasoning over layout.
            Options may be labeled 1-5, A-E, ①-⑤, etc. Map A→1 … E→5.

            Reply with ONLY compact JSON (no markdown, no other text):
            {"a":2,"why":"short reason in Korean or English"}

            - a must be integer 1..5 when solvable
            - If the image is NOT a clear 5-option MCQ: {"a":"NONE"}
            - If you truly cannot decide: {"a":"UNSURE"}

            Never invent coordinates. Never answer from option position alone.
            """,
            userText: "Solve the 5-choice question. JSON only: {\"a\":N,\"why\":\"...\"}",
            dataURL: dataURL
        )

        let parsedAnswer = Self.parseAnswerOnly(answerRaw)
        switch parsedAnswer {
        case .notFiveChoice: return .notFiveChoice
        case .unclear: return .unclear
        case .answer(let n, let fallbackX, let fallbackY):
            guard needLocation else {
                return .answer(n, x: fallbackX, y: fallbackY)
            }
            // 2) 로컬 OCR로 선택지 bbox 중심 (LLM 좌표보다 정확)
            if let hit = await OptionOCRLocator.locate(answer: n, in: image) {
                Self.lastEncodeInfo += " · \(hit.method) '\(hit.label)'"
                return .answer(n, x: hit.x, y: hit.y)
            }
            return .answer(n, x: fallbackX, y: fallbackY)
        }
    }

    // MARK: - networking

    private enum ChatPurpose {
        case answer
    }

    /// Gemini 2.5 Pro는 thinking 토큰이 max_tokens를 먼저 소진해 content가 비는 경우가 많음.
    private static func isThinkingHeavy(_ modelId: String) -> Bool {
        let id = modelId.lowercased()
        return id.contains("gemini") || id.contains("o1") || id.contains("o3") || id.contains("o4")
    }

    private func chat(
        modelId: String,
        apiKey: String,
        provider: APIProvider,
        purpose: ChatPurpose,
        system: String,
        userText: String,
        dataURL: String
    ) async throws -> String {
        let thinking = Self.isThinkingHeavy(modelId)
        let maxTokens = thinking ? 8192 : 300

        var body: [String: Any] = [
            "model": modelId,
            "max_tokens": maxTokens,
            "temperature": 0,
            "messages": [
                ["role": "system", "content": system],
                [
                    "role": "user",
                    "content": [
                        ["type": "text", "text": userText],
                        [
                            "type": "image_url",
                            "image_url": [
                                "url": dataURL,
                                "detail": "high"
                            ]
                        ]
                    ]
                ]
            ]
        ]

        if provider == .openRouter, thinking {
            body["reasoning"] = [
                "max_tokens": 2048,
                "exclude": true
            ]
        }

        var request = URLRequest(url: provider.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if case .openRouter = provider {
            request.setValue("https://github.com/solv-app", forHTTPHeaderField: "HTTP-Referer")
            request.setValue("Solv", forHTTPHeaderField: "X-Title")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 180

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SolverError.badResponse }
        guard (200...299).contains(http.statusCode) else {
            throw SolverError.api(Self.friendlyError(from: data, status: http.statusCode, provider: provider))
        }
        let parsed = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        let content = parsed.choices.first?.message.content?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if content.isEmpty {
            throw SolverError.api("모델 응답이 비어 있음 (thinking 토큰 한도/모델 오류). Gemini면 다시 시도하거나 다른 모델 사용.")
        }
        return content
    }

    // MARK: - parse

    private static func parseAnswerOnly(_ raw: String) -> SolveResult {
        let cleaned = stripFences(raw)
        if let obj = jsonObject(cleaned) {
            if let s = obj["a"] as? String {
                let u = s.uppercased()
                if u == "NONE" { return .notFiveChoice }
                if u == "UNSURE" { return .unclear }
            }
            if let n = parseAnswerNumber(obj["a"]), (1...5).contains(n) {
                return .answer(n, x: 0.5, y: estimateY(for: n))
            }
        }
        let u = cleaned.uppercased()
        if u.contains("NONE") { return .notFiveChoice }
        if u.contains("UNSURE") { return .unclear }
        // plain "2"
        if let n = parseAnswerNumber(cleaned), (1...5).contains(n) {
            return .answer(n, x: 0.5, y: estimateY(for: n))
        }
        return .unclear
    }

    private static func parseXY(_ raw: String, answer: Int) -> (Double, Double) {
        let cleaned = stripFences(raw)
        if let obj = jsonObject(cleaned),
           let x = number(obj["x"]), let y = number(obj["y"]),
           x <= 1.5, y <= 1.5 {
            return (clamp01(x), clamp01(y))
        }
        return (0.5, estimateY(for: answer))
    }

    private static func stripFences(_ raw: String) -> String {
        raw.replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func jsonObject(_ raw: String) -> [String: Any]? {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // try extract {...}
            if let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}") {
                let sub = String(raw[start...end])
                if let d = sub.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                    return obj
                }
            }
            return nil
        }
        return obj
    }

    private static func parseAnswerNumber(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let d = any as? Double { return Int(d.rounded()) }
        if let s = any as? String {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if let i = Int(t) { return i }
            let map: [Character: Int] = [
                "1": 1, "2": 2, "3": 3, "4": 4, "5": 5,
                "A": 1, "B": 2, "C": 3, "D": 4, "E": 5
            ]
            if let c = t.uppercased().first { return map[c] }
        }
        return nil
    }

    private static func estimateY(for answer: Int) -> Double {
        [0.40, 0.48, 0.56, 0.64, 0.72][max(0, min(4, answer - 1))]
    }

    private static func number(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        if let s = any as? String { return Double(s) }
        return nil
    }

    private static func clamp01(_ v: Double) -> Double { min(1, max(0, v)) }

    private static func friendlyError(from data: Data, status: Int, provider: APIProvider) -> String {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let err = obj["error"] as? [String: Any]
            if let message = (err?["message"] as? String) ?? (obj["message"] as? String) {
                return message
            }
        }
        return "HTTP \(status)"
    }
}

private enum APIProvider: Equatable {
    case openAI, openRouter

    static func detect(apiKey: String) -> APIProvider {
        apiKey.hasPrefix("sk-or-") ? .openRouter : .openAI
    }

    var endpoint: URL {
        switch self {
        case .openAI: return URL(string: "https://api.openai.com/v1/chat/completions")!
        case .openRouter: return URL(string: "https://openrouter.ai/api/v1/chat/completions")!
        }
    }
}

enum SolverError: LocalizedError {
    case encodeFailed, badResponse, api(String)
    var errorDescription: String? {
        switch self {
        case .encodeFailed: return "이미지 인코딩 실패"
        case .badResponse: return "API 응답 오류"
        case .api(let m): return m
        }
    }
}

private struct ChatCompletionResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable { let content: String? }
        let message: Message
    }
    let choices: [Choice]
}
