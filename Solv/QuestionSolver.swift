import AppKit
import Foundation

enum SolveResult {
    struct Choice: Equatable {
        var index: Int
        var text: String
        var note: String
        var isCorrect: Bool
    }

    struct MultiItem: Equatable {
        var question: String
        var answer: String
        var why: String
        var choices: [Choice]
        /// 이미지 좌상단 원점 정규화 좌표 (마우스용, OCR)
        var x: Double?
        var y: Double?

        var answerNumber: Int? { answerNumbers.first }

        /// 복수 선택 포함: "1,3" → [1,3], 선지 ok 여러 개도 반영.
        var answerNumbers: [Int] {
            let fromText = Self.parseAnswerNumbers(answer)
            if !fromText.isEmpty { return fromText }
            let fromChoices = choices
                .filter(\.isCorrect)
                .map(\.index)
                .filter { (1...QuestionSolver.maxOptions).contains($0) }
            return Self.uniquePreserveOrder(fromChoices)
        }

        /// Caps/손바닥용: "3", "②", "답 2번", "정답: C" 등에서 1~9 추출.
        static func parseAnswerNumber(_ raw: String) -> Int? {
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { return nil }

            let circled: [Character: Int] = [
                "①": 1, "②": 2, "③": 3, "④": 4, "⑤": 5,
                "⑥": 6, "⑦": 7, "⑧": 8, "⑨": 9,
                "➀": 1, "➁": 2, "➂": 3, "➃": 4, "➄": 5,
                "⑴": 1, "⑵": 2, "⑶": 3, "⑷": 4, "⑸": 5,
                "⒈": 1, "⒉": 2, "⒊": 3, "⒋": 4, "⒌": 5
            ]
            let fullwidth: [Character: Int] = [
                "１": 1, "２": 2, "３": 3, "４": 4, "５": 5,
                "６": 6, "７": 7, "８": 8, "９": 9
            ]
            let letters: [Character: Int] = [
                "A": 1, "B": 2, "C": 3, "D": 4, "E": 5,
                "a": 1, "b": 2, "c": 3, "d": 4, "e": 5
            ]
            let korean: [String: Int] = [
                "일": 1, "이": 2, "삼": 3, "사": 4, "오": 5,
                "하나": 1, "둘": 2, "셋": 3, "넷": 4, "다섯": 5,
                "첫번째": 1, "첫 번째": 1, "두번째": 2, "두 번째": 2,
                "세번째": 3, "세 번째": 3, "네번째": 4, "네 번째": 4,
                "다섯번째": 5, "다섯 번째": 5
            ]

            func valid(_ n: Int?) -> Int? {
                guard let n, (1...QuestionSolver.maxOptions).contains(n) else { return nil }
                return n
            }

            if let i = Int(t) { return valid(i) }
            if t.count == 1, let c = t.first {
                if let n = circled[c] ?? fullwidth[c] ?? letters[c] { return valid(n) }
            }
            for (k, v) in korean where t == k || t.hasPrefix(k + "번") || t.hasPrefix(k + " ") {
                return valid(v)
            }

            // "정답: 3", "답은 2번", "answer: 4" — 라벨 뒤 숫자 우선
            let labeled = #"(?:정답|답|answer|ans|correct)\s*[:：=]?\s*([1-9①②③④⑤⑥⑦⑧⑨１-９]|[A-Ea-e])"#
            if let n = firstToken(in: t, pattern: labeled, circled: circled, fullwidth: fullwidth, letters: letters) {
                return valid(n)
            }

            // "2번", "(3)", "【4】", "3."
            let numbered = #"([1-9①②③④⑤⑥⑦⑧⑨１-９])\s*(?:번|\)|］|】|\.|．)?"#
            if let n = firstToken(in: t, pattern: numbered, circled: circled, fullwidth: fullwidth, letters: letters) {
                return valid(n)
            }

            // 단독 A–E만 (단어 속 B/C 오인 방지). "C)", "B번"
            let letterOnly = #"(?<![A-Za-z])([A-Ea-e])(?:\s*(?:번|\)|\.|．))?(?![A-Za-z])"#
            if let n = firstToken(in: t, pattern: letterOnly, circled: circled, fullwidth: fullwidth, letters: letters) {
                return valid(n)
            }

            // 문자열에 원문자만 있는 경우
            for ch in t {
                if let n = circled[ch] ?? fullwidth[ch] { return valid(n) }
            }

            // 최후: 단독 1–9 숫자 (연도·점수 오인 줄이려 공백/구두점 경계)
            let loneDigit = #"(?<![0-9])([1-9])(?![0-9])"#
            if let n = firstToken(in: t, pattern: loneDigit, circled: circled, fullwidth: fullwidth, letters: letters) {
                return valid(n)
            }
            return nil
        }

