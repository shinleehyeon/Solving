import AppKit
import Foundation

/// RaycastTyper 클립보드 모드 정확도 테스트
@main
enum RaycastClipboardBench {
    struct Case {
        let name: String
        let input: String
        let expectOK: Bool
        let expectPasteboard: String?
    }

    static func main() {
        let cases: [Case] = [
            Case(name: "mcq-digit", input: "3", expectOK: true, expectPasteboard: "3"),
            Case(name: "mcq-letter", input: "B", expectOK: true, expectPasteboard: "B"),
            Case(name: "open-ko", input: "광합성", expectOK: true, expectPasteboard: "광합성"),
            Case(name: "open-en", input: "mitochondria", expectOK: true, expectPasteboard: "mitochondria"),
            Case(name: "trim-spaces", input: "  42  ", expectOK: true, expectPasteboard: "42"),
            Case(name: "mixed", input: "답은 4번", expectOK: true, expectPasteboard: "답은 4번"),
            Case(name: "long", input: String(repeating: "가", count: 80), expectOK: true, expectPasteboard: String(repeating: "가", count: 80)),
            Case(name: "empty", input: "", expectOK: false, expectPasteboard: nil),
            Case(name: "whitespace-only", input: "   \n\t  ", expectOK: false, expectPasteboard: nil),
            Case(name: "symbols", input: "H2O + CO2", expectOK: true, expectPasteboard: "H2O + CO2"),
            Case(name: "newline-trim", input: "\n서울\n", expectOK: true, expectPasteboard: "서울"),
            Case(name: "overwrite-prev", input: "first", expectOK: true, expectPasteboard: "first"),
            Case(name: "overwrite-next", input: "second", expectOK: true, expectPasteboard: "second"),
        ]

        // 오염 방지: 이전 클립보드 백업
        let pb = NSPasteboard.general
        let backup = pb.string(forType: .string)

        print("Raycast clipboard accuracy — \(cases.count) cases")
        print(String(repeating: "─", count: 64))

        var pass = 0
        for (i, c) in cases.enumerated() {
            // 고의로 이전 값 남김
            if c.name == "overwrite-next" {
                _ = RaycastTyper.putAnswerReady("first")
            }

            let outcome = RaycastTyper.putAnswerReady(c.input)
            let okOutcome = c.expectOK ? (outcome == .ok) : (outcome == .emptyText)

            var okBoard = true
            if let expected = c.expectPasteboard {
                let got = pb.string(forType: .string) ?? ""
                okBoard = (got == expected)
                let mark = (okOutcome && okBoard) ? "PASS" : "FAIL"
                if okOutcome && okBoard { pass += 1 }
                print(String(format: "%2d. [%@] %@ outcome=%@ board='%@' expected='%@'",
                             i + 1, mark, c.name, "\(outcome)", got, expected))
            } else {
                let mark = okOutcome ? "PASS" : "FAIL"
                if okOutcome { pass += 1 }
                print(String(format: "%2d. [%@] %@ outcome=%@", i + 1, mark, c.name, "\(outcome)"))
            }
        }

        // 복원
        pb.clearContents()
        if let backup {
            pb.setString(backup, forType: .string)
        }

        let n = cases.count
        let rate = Double(pass) / Double(n) * 100
        print(String(repeating: "─", count: 64))
        print(String(format: "Result: %d/%d = %.1f%%", pass, n, rate))

        let outDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent(".build")
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let summary = "cases=\(n) pass=\(pass) rate=\(String(format: "%.1f", rate))%\n"
        try? summary.write(
            to: outDir.appendingPathComponent("raycast_clipboard_accuracy.txt"),
            atomically: true,
            encoding: .utf8
        )

        exit(pass == n ? 0 : 1)
    }
}
