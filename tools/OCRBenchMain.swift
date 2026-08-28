import AppKit
import Foundation

/// OCR 선택지 위치 정확도 벤치마크 (`tools/run_option_ocr_test.sh`)

struct OptionGT {
    let index: Int
    let rect: CGRect
    var center: CGPoint { CGPoint(x: rect.midX, y: rect.midY) }
}

struct QuizCase {
    let name: String
    let answer: Int
    let image: NSImage
    let options: [OptionGT]
}

enum QuizRenderer {
    static func make(
        name: String,
        stem: String,
        labels: [String],
        answer: Int,
        width: Int = 900,
        height: Int = 720,
        fontSize: CGFloat = 32,
        left: CGFloat = 72,
        stemTop: CGFloat = 64,
        optionGap: CGFloat = 58
    ) -> QuizCase {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .regular),
            .foregroundColor: NSColor.black
        ]

        func drawTopLeft(text: String, topY: CGFloat, x: CGFloat) -> CGRect {
            let size = (text as NSString).size(withAttributes: attrs)
            let appKitY = CGFloat(height) - topY - size.height
            (text as NSString).draw(at: NSPoint(x: x, y: appKitY), withAttributes: attrs)
            let nx = x / CGFloat(width)
            let ny = topY / CGFloat(height)
            let nw = size.width / CGFloat(width)
            let nh = size.height / CGFloat(height)
            return CGRect(x: nx, y: ny, width: max(nw, 0.35), height: max(nh, 0.035))
        }

        _ = drawTopLeft(text: stem, topY: stemTop, x: left)

        var gts: [OptionGT] = []
        var y = stemTop + fontSize + 36
        for (i, line) in labels.enumerated() {
            let rect = drawTopLeft(text: line, topY: y, x: left)
            let padded = CGRect(
                x: rect.minX,
                y: rect.minY - 0.008,
                width: max(rect.width, 0.55),
                height: rect.height + 0.016
            )
            gts.append(OptionGT(index: i + 1, rect: padded))
            y += optionGap
        }

        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: NSSize(width: width, height: height))
        image.addRepresentation(rep)
        return QuizCase(name: name, answer: answer, image: image, options: gts)
    }
}