        /// 복수 정답: "1,3", "1·3", "[1, 3]", "①③" → [1,3] (등장 순, 중복 제거)
        static func parseAnswerNumbers(_ raw: String) -> [Int] {
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { return [] }

            // JSON 배열 문자열 "[1,3]"
            if t.hasPrefix("["), t.hasSuffix("]"),
               let data = t.data(using: .utf8),
               let arr = try? JSONSerialization.jsonObject(with: data) as? [Any] {
                let nums = arr.compactMap { any -> Int? in
                    if let i = any as? Int { return (1...QuestionSolver.maxOptions).contains(i) ? i : nil }
                    if let d = any as? Double {
                        let i = Int(d.rounded())
                        return (1...QuestionSolver.maxOptions).contains(i) ? i : nil
                    }
                    return parseAnswerNumber(String(describing: any))
                }
                if !nums.isEmpty { return uniquePreserveOrder(nums) }
            }

            let separators = CharacterSet(charactersIn: ",、/·•+|&~～")
            var parts = t.components(separatedBy: separators)
            parts = parts.flatMap { $0.components(separatedBy: "와") }
            parts = parts.flatMap { $0.components(separatedBy: "과") }
            parts = parts.flatMap { $0.components(separatedBy: "and") }
            parts = parts.flatMap { $0.components(separatedBy: "그리고") }

            var fromParts: [Int] = []
            for part in parts {
                let p = part.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !p.isEmpty else { continue }
                if let n = parseAnswerNumber(p) { fromParts.append(n) }
            }
            if fromParts.count >= 2 { return uniquePreserveOrder(fromParts) }

            // "①③", "13번"이 아니라 원문자 연속 / 숫자 토큰 전부
            var scanned: [Int] = []
            let circled: [Character: Int] = [
                "①": 1, "②": 2, "③": 3, "④": 4, "⑤": 5,
                "⑥": 6, "⑦": 7, "⑧": 8, "⑨": 9
            ]
            for ch in t {
                if let n = circled[ch] { scanned.append(n) }
            }
            if scanned.count >= 2 { return uniquePreserveOrder(scanned) }

            let digitPattern = #"(?<![0-9])([1-9])(?![0-9])"#
            if let regex = try? NSRegularExpression(pattern: digitPattern) {
                let ns = NSRange(t.startIndex..., in: t)
                for match in regex.matches(in: t, range: ns) {
                    if let r = Range(match.range(at: 1), in: t), let n = Int(t[r]) {
                        scanned.append(n)
                    }
                }
            }
            if scanned.count >= 2 { return uniquePreserveOrder(scanned) }

            if fromParts.count == 1 { return fromParts }
            if let n = parseAnswerNumber(t) { return [n] }
            return uniquePreserveOrder(scanned)
        }

        static func uniquePreserveOrder(_ nums: [Int]) -> [Int] {
            var seen = Set<Int>()
            var out: [Int] = []
            for n in nums where (1...QuestionSolver.maxOptions).contains(n) && seen.insert(n).inserted {
                out.append(n)
            }
            return out
        }

