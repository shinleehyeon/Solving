#!/usr/bin/env swift
import Foundation

// QuestionSolver.MultiItem.parseAnswerNumbers 로직 복제 검증

enum Parse {
    static let maxOptions = 9

    static func parseAnswerNumber(_ raw: String) -> Int? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        if let i = Int(t), (1...maxOptions).contains(i) { return i }
        let circled: [Character: Int] = [
            "①": 1, "②": 2, "③": 3, "④": 4, "⑤": 5
        ]
        if t.count == 1, let c = t.first, let n = circled[c] { return n }
        let loneDigit = #"(?<![0-9])([1-9])(?![0-9])"#
        if let regex = try? NSRegularExpression(pattern: loneDigit),
           let match = regex.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)),
           let range = Range(match.range(at: 1), in: t),
           let i = Int(t[range]), (1...maxOptions).contains(i) {
            return i
        }
        return nil
    }

    static func uniquePreserveOrder(_ nums: [Int]) -> [Int] {
        var seen = Set<Int>()
        var out: [Int] = []
        for n in nums where (1...maxOptions).contains(n) && seen.insert(n).inserted {
            out.append(n)
        }
        return out
    }

    static func parseAnswerNumbers(_ raw: String) -> [Int] {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return [] }

        if t.hasPrefix("["), t.hasSuffix("]"),
           let data = t.data(using: .utf8),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [Any] {
            let nums = arr.compactMap { any -> Int? in
                if let i = any as? Int { return (1...maxOptions).contains(i) ? i : nil }
                return parseAnswerNumber(String(describing: any))
            }
            if !nums.isEmpty { return uniquePreserveOrder(nums) }
        }

        let separators = CharacterSet(charactersIn: ",、/·•+|&~～")
        var parts = t.components(separatedBy: separators)
        parts = parts.flatMap { $0.components(separatedBy: "와") }
        parts = parts.flatMap { $0.components(separatedBy: "과") }
        parts = parts.flatMap { $0.components(separatedBy: "and") }

        var fromParts: [Int] = []
        for part in parts {
            let p = part.trimmingCharacters(in: .whitespacesAndNewlines)
            if let n = parseAnswerNumber(p) { fromParts.append(n) }
        }
        if fromParts.count >= 2 { return uniquePreserveOrder(fromParts) }

        var scanned: [Int] = []
        let circled: [Character: Int] = ["①": 1, "②": 2, "③": 3, "④": 4, "⑤": 5]
        for ch in t {
            if let n = circled[ch] { scanned.append(n) }
        }
        if scanned.count >= 2 { return uniquePreserveOrder(scanned) }

        let digitPattern = #"(?<![0-9])([1-9])(?![0-9])"#
        if let regex = try? NSRegularExpression(pattern: digitPattern) {
            for match in regex.matches(in: t, range: NSRange(t.startIndex..., in: t)) {
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
}

struct Case {
    let name: String
    let input: String
    let expected: [Int]
}

let cases: [Case] = [
    Case(name: "single", input: "3", expected: [3]),
    Case(name: "comma", input: "1,3", expected: [1, 3]),
    Case(name: "comma-space", input: "1, 3", expected: [1, 3]),
    Case(name: "dot", input: "1·3", expected: [1, 3]),
    Case(name: "json", input: "[1,3]", expected: [1, 3]),
    Case(name: "circled", input: "①③", expected: [1, 3]),
    Case(name: "and", input: "1 and 3", expected: [1, 3]),
    Case(name: "wa", input: "1과 3", expected: [1, 3]),
    Case(name: "three", input: "2,4,5", expected: [2, 4, 5]),
    Case(name: "dup", input: "1,1,3", expected: [1, 3]),
]

print("Multi-select parse — \(cases.count) cases")
print(String(repeating: "─", count: 48))
var failed = 0
for (i, c) in cases.enumerated() {
    let got = Parse.parseAnswerNumbers(c.input)
    let ok = got == c.expected
    if !ok { failed += 1 }
    print(String(format: "%2d. [%@] %@ → %@ %@", i + 1, ok ? "PASS" : "FAIL", c.name, "\(got)", ok ? "" : "(want \(c.expected))"))
}
print(String(repeating: "─", count: 48))
print(failed == 0 ? "Result: all passed" : "Result: \(failed) failed")
exit(failed == 0 ? 0 : 1)
