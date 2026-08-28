import AppKit
import Foundation

enum SolveResult {
    /// 객관식: a=번호, typeText=Raycast에 칠 문자열(보통 "3")
    case mcq(Int, x: Double, y: Double, typeText: String)
    /// 주관식/단답: Raycast에 타이핑할 텍스트
    case open(typeText: String)
    /// 한 화면에 여러 문제 → (문제 내용, 답)
    case multi(items: [(question: String, answer: String)])
    case notQuestion
    case unclear
}

extension SolveResult {
    /// 클립보드: "문제내용 답" 한 줄씩 (번호 매기지 않음 — 객관식과 헷갈림 방지)
    static func clipboardText(from items: [(question: String, answer: String)]) -> String {
        let lines = items.compactMap { item -> String? in
            let q = item.question
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let a = item.answer.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !a.isEmpty else { return nil }
            if q.isEmpty { return a }
            return "\(q) \(a)"
        }
        guard lines.count > 1 else {
            return lines.first ?? ""
        }
        return lines.joined(separator: "\n")
    }
}

final class QuestionSolver {
    private(set) static var lastEncodeInfo: String = ""
    static let maxOptions = 9
    private(set) static var lastOptionCount: Int?

    /// 객관식·주관식 모두 처리. needLocation이면 객관식 OCR 좌표.
    func solve(
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

        let answerRaw = try await chat(
            modelId: modelId,
            apiKey: apiKey,
            provider: provider,
            system: """
            You are a meticulous exam solver (Korean and English).
            Solve every question visible in the screenshot.

            Modes:
            1) Single multiple choice (2~9 options):
               {"mode":"mcq","a":2,"n":4,"t":"2","why":"short"}
               - a = 1-based option index, n = option count, t = short text to type
            2) Single open / short answer:
               {"mode":"open","t":"답 텍스트","why":"short"}
            3) TWO OR MORE questions in the image (numbered problems, several blanks, etc.):
               {"mode":"multi","items":[{"q":"다음 중 vi 편집기를 개발한 인물로 알맞은 것은?","t":"3"},{"q":"문제 내용을 짧게","t":"답"}]}
               - q = short question stem as shown (핵심만, 선택지 나열은 생략)
               - t = final answer only (digit/letter for MCQ, short text for open)
               - One item per question, top-to-bottom / left-to-right order
               - Prefer multi whenever more than one distinct question/answer is visible

            If not a solvable question: {"a":"NONE"}
            If cannot decide: {"a":"UNSURE"}

            Never invent coordinates. Prefer content over layout.
            Do NOT reject MCQ only because option count ≠ 5.
            Reply ONLY compact JSON, no markdown.
            """,
            userText: "Solve all. multi: {\"mode\":\"multi\",\"items\":[{\"q\":\"문제내용?\",\"t\":\"답\"},...]} or single mcq/open.",
            dataURL: dataURL
        )

        let parsed = Self.parse(answerRaw)
        switch parsed {
        case .notQuestion, .unclear, .open, .multi:
            return parsed
        case .mcq(let n, let fx, let fy, let typeText):
            guard needLocation else {
                return .mcq(n, x: fx, y: fy, typeText: typeText)
            }
            let optionCount = Self.lastOptionCount ?? max(n, 4)
            if let hit = await OptionOCRLocator.locate(answer: n, optionCount: optionCount, in: image) {
                Self.lastEncodeInfo += " · \(hit.method) '\(hit.label)'"
                return .mcq(n, x: hit.x, y: hit.y, typeText: typeText)
            }
            return .mcq(n, x: fx, y: fy, typeText: typeText)
        }
    }

    // MARK: - networking

    private static func isThinkingHeavy(_ modelId: String) -> Bool {
        let id = modelId.lowercased()
        return id.contains("gemini") || id.contains("o1") || id.contains("o3") || id.contains("o4")
    }