        private static func firstToken(
            in t: String,
            pattern: String,
            circled: [Character: Int],
            fullwidth: [Character: Int],
            letters: [Character: Int]
        ) -> Int? {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = regex.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)),
                  match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: t) else { return nil }
            let token = String(t[range])
            if let i = Int(token) { return i }
            if let c = token.first {
                return circled[c] ?? fullwidth[c] ?? letters[c]
            }
            return nil
        }
    }

    /// 객관식: answers=[3] 또는 복수선택 [1,3]. typeText는 "3" / "1,3"
    case mcq(answers: [Int], x: Double, y: Double, typeText: String, why: String, choices: [Choice])
    /// 주관식/단답: Raycast에 타이핑할 텍스트
    case open(typeText: String, why: String)
    /// 한 화면에 여러 문제
    case multi(items: [MultiItem])
    case notQuestion
    case unclear
}

extension SolveResult {
    static func clipboardAnswer(
        _ answer: String,
        why: String,
        choices: [Choice] = [],
        includeWhy: Bool
    ) -> String {
        let a = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        let w = why.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !a.isEmpty else { return "" }
        guard includeWhy else { return a }

        var parts: [String] = ["정답: \(a)"]
        if !choices.isEmpty {
            parts.append("")
            parts.append("선지:")
            for c in choices.sorted(by: { $0.index < $1.index }) {
                let body = c.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let note = c.note.trimmingCharacters(in: .whitespacesAndNewlines)
                let mark = c.isCorrect ? "정답" : "오답"
                if body.isEmpty && note.isEmpty {
                    parts.append("\(c.index). (\(mark))")
                } else if note.isEmpty {
                    parts.append("\(c.index). \(body)\(c.isCorrect ? " ← 정답" : "")")
                } else if body.isEmpty {
                    parts.append("\(c.index). \(mark) — \(note)")
                } else {
                    parts.append("\(c.index). \(body) — \(mark): \(note)")
                }
            }
        }
        if !w.isEmpty {
            parts.append("")
            parts.append("설명: \(w)")
        }
        return parts.joined(separator: "\n")
    }

    /// 클립보드: includeWhy면 문제·정답·선지·설명.
    static func clipboardText(from items: [MultiItem], includeWhy: Bool) -> String {
        let blocks = items.compactMap { item -> String? in
            let q = item.question
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let a = item.answer.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !a.isEmpty else { return nil }
            if !includeWhy {
                return q.isEmpty ? a : "\(q) \(a)"
            }
            let body = clipboardAnswer(a, why: item.why, choices: item.choices, includeWhy: true)
            if q.isEmpty { return body }
            return "\(q)\n\(body)"
        }
        guard blocks.count > 1 else {
            return blocks.first ?? ""
        }
        return blocks.joined(separator: "\n\n————\n\n")
    }
}

final class QuestionSolver {
    private(set) static var lastEncodeInfo: String = ""
    private(set) static var lastLatencyMs: Int = 0
    static let maxOptions = 9
    private(set) static var lastOptionCount: Int?