func buildSuite() -> [QuizCase] {
    var cases: [QuizCase] = []

    // —— 기존 ——
    let circled = ["① 부산", "② 서울", "③ 대구", "④ 인천", "⑤ 광주"]
    let dotted = ["1. 사과", "2. 바나나", "3. 포도", "4. 수박", "5. 참외"]
    let paren = ["(1) redox", "(2) acid", "(3) base", "(4) salt", "(5) buffer"]
    let letters = ["A. Paris", "B. London", "C. Berlin", "D. Madrid", "E. Rome"]
    let hangulNum = ["1번 광합성", "2번 호흡", "3번 발효", "4번 증산", "5번 흡수"]
    let mixedLong = [
        "① 이 선택지는 조금 긴 문장입니다",
        "② 두 번째도 역시 긴 설명 텍스트",
        "③ 정답 후보가 여기일 수 있음",
        "④ 네 번째 보기 내용",
        "⑤ 마지막 선택지입니다"
    ]

    for a in 1...5 {
        cases.append(QuizRenderer.make(
            name: "circled-ans\(a)", stem: "문제: 대한민국의 수도는?", labels: circled, answer: a
        ))
    }
    for a in 1...5 {
        cases.append(QuizRenderer.make(
            name: "dotted-ans\(a)", stem: "Q. Which fruit?", labels: dotted, answer: a, fontSize: 28
        ))
    }
    for a in [1, 3, 5] {
        cases.append(QuizRenderer.make(
            name: "paren-ans\(a)", stem: "Chemistry: pick one", labels: paren, answer: a,
            fontSize: 26, optionGap: 52
        ))
    }
    for a in [2, 4] {
        cases.append(QuizRenderer.make(
            name: "letter-ans\(a)", stem: "Capital of France?", labels: letters, answer: a
        ))
    }
    for a in [1, 5] {
        cases.append(QuizRenderer.make(
            name: "hangulNum-ans\(a)", stem: "생물: 올바른 과정은?", labels: hangulNum, answer: a, fontSize: 30
        ))
    }
    for a in [3, 4] {
        cases.append(QuizRenderer.make(
            name: "long-ans\(a)", stem: "다음 중 알맞은 것은?", labels: mixedLong, answer: a,
            width: 1000, height: 800, fontSize: 24, optionGap: 64
        ))
    }
    cases.append(QuizRenderer.make(
        name: "tight-ans2", stem: "짧음", labels: circled, answer: 2,
        fontSize: 22, stemTop: 40, optionGap: 40
    ))
    cases.append(QuizRenderer.make(
        name: "tight-ans5", stem: "짧음", labels: dotted, answer: 5,
        fontSize: 22, optionGap: 40
    ))

    // —— 신규: 다른 표기 ——
    let boldCircled = ["❶ 산소", "❷ 질소", "❸ 수소", "❹ 헬륨", "❺ 네온"]
    let dashNum = ["1) 합", "2) 차", "3) 곱", "4) 몫", "5) 나머지"]
    let lowerLetter = ["a. stack", "b. queue", "c. heap", "d. tree", "e. graph"]
    let koLetter = ["ㄱ. 춘분", "ㄴ. 하지", "ㄷ. 추분", "ㄹ. 동지", "ㅁ. 입춘"]
    let fullwidth = ["１. 서울", "２. 부산", "３. 대구", "４. 인천", "５. 광주"]

    for a in [1, 3, 5] {
        cases.append(QuizRenderer.make(
            name: "boldcirc-ans\(a)", stem: "기체 기호에 해당하는 것은?", labels: boldCircled, answer: a
        ))
    }
    for a in [2, 4] {
        cases.append(QuizRenderer.make(
            name: "dashnum-ans\(a)", stem: "연산의 결과는?", labels: dashNum, answer: a, fontSize: 30
        ))
    }
    for a in [1, 3, 5] {
        cases.append(QuizRenderer.make(
            name: "lower-ans\(a)", stem: "Data structure?", labels: lowerLetter, answer: a, fontSize: 28
        ))
    }
    for a in [2, 4] {
        cases.append(QuizRenderer.make(
            name: "koletter-ans\(a)", stem: "계절의 구분은?", labels: koLetter, answer: a, fontSize: 28
        ))
    }
    for a in [1, 5] {
        cases.append(QuizRenderer.make(
            name: "fullwidth-ans\(a)", stem: "도시 선택", labels: fullwidth, answer: a, fontSize: 30
        ))
    }

    // —— 신규: 지문에 숫자/보기 언급 (오탐 유도) ——
    let distractStem = [
        "다음 중 옳은 것은? (보기 1~5 참고)",
        "문항 3번에 대한 설명으로 알맞은 것은?",
        "A와 B 중 맞는 보기를 고르시오."
    ]
    for (i, stem) in distractStem.enumerated() {
        cases.append(QuizRenderer.make(
            name: "distract\(i + 1)-ans\(i == 0 ? 4 : 2)",
            stem: stem,
            labels: circled,
            answer: i == 0 ? 4 : 2,
            fontSize: 26
        ))
    }

    // —— 신규: 레이아웃 변형 ——
    cases.append(QuizRenderer.make(
        name: "indent-ans3", stem: "들여쓰기 보기", labels: dotted, answer: 3,
        fontSize: 28, left: 140
    ))
    cases.append(QuizRenderer.make(
        name: "widegap-ans1", stem: "간격 큼", labels: letters, answer: 1,
        height: 900, fontSize: 30, optionGap: 90
    ))
    cases.append(QuizRenderer.make(
        name: "tiny-ans5", stem: "작은 글씨 시험지", labels: hangulNum, answer: 5,
        width: 700, height: 560, fontSize: 18, left: 40, stemTop: 28, optionGap: 34
    ))
    cases.append(QuizRenderer.make(
        name: "huge-ans2", stem: "큰 글씨", labels: paren, answer: 2,
        width: 1200, height: 900, fontSize: 40, left: 100, optionGap: 72
    ))

    // —— 신규: 긴 지문 여러 줄 ——
    cases.append(QuizRenderer.make(
        name: "multistem-ans3",
        stem: "다음 글을 읽고 물음에 답하시오. 광합성과 호흡의 관계를 설명할 때",
        labels: hangulNum,
        answer: 3,
        height: 780,
        fontSize: 24,
        stemTop: 36,
        optionGap: 50
    ))
    cases.append(QuizRenderer.make(
        name: "noisehead-ans4",
        stem: "[실전모의] 2024학년도 · 문항 12",
        labels: mixedLong,
        answer: 4,
        width: 980,
        fontSize: 22,
        optionGap: 55
    ))

    // —— 신규: 영어+한글 혼합 보기 ——
    let mixedLang = [
        "1. photosynthesis 광합성",
        "2. respiration 호흡",
        "3. fermentation 발효",
        "4. diffusion 확산",
        "5. osmosis 삼투"
    ]
    for a in [1, 2, 5] {
        cases.append(QuizRenderer.make(
            name: "mixedlang-ans\(a)", stem: "알맞은 용어는?", labels: mixedLang, answer: a, fontSize: 26
        ))
    }

    // —— 신규: 보기 본문에 다른 번호 포함 ——
    let nestedNums = [
        "① 1과 2만 옳다",
        "② 2와 3만 옳다",
        "③ 1과 4만 옳다",
        "④ 3과 5만 옳다",
        "⑤ 1, 2, 3 모두 옳다"
    ]
    for a in [1, 3, 5] {
        cases.append(QuizRenderer.make(
            name: "nested-ans\(a)", stem: "옳은 것을 고르면?", labels: nestedNums, answer: a, fontSize: 26
        ))
    }

    return cases
}