    private func chat(
        modelId: String,
        apiKey: String,
        provider: APIProvider,
        system: String,
        userText: String,
        dataURL: String
    ) async throws -> String {
        let thinking = Self.isThinkingHeavy(modelId)
        let maxTokens = thinking ? 8192 : 500

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
            throw SolverError.api("모델 응답이 비어 있음. Gemini면 다시 시도하거나 다른 모델 사용.")
        }
        return content
    }

    // MARK: - parse

    private static func parse(_ raw: String) -> SolveResult {
        lastOptionCount = nil
        let cleaned = stripFences(raw)
        if let obj = jsonObject(cleaned) {
            if let s = obj["a"] as? String {
                let u = s.uppercased()
                if u == "NONE" { return .notQuestion }
                if u == "UNSURE" { return .unclear }
            }
            if let mode = (obj["mode"] as? String)?.lowercased() {
                if mode == "multi" {
                    if let items = parseMultiItems(obj), items.count >= 2 {
                        return .multi(items: items)
                    }
                    if let items = parseMultiItems(obj), items.count == 1 {
                        return .open(typeText: items[0].answer)
                    }
                    return .unclear
                }
                if mode == "open" {
                    if let t = stringValue(obj["t"])?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
                        return .open(typeText: t)
                    }
                    return .unclear
                }
            }
            // multi without mode: items array
            if let items = parseMultiItems(obj), items.count >= 2 {
                return .multi(items: items)
            }
            // open without mode but with t and no a
            if obj["a"] == nil, let t = stringValue(obj["t"])?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
                return .open(typeText: t)
            }

            let optionCount = clampOptionCount(parseAnswerNumber(obj["n"]))
            if let n = parseAnswerNumber(obj["a"]) {
                let maxA = optionCount ?? Self.maxOptions
                if (1...maxA).contains(n) {
                    let count = optionCount ?? max(n, 2)
                    lastOptionCount = count
                    let t = stringValue(obj["t"])?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let typeText = (t?.isEmpty == false) ? t! : "\(n)"
                    return .mcq(n, x: 0.5, y: estimateY(for: n, optionCount: count), typeText: typeText)
                }
            }
        }
        let u = cleaned.uppercased()
        if u.contains("UNSURE") { return .unclear }
        if u.contains("NONE") { return .notQuestion }
        if let n = parseAnswerNumber(cleaned), (1...Self.maxOptions).contains(n) {
            lastOptionCount = max(n, 4)
            return .mcq(n, x: 0.5, y: estimateY(for: n, optionCount: lastOptionCount!), typeText: "\(n)")
        }
        return .unclear
    }

    private static func parseMultiItems(_ obj: [String: Any]) -> [(question: String, answer: String)]? {
        if let items = obj["items"] as? [[String: Any]] {
            let parsed: [(question: String, answer: String)] = items.compactMap { item in
                guard let a = stringValue(item["t"])?.trimmingCharacters(in: .whitespacesAndNewlines), !a.isEmpty else {
                    return nil
                }
                let q = (stringValue(item["q"]) ?? stringValue(item["question"]) ?? "")
                    .replacingOccurrences(of: "\n", with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return (question: q, answer: a)
            }
            return parsed.isEmpty ? nil : parsed
        }
        if let items = obj["items"] as? [String] {
            let parsed = items
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .map { (question: "", answer: $0) }
            return parsed.isEmpty ? nil : parsed
        }
        if let arr = obj["answers"] as? [Any] {
            let parsed: [(question: String, answer: String)] = arr.compactMap { any in
                if let dict = any as? [String: Any] {
                    guard let a = stringValue(dict["t"])?.trimmingCharacters(in: .whitespacesAndNewlines), !a.isEmpty else {
                        return nil
                    }
                    let q = (stringValue(dict["q"]) ?? "")
                        .replacingOccurrences(of: "\n", with: " ")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    return (question: q, answer: a)
                }
                if let a = stringValue(any)?.trimmingCharacters(in: .whitespacesAndNewlines), !a.isEmpty {
                    return (question: "", answer: a)
                }
                return nil
            }
            return parsed.isEmpty ? nil : parsed
        }
        return nil
    }

    private static func stringValue(_ any: Any?) -> String? {
        if let s = any as? String { return s }
        if let i = any as? Int { return String(i) }
        if let d = any as? Double { return String(Int(d.rounded())) }
        return nil
    }

    private static func clampOptionCount(_ n: Int?) -> Int? {
        guard let n, (2...Self.maxOptions).contains(n) else { return nil }
        return n
    }

    private static func stripFences(_ raw: String) -> String {
        raw.replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func jsonObject(_ raw: String) -> [String: Any]? {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
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
                "1": 1, "2": 2, "3": 3, "4": 4, "5": 5, "6": 6, "7": 7, "8": 8, "9": 9,
                "A": 1, "B": 2, "C": 3, "D": 4, "E": 5, "F": 6, "G": 7, "H": 8, "I": 9
            ]
            if let c = t.uppercased().first { return map[c] }
        }
        return nil
    }

    private static func estimateY(for answer: Int, optionCount: Int) -> Double {
        let count = max(2, min(Self.maxOptions, optionCount))
        let idx = max(0, min(count - 1, answer - 1))
        let top = 0.34
        let bottom = 0.78
        if count == 1 { return 0.5 }
        return top + (bottom - top) * Double(idx) / Double(count - 1)
    }

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