    /// 객관식·주관식 모두 처리. needLocation이면 객관식 OCR 좌표.
    /// needExplanation이면 why를 2~4문장으로 길게.
    func solve(
        image: NSImage,
        apiKey: String,
        needLocation: Bool,
        needExplanation: Bool = false,
        precise: Bool = false
    ) async throws -> SolveResult {
        let t0 = Date()
        // API용은 작게, OCR은 원본(고해상도) — 업로드·비전 토큰이 제일 느림
        guard let payload = VisionImageEncoder.encodeForAPI(image, fast: !needExplanation && !precise) else {
            throw SolverError.encodeFailed
        }
        Self.lastEncodeInfo = "\(payload.width)x\(payload.height) \(payload.format) \(payload.bytes / 1024)KB"

        let apiKey = KeychainStore.normalizeAPIKey(apiKey)
        let provider = APIProvider.detect(apiKey: apiKey)
        let selected = await MainActor.run { SolvModelCatalog.shared.selectedId }
        let modelId = SolvModelCatalog.resolvedId(
            openRouterId: selected,
            forOpenRouter: provider == .openRouter
        )
        let dataURL = "data:\(payload.mime);base64,\(payload.data.base64EncodedString())"

        var system: String
        let userText: String
        if needExplanation {
            system = """
            Exam solver (KO/EN). JSON only.
            mcq: {"mode":"mcq","a":N,"n":C,"t":"...","why":"...","opts":[{"i":1,"t":"...","ok":false,"note":"..."},...]}
            multi-select ONE question (pick all that apply): a=[1,3], t="1,3" (numbers only, ascending).
            open: {"mode":"open","t":"...","why":"..."}
            multi: {"mode":"multi","items":[{"q":"...","a":N,"t":"N","why":"...","opts":[...]}]}
            For MCQ a/t = choice number(s) 1-9 only (not choice text). Multi-select uses array a.
            why=2-4 Korean sentences. opts=every choice. NONE/UNSURE if needed.
            """
            userText = "Solve. Korean why + all opts for MCQ."
        } else {
            system = """
            Exam solver. JSON only, no markdown.
            mcq: {"mode":"mcq","a":N,"n":C,"t":"N"}
            multi-select (one question, several correct): {"mode":"mcq","a":[1,3],"n":C,"t":"1,3"}
            open: {"mode":"open","t":"answer"}
            multi: {"mode":"multi","items":[{"q":"stem?","a":N,"t":"N"},...]} top-to-bottom
            MCQ: a/t = choice number 1-9 ONLY. Multi-select: a array + t="1,3". Never choice text.
            Prefer multi if 2+ separate questions. NONE/UNSURE if needed. No coords.
            """
            userText = "Solve. Compact JSON."
        }

        if precise {
            system += """

            Take your time: reason step by step before answering. Read every character of code, tables and choices exactly.
            Judge each choice true/false on its own, then pick. If the stem says how many to choose, return exactly that many.
            SQL rules: comparisons with NULL are UNKNOWN; NOT IN with a NULL in the list returns no rows; COUNT(col) skips NULL, COUNT(*) does not;
            DISTINCT/GROUP BY treat NULLs as equal; outer join: condition in ON keeps unmatched rows, in WHERE removes them;
            with GROUP BY, SELECT/HAVING/ORDER BY may use only grouped columns or aggregates; a column alias works in ORDER BY (and GROUP BY in PostgreSQL) but not in WHERE/HAVING;
            a bare ORDER BY name prefers the output alias, inside an expression it means the input column; ROW_NUMBER is unique, RANK repeats on ties;
            UNION removes duplicates, UNION ALL keeps them. Use the DB dialect named in the question if any.
            """
        }

        // OCR을 API와 동시에 돌려 마우스 모드 대기 시간 단축
        async let ocrPrep: OptionOCRLocator.Prepared? = needLocation
            ? OptionOCRLocator.prepare(image)
            : nil

        let answerRaw = try await chat(
            modelId: modelId,
            apiKey: apiKey,
            provider: provider,
            needExplanation: needExplanation,
            precise: precise,
            system: system,
            userText: userText,
            dataURL: dataURL
        )
        let prepared = await ocrPrep

        Self.lastLatencyMs = Int(Date().timeIntervalSince(t0) * 1000)
        Self.lastEncodeInfo += " · \(Self.lastLatencyMs)ms"

        let parsed = Self.parse(answerRaw)
        switch parsed {
        case .notQuestion, .unclear, .open:
            return parsed
        case .multi(let items):
            guard needLocation else { return .multi(items: items) }
            return .multi(items: Self.enrichMultiLocations(items, prepared: prepared))
        case .mcq(let answers, let fx, let fy, let typeText, let why, let choices):
            let primary = answers.first ?? 1
            guard needLocation else {
                return .mcq(answers: answers, x: fx, y: fy, typeText: typeText, why: why, choices: choices)
            }
            let optionCount = Self.lastOptionCount ?? max(answers.max() ?? primary, 4)
            let hit: OptionOCRLocator.Hit?
            if let prepared {
                hit = OptionOCRLocator.locate(answer: primary, optionCount: optionCount, prepared: prepared)
            } else {
                hit = await OptionOCRLocator.locate(answer: primary, optionCount: optionCount, in: image)
            }
            if let hit {
                Self.lastEncodeInfo += " · \(hit.method) '\(hit.label)'"
                return .mcq(answers: answers, x: hit.x, y: hit.y, typeText: typeText, why: why, choices: choices)
            }
            return .mcq(answers: answers, x: fx, y: fy, typeText: typeText, why: why, choices: choices)
        }
    }