struct Eval {
    let name: String
    let answer: Int
    let okHit: Bool
    let okNear: Bool
    let dist: Double
    let method: String
    let pred: String
}

@main
enum OCRBench {
    static func main() async {
        var suite = buildSuite()
        if let m = ProcessInfo.processInfo.environment["OCR_MAX"], let n = Int(m) {
            suite = Array(suite.prefix(n))
        }
        if let p = ProcessInfo.processInfo.environment["OCR_PREFIX"] {
            suite = suite.filter { $0.name.hasPrefix(p) }
        }
        FileHandle.standardError.write(Data("suite=\(suite.count)\n".utf8))
        print("Option OCR accuracy — \(suite.count) cases")
        print(String(repeating: "─", count: 72))

        let nearThresh = 0.045
        var results: [Eval] = []

        for c in suite {
            let gt = c.options.first { $0.index == c.answer }!
            let hit = await OptionOCRLocator.locate(
                answer: c.answer,
                optionCount: c.options.count,
                in: c.image
            )
            if let hit {
                let p = CGPoint(x: hit.x, y: hit.y)
                let inside = gt.rect.insetBy(dx: -0.02, dy: -0.01).contains(p)
                let dist = hypot(p.x - gt.center.x, p.y - gt.center.y)
                results.append(Eval(
                    name: c.name, answer: c.answer, okHit: inside, okNear: dist <= nearThresh,
                    dist: dist, method: hit.method,
                    pred: String(format: "(%.3f,%.3f) '%@'", hit.x, hit.y, hit.label)
                ))
            } else {
                results.append(Eval(
                    name: c.name, answer: c.answer, okHit: false, okNear: false,
                    dist: 9, method: "nil", pred: "—"
                ))
            }
        }

        var passHit = 0, passNear = 0
        for (i, r) in results.enumerated() {
            let mark = r.okHit ? "HIT" : (r.okNear ? "NEAR" : "MISS")
            if r.okHit { passHit += 1 }
            if r.okNear || r.okHit { passNear += 1 }
            print("\(i + 1). [\(mark)] \(r.name) ans=\(r.answer) dist=\(String(format: "%.3f", r.dist)) \(r.method) · \(r.pred)")
        }

        let n = results.count
        let hitRate = n == 0 ? 0.0 : Double(passHit) / Double(n) * 100
        let nearRate = n == 0 ? 0.0 : Double(passNear) / Double(n) * 100
        let dists = results.filter { $0.dist < 9 }.map(\.dist)
        let mean = dists.isEmpty ? -1.0 : dists.reduce(0, +) / Double(dists.count)
        let sortedD = dists.sorted()
        let p50 = sortedD.isEmpty ? -1.0 : sortedD[sortedD.count / 2]

        let groups = [
            "circled", "dotted", "paren", "letter", "hangulNum", "long", "tight",
            "boldcirc", "dashnum", "lower", "koletter", "fullwidth",
            "distract", "indent", "widegap", "tiny", "huge",
            "multistem", "noisehead", "mixedlang", "nested"
        ]
        print(String(repeating: "─", count: 72))
        for g in groups {
            let sub = results.filter { $0.name.hasPrefix(g) }
            guard !sub.isEmpty else { continue }
            let h = sub.filter(\.okHit).count
            let pct = Double(h) / Double(sub.count) * 100
            print("  \(g): HIT \(h)/\(sub.count) = \(String(format: "%.0f", pct))%")
        }

        print(String(repeating: "─", count: 72))
        print("Row-hit accuracy : \(passHit)/\(n) = \(String(format: "%.1f", hitRate))%  (GT 선택지 행 안)")
        print("Near accuracy    : \(passNear)/\(n) = \(String(format: "%.1f", nearRate))%  (HIT 또는 dist≤4.5%)")
        print("Mean dist        : \(String(format: "%.4f", mean))   median: \(String(format: "%.4f", p50))")

        let outDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent(".build")
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let summary = "cases=\(n) hit=\(passHit) (\(String(format: "%.1f", hitRate))%) near=\(passNear) (\(String(format: "%.1f", nearRate))%) meanDist=\(String(format: "%.4f", mean))\n"
        try? summary.write(to: outDir.appendingPathComponent("ocr_accuracy.txt"), atomically: true, encoding: .utf8)

        exit(hitRate >= 80 ? 0 : 1)
    }
}