    private static func enrichMultiLocations(
        _ items: [SolveResult.MultiItem],
        prepared: OptionOCRLocator.Prepared?
    ) -> [SolveResult.MultiItem] {
        let nums = items.map { $0.answerNumber ?? 0 }
        let mcqIndices = nums.indices.filter { nums[$0] >= 1 }
        guard !mcqIndices.isEmpty, let prepared, !prepared.isEmpty else { return items }

        let answers = mcqIndices.map { nums[$0] }
        let hits = OptionOCRLocator.locateMulti(
            answers: answers,
            optionCount: lastOptionCount ?? 5,
            prepared: prepared
        )
        var out = items
        for (j, idx) in mcqIndices.enumerated() {
            guard j < hits.count, let hit = hits[j] else { continue }
            out[idx].x = hit.x
            out[idx].y = hit.y
            lastEncodeInfo += " · Q\(idx + 1):\(hit.method)"
        }
        return out
    }

    // MARK: - networking

    private static func wantsThinking(_ modelId: String, needExplanation: Bool) -> Bool {
        let id = modelId.lowercased()
        if id.contains("pro") || id.contains("opus") || id.contains("o1") || id.contains("o3") {
            return true
        }
        // Flash도 설명 모드에서만 짧은 thinking
        if needExplanation, id.contains("gemini") || id.contains("o4") {
            return true
        }
        return false
    }

    private func chat(
        modelId: String,
        apiKey: String,
        provider: APIProvider,
        needExplanation: Bool,
        precise: Bool = false,
        system: String,
        userText: String,
        dataURL: String
    ) async throws -> String {
        let thinking = Self.wantsThinking(modelId, needExplanation: needExplanation)
        let maxTokens: Int
        if thinking {
            maxTokens = needExplanation ? 2048 : 1024
        } else {
            maxTokens = needExplanation ? 900 : 350
        }
        let detail = (needExplanation || precise) ? "high" : "low"

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
                                "detail": detail
                            ]
                        ]
                    ]
                ]
            ]
        ]

        if precise {
            // 정밀 모드: 생각 허용 (OpenRouter는 reasoning, 직접 OpenAI는 토큰 여유만)
            body["max_tokens"] = provider == .openRouter ? 8000 : 4000
            body.removeValue(forKey: "temperature")  // Claude thinking 은 temperature 고정이 필요
            if provider == .openRouter {
                body["reasoning"] = ["effort": "high", "exclude": true]
            }
        } else if provider == .openRouter {
            // 빠른 엔드포인트 우선
            body["provider"] = ["sort": "latency"]
            let id = modelId.lowercased()
            if id.contains("gemini") || id.contains("o1") || id.contains("o3") || id.contains("o4") {
                if thinking {
                    body["reasoning"] = [
                        "max_tokens": needExplanation ? 512 : 256,
                        "exclude": true
                    ]
                } else {
                    // Flash 일반 풀이: thinking 끄기 → 체감 가장 큼
                    body["reasoning"] = [
                        "effort": "none",
                        "exclude": true
                    ]
                }
            }
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
        request.timeoutInterval = precise ? 240 : 90

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SolverError.badResponse }
        guard (200...299).contains(http.statusCode) else {
            throw SolverError.api(Self.friendlyError(from: data, status: http.statusCode, provider: provider))
        }
        let parsed = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        let content = parsed.choices.first?.message.content?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if content.isEmpty {
            throw SolverError.api("모델 응답이 비어 있음. Gemini면 다시 시도하거나 Flash Lite 사용.")
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
                        let nums = items[0].answerNumbers
                        if !nums.isEmpty {
                            return makeMcq(answers: nums, obj: [
                                "n": obj["n"] as Any,
                                "why": items[0].why,
                                "opts": []
                            ], typeTextOverride: items[0].answer, choicesOverride: items[0].choices)
                        }
                        return .open(typeText: items[0].answer, why: items[0].why)
                    }
                    return .unclear
                }
                if mode == "open" {
                    if let t = stringValue(obj["t"])?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
                        // 주관식처럼 왔지만 "1,3" 복수번호면 객관식 복수선택으로
                        let nums = SolveResult.MultiItem.parseAnswerNumbers(t)
                        if nums.count >= 2 {
                            return makeMcq(answers: nums, obj: obj, typeTextOverride: nums.map(String.init).joined(separator: ","))
                        }
                        return .open(typeText: t, why: whyString(obj))
                    }
                    return .unclear
                }
            }
            // multi without mode: items array
            if let items = parseMultiItems(obj), items.count >= 2 {
                return .multi(items: items)
            }
            // open without mode but with t and no a — 단 복수번호면 mcq
            if obj["a"] == nil, let t = stringValue(obj["t"])?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
                let nums = SolveResult.MultiItem.parseAnswerNumbers(t)
                if nums.count >= 2 {
                    return makeMcq(answers: nums, obj: obj, typeTextOverride: nums.map(String.init).joined(separator: ","))
                }
                return .open(typeText: t, why: whyString(obj))
            }

            let answers = parseAnswerList(obj["a"]).isEmpty
                ? parseAnswerList(obj["t"])
                : parseAnswerList(obj["a"])
            if !answers.isEmpty {
                return makeMcq(answers: answers, obj: obj)
            }
        }
        let u = cleaned.uppercased()
        if u.contains("UNSURE") { return .unclear }
        if u.contains("NONE") { return .notQuestion }
        let loose = SolveResult.MultiItem.parseAnswerNumbers(cleaned)
        if !loose.isEmpty {
            lastOptionCount = max(loose.max() ?? 4, 4)
            let primary = loose[0]
            return .mcq(
                answers: loose,
                x: 0.5,
                y: estimateY(for: primary, optionCount: lastOptionCount!),
                typeText: loose.map(String.init).joined(separator: ","),
                why: "",
                choices: []
            )
        }
        return .unclear
    }

    private static func makeMcq(
        answers: [Int],
        obj: [String: Any],
        typeTextOverride: String? = nil,
        choicesOverride: [SolveResult.Choice]? = nil
    ) -> SolveResult {
        let optionCount = clampOptionCount(parseAnswerNumber(obj["n"]))
        let maxA = optionCount ?? Self.maxOptions
        let valid = SolveResult.MultiItem.uniquePreserveOrder(
            answers.filter { (1...maxA).contains($0) }
        )
        guard let primary = valid.first else { return .unclear }
        let count = optionCount ?? max(valid.max() ?? primary, 2)
        lastOptionCount = count
        let t = stringValue(obj["t"])?.trimmingCharacters(in: .whitespacesAndNewlines)
        let typeText = typeTextOverride
            ?? ((t?.isEmpty == false) ? t! : valid.map(String.init).joined(separator: ","))
        let choices = choicesOverride
            ?? parseChoices(obj, correctIndices: Set(valid))
        return .mcq(
            answers: valid,
            x: 0.5,
            y: estimateY(for: primary, optionCount: count),
            typeText: typeText,
            why: whyString(obj),
            choices: choices
        )
    }

    /// a: 3 | "1,3" | [1,3]
    private static func parseAnswerList(_ any: Any?) -> [Int] {
        if let arr = any as? [Any] {
            return SolveResult.MultiItem.uniquePreserveOrder(arr.compactMap { parseAnswerNumber($0) })
        }
        if let s = any as? String {
            return SolveResult.MultiItem.parseAnswerNumbers(s)
        }
        if let n = parseAnswerNumber(any) {
            return (1...maxOptions).contains(n) ? [n] : []
        }
        return []
    }

    private static func whyString(_ obj: [String: Any]) -> String {
        (stringValue(obj["why"]) ?? stringValue(obj["w"]) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parseChoices(_ obj: [String: Any], correctIndex: Int) -> [SolveResult.Choice] {
        parseChoices(obj, correctIndices: [correctIndex])
    }

    private static func parseChoices(_ obj: [String: Any], correctIndices: Set<Int>) -> [SolveResult.Choice] {
        let raw = (obj["opts"] as? [Any]) ?? (obj["choices"] as? [Any]) ?? (obj["options"] as? [Any])
        guard let raw else { return [] }
        var out: [SolveResult.Choice] = []
        for (idx, any) in raw.enumerated() {
            if let dict = any as? [String: Any] {
                let i = parseAnswerNumber(dict["i"]) ?? parseAnswerNumber(dict["a"]) ?? (idx + 1)
                let text = (stringValue(dict["t"]) ?? stringValue(dict["text"]) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let note = (stringValue(dict["note"]) ?? stringValue(dict["why"]) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let ok: Bool
                if let b = dict["ok"] as? Bool {
                    ok = b
                } else if let s = stringValue(dict["ok"])?.lowercased() {
                    ok = s == "true" || s == "1" || s == "yes"
                } else {
                    ok = correctIndices.contains(i)
                }
                out.append(SolveResult.Choice(index: i, text: text, note: note, isCorrect: ok))
            } else if let s = stringValue(any)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
                let i = idx + 1
                out.append(SolveResult.Choice(index: i, text: s, note: "", isCorrect: correctIndices.contains(i)))
            }
        }
        return out
    }

    private static func parseMultiItems(_ obj: [String: Any]) -> [SolveResult.MultiItem]? {
        func makeItem(q: String, a: String, why: String, choices: [SolveResult.Choice]) -> SolveResult.MultiItem {
            let fromText = SolveResult.MultiItem.parseAnswerNumbers(a)
            let fromChoices = choices.filter(\.isCorrect).map(\.index)
            let nums = !fromText.isEmpty ? fromText : SolveResult.MultiItem.uniquePreserveOrder(fromChoices)
            let normalized = nums.isEmpty ? a : nums.map(String.init).joined(separator: ",")
            return SolveResult.MultiItem(question: q, answer: normalized, why: why, choices: choices, x: nil, y: nil)
        }

        func itemFromDict(_ item: [String: Any]) -> SolveResult.MultiItem? {
            let rawT = stringValue(item["t"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let listA = parseAnswerList(item["a"])
            let listT = SolveResult.MultiItem.parseAnswerNumbers(rawT)
            let nums = !listA.isEmpty ? listA : listT
            guard !nums.isEmpty || !rawT.isEmpty || item["opts"] != nil || item["choices"] != nil else { return nil }

            let q = (stringValue(item["q"]) ?? stringValue(item["question"]) ?? "")
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            let choices = parseChoices(item, correctIndices: Set(nums))
            let answerText: String
            if !nums.isEmpty {
                answerText = nums.map(String.init).joined(separator: ",")
            } else if !rawT.isEmpty {
                answerText = rawT
            } else if let c = choices.first(where: \.isCorrect) {
                answerText = "\(c.index)"
            } else {
                return nil
            }
            return makeItem(q: q, a: answerText, why: whyString(item), choices: choices)
        }

        if let items = obj["items"] as? [[String: Any]] {
            let parsed = items.compactMap(itemFromDict)
            return parsed.isEmpty ? nil : parsed
        }
        if let items = obj["items"] as? [String] {
            let parsed = items
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .map { makeItem(q: "", a: $0, why: "", choices: []) }
            return parsed.isEmpty ? nil : parsed
        }
        if let arr = obj["answers"] as? [Any] {
            let parsed: [SolveResult.MultiItem] = arr.compactMap { any in
                if let dict = any as? [String: Any] {
                    return itemFromDict(dict)
                }
                if let a = stringValue(any)?.trimmingCharacters(in: .whitespacesAndNewlines), !a.isEmpty {
                    return makeItem(q: "", a: a, why: "", choices: [])
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
        var raw = ""
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let err = obj["error"] as? [String: Any]
            raw = (err?["message"] as? String) ?? (obj["message"] as? String) ?? ""
        }
        let lower = raw.lowercased()
        // OpenRouter: 잘못된/삭제된 키 → "User not found."
        if status == 401 || status == 403
            || lower.contains("user not found")
            || lower.contains("invalid api key")
            || lower.contains("incorrect api key")
            || lower.contains("unauthorized")
            || lower.contains("no auth")
            || lower.contains("authentication") {
            switch provider {
            case .openRouter:
                return "API 키 무효(User not found). OpenRouter에서 새 키 발급 → Solv에 다시 저장"
            case .openAI:
                return "OpenAI API 키 무효. platform.openai.com에서 키 확인 후 다시 저장"
            }
        }
        if !raw.isEmpty { return raw }
        return "HTTP \(status)"
    }

    /// 저장 직후/메뉴에서 호출. 키가 살아 있는지 확인. (ok, message)
    static func probeAPIKey(_ rawKey: String) async -> (ok: Bool, message: String) {
        let apiKey = KeychainStore.normalizeAPIKey(rawKey)
        guard !apiKey.isEmpty else { return (false, "키가 비어 있음") }
        let provider = APIProvider.detect(apiKey: apiKey)
        let url: URL
        switch provider {
        case .openRouter:
            url = URL(string: "https://openrouter.ai/api/v1/auth/key")!
        case .openAI:
            url = URL(string: "https://api.openai.com/v1/models")!
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 20
        if provider == .openRouter {
            request.setValue("https://github.com/solv-app", forHTTPHeaderField: "HTTP-Referer")
            request.setValue("Solv", forHTTPHeaderField: "X-Title")
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return (false, "응답 없음")
            }
            guard (200...299).contains(http.statusCode) else {
                return (false, friendlyError(from: data, status: http.statusCode, provider: provider))
            }
            let mask = KeychainStore.maskedPreview(apiKey)
            switch provider {
            case .openRouter:
                if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let dataObj = obj["data"] as? [String: Any] {
                    let label = (dataObj["label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let limit = dataObj["limit_remaining"] ?? dataObj["limit"]
                    let limitText: String
                    if let d = limit as? Double {
                        limitText = String(format: "잔여 $%.2f", d)
                    } else if let i = limit as? Int {
                        limitText = "잔여 \(i)"
                    } else {
                        limitText = "연결 OK"
                    }
                    let name = (label?.isEmpty == false) ? label! : "OpenRouter"
                    return (true, "\(name) · \(limitText) · \(mask)")
                }
                return (true, "OpenRouter 연결 OK · \(mask)")
            case .openAI:
                return (true, "OpenAI 연결 OK · \(mask)")
            }
        } catch {
            return (false, error.localizedDescription)
        }
    }
}

private enum APIProvider: Equatable {
    case openAI, openRouter

    static func detect(apiKey: String) -> APIProvider {
        let k = KeychainStore.normalizeAPIKey(apiKey).lowercased()
        // OpenRouter: sk-or-… / or-…
        if k.hasPrefix("sk-or-") || k.hasPrefix("or-") { return .openRouter }
        return .openAI
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
