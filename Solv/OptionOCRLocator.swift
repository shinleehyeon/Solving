import AppKit
import Foundation
import Vision

/// 온디바이스 OCR로 N지선다 선택지 위치를 찾는다 (좌상단 원점 정규화 좌표).
enum OptionOCRLocator {
    struct Hit {
        let x: Double
        let y: Double
        let label: String
        let method: String
    }

    /// - Parameters:
    ///   - answer: 1-based 정답 번호
    ///   - optionCount: 선택지 개수 (2…9)
    static func locate(answer: Int, optionCount: Int = 5, in image: NSImage) async -> Hit? {
        let count = max(2, min(QuestionSolver.maxOptions, optionCount))
        let n = max(1, min(count, answer))
        guard let cg = cgImage(from: image) else { return nil }

        let boxes = await recognize(cgImage: cg)
        guard !boxes.isEmpty else { return nil }

        if let hit = matchByMarker(answer: n, optionCount: count, boxes: boxes) {
            return hit
        }
        if let hit = matchByRowIndex(answer: n, optionCount: count, boxes: boxes) {
            return hit
        }
        return nil
    }

    // MARK: - Vision OCR

    private struct Box {
        let text: String
        /// 좌상단 원점 정규화 bbox
        let rect: CGRect
        var cx: Double { rect.midX }
        var cy: Double { rect.midY }
    }

    private static func recognize(cgImage: CGImage) async -> [Box] {
        await withCheckedContinuation { cont in
            var resumed = false
            let finish: ([Box]) -> Void = { boxes in
                guard !resumed else { return }
                resumed = true
                cont.resume(returning: boxes)
            }

            let request = VNRecognizeTextRequest { request, error in
                if error != nil {
                    finish([])
                    return
                }
                let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
                let boxes: [Box] = observations.compactMap { obs in
                    guard let top = obs.topCandidates(1).first else { return nil }
                    let bb = obs.boundingBox
                    let topLeft = CGRect(
                        x: bb.origin.x,
                        y: 1.0 - bb.origin.y - bb.height,
                        width: bb.width,
                        height: bb.height
                    )
                    return Box(text: top.string.trimmingCharacters(in: .whitespacesAndNewlines), rect: topLeft)
                }
                finish(boxes)
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            request.recognitionLanguages = ["ko-KR", "en-US"]
            if #available(macOS 13.0, *) {
                request.automaticallyDetectsLanguage = true
            }

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                finish([])
            }
        }
    }

    // MARK: - matching

    /// 선택지 번호/기호 마커를 찾아 답번에 해당하는 중심점.
    private static func matchByMarker(answer: Int, optionCount: Int, boxes: [Box]) -> Hit? {
        let markers = boxes.compactMap { box -> (Int, Box)? in
            guard let num = parseOptionMarker(box.text), (1...optionCount).contains(num) else { return nil }
            return (num, box)
        }

        var best: [Int: Box] = [:]
        for (num, box) in markers {
            if let prev = best[num] {
                if box.rect.minX < prev.rect.minX - 0.02 ||
                    (abs(box.rect.minX - prev.rect.minX) < 0.05 && box.rect.width < prev.rect.width) {
                    best[num] = box
                }
            } else {
                best[num] = box
            }
        }

        if let box = best[answer] {
            return hitFromBox(box, method: "ocr-marker")
        }

        let foundNums = best.keys.sorted()
        guard foundNums.count >= 2 else { return nil }

        let xs = foundNums.compactMap { best[$0]?.rect.minX }.sorted()
        let medianX = xs[xs.count / 2]

        let column = boxes
            .filter { abs($0.rect.minX - medianX) < 0.16 && $0.rect.minX < 0.50 }
            .sorted { $0.cy < $1.cy }
        let rows = clusterByY(column, tol: 0.028)

        let markedIndices: [Int] = rows.indices.compactMap { idx in
            rowNumber(rows[idx], optionCount: optionCount) != nil ? idx : nil
        }
        guard let firstM = markedIndices.first, let lastM = markedIndices.last else {
            return interpolateAnswer(answer, optionCount: optionCount, best: best)
        }

        var slice = Array(rows[firstM...lastM])
        if slice.count > optionCount {
            slice = compressToSlots(slice, optionCount: optionCount)
        }

        if let hit = assignAndPick(answer: answer, optionCount: optionCount, rows: slice, method: "ocr-column") {
            return hit
        }

        if let hit = interpolateAnswer(answer, optionCount: optionCount, best: best) {
            return hit
        }
        return nil
    }

    private static func rowNumber(_ row: [Box], optionCount: Int) -> Int? {
        let left = row.min(by: { $0.rect.minX < $1.rect.minX })
        if let left, let n = parseOptionMarker(left.text), (1...optionCount).contains(n) { return n }
        let joined = row.map(\.text).joined(separator: " ")
        if let n = parseOptionMarker(joined), (1...optionCount).contains(n) { return n }
        return nil
    }

    private static func assignAndPick(
        answer: Int,
        optionCount: Int,
        rows: [[Box]],
        method: String
    ) -> Hit? {
        guard !rows.isEmpty else { return nil }

        var nums: [Int?] = rows.map { rowNumber($0, optionCount: optionCount) }

        if let idx = nums.firstIndex(where: { $0 == answer }) {
            return hitFromRow(rows[idx], method: method)
        }

        var used = Set(nums.compactMap { $0 })
        var pool = (1...optionCount).filter { !used.contains($0) }
        for i in nums.indices where nums[i] == nil {
            guard !pool.isEmpty else { break }
            let lo = (0..<i).reversed().compactMap { nums[$0] }.first
            let hi = ((i + 1)..<nums.count).compactMap { nums[$0] }.first
            if let lo, let hi, hi > lo + 1 {
                let gap = (lo + 1)..<hi
                if let pick = gap.first(where: { pool.contains($0) }) {
                    nums[i] = pick
                    pool.removeAll { $0 == pick }
                    used.insert(pick)
                    continue
                }
            }
            if let lo, let pick = pool.first(where: { $0 == lo + 1 }) {
                nums[i] = pick
                pool.removeAll { $0 == pick }
                used.insert(pick)
                continue
            }
            if let hi, let pick = pool.first(where: { $0 == hi - 1 }) {
                nums[i] = pick
                pool.removeAll { $0 == pick }
                used.insert(pick)
                continue
            }
            let pick = pool.removeFirst()
            nums[i] = pick
            used.insert(pick)
        }

        if let idx = nums.firstIndex(where: { $0 == answer }) {
            return hitFromRow(rows[idx], method: method + "-filled")
        }

        if rows.count == optionCount, (1...optionCount).contains(answer) {
            return hitFromRow(rows[answer - 1], method: method)
        }
        return nil
    }

    private static func compressToSlots(_ rows: [[Box]], optionCount: Int) -> [[Box]] {
        var out: [[Box]] = []
        for row in rows {
            if rowNumber(row, optionCount: optionCount) != nil {
                out.append(row)
            } else if let last = out.last, rowNumber(last, optionCount: optionCount) != nil {
                out.append(row)
            } else if out.isEmpty {
                continue
            }
        }
        if out.count > optionCount {
            let step = Double(out.count) / Double(optionCount)
            return (0..<optionCount).map { out[min(out.count - 1, Int(Double($0) * step))] }
        }
        return out
    }

    private static func interpolateAnswer(_ answer: Int, optionCount: Int, best: [Int: Box]) -> Hit? {
        let below = (1..<answer).reversed().compactMap { best[$0] }.first
        let above = ((answer + 1)...optionCount).compactMap { best[$0] }.first
        if let below, let above {
            let loN = (1..<answer).reversed().first { best[$0] != nil }!
            let hiN = ((answer + 1)...optionCount).first { best[$0] != nil }!
            let span = Double(hiN - loN)
            let frac = Double(answer - loN) / span
            let y = below.cy + (above.cy - below.cy) * frac
            let x = (below.cx + above.cx) / 2 + 0.06
            return Hit(x: min(0.98, x), y: y, label: "~\(answer)", method: "ocr-interp")
        }
        if let below {
            return Hit(x: min(0.98, below.cx + 0.06), y: below.cy + 0.08, label: "~\(answer)", method: "ocr-extrapolate")
        }
        if let above {
            return Hit(x: min(0.98, above.cx + 0.06), y: max(0.02, above.cy - 0.08), label: "~\(answer)", method: "ocr-extrapolate")
        }
        return nil
    }

    private static func hitFromBox(_ box: Box, method: String) -> Hit {
        let x = min(0.98, box.cx + max(0.05, box.rect.width * 0.35))
        return Hit(x: x, y: box.cy, label: box.text, method: method)
    }

    private static func hitFromRow(_ row: [Box], method: String) -> Hit {
        let minX = row.map(\.rect.minX).min() ?? 0.1
        let maxX = row.map(\.rect.maxX).max() ?? 0.9
        let minY = row.map(\.rect.minY).min() ?? 0.5
        let maxY = row.map(\.rect.maxY).max() ?? 0.5
        return Hit(
            x: (minX + maxX) / 2,
            y: (minY + maxY) / 2,
            label: row.map(\.text).joined(separator: " "),
            method: method
        )
    }

    private static func clusterByY(_ boxes: [Box], tol: Double) -> [[Box]] {
        let sorted = boxes.sorted { $0.cy < $1.cy }
        var rows: [[Box]] = []
        for box in sorted {
            if let last = rows.last, let ref = last.first, abs(ref.cy - box.cy) < tol {
                rows[rows.count - 1].append(box)
            } else {
                rows.append([box])
            }
        }
        return rows
    }

    /// 마커가 약할 때: 줄 단위로 묶어 N번째 선택지.
    private static func matchByRowIndex(answer: Int, optionCount: Int, boxes: [Box]) -> Hit? {
        let lines = boxes.filter { $0.rect.height < 0.08 && !$0.text.isEmpty }
        guard lines.count >= answer else { return nil }

        let sorted = lines.sorted { $0.cy < $1.cy }
        var rows: [[Box]] = []
        let yTol = 0.025
        for box in sorted {
            if let last = rows.last, let ref = last.first, abs(ref.cy - box.cy) < yTol {
                rows[rows.count - 1].append(box)
            } else {
                rows.append([box])
            }
        }

        let optionRows = rows.filter { row in
            rowNumber(row, optionCount: optionCount) != nil
                || looksLikeOptionLine(row.map(\.text).joined(separator: " "))
        }

        let targetRows = optionRows.count >= max(2, optionCount - 1) ? optionRows : rows
        if let hit = assignAndPick(
            answer: answer,
            optionCount: optionCount,
            rows: targetRows,
            method: "ocr-row"
        ) {
            return hit
        }
        guard targetRows.count >= answer else { return nil }
        return hitFromRow(targetRows[answer - 1], method: "ocr-row")
    }

    private static func looksLikeOptionLine(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard t.count >= 2, t.count < 120 else { return false }
        return parseOptionMarker(t) != nil
    }

    /// "3", "3.", "(3)", "③", "C", "ㄱ" 등 → 1…9
    static func parseOptionMarker(_ raw: String) -> Int? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }

        let circled: [Character: Int] = [
            "①": 1, "②": 2, "③": 3, "④": 4, "⑤": 5, "⑥": 6, "⑦": 7, "⑧": 8, "⑨": 9,
            "❶": 1, "❷": 2, "❸": 3, "❹": 4, "❺": 5, "❻": 6, "❼": 7, "❽": 8, "❾": 9
        ]
        if let c = s.first, let n = circled[c] { return n }

        let koLetters: [Character: Int] = [
            "ㄱ": 1, "ㄴ": 2, "ㄷ": 3, "ㄹ": 4, "ㅁ": 5, "ㅂ": 6, "ㅅ": 7, "ㅇ": 8, "ㅈ": 9
        ]
        if let c = s.first, let n = koLetters[c] {
            let rest = s.dropFirst()
            if rest.isEmpty || ".)、．:：]）】 \t".contains(rest.first!) { return n }
            if rest.first == " " || rest.first == "." { return n }
        }

        let fullwidth: [Character: Int] = [
            "１": 1, "２": 2, "３": 3, "４": 4, "５": 5, "６": 6, "７": 7, "８": 8, "９": 9
        ]
        if let c = s.first, let n = fullwidth[c] {
            let rest = s.dropFirst()
            if rest.isEmpty || ".)、．:：]）】 \t-번".contains(rest.first!) { return n }
            if rest.first == " " || rest.first == "." { return n }
            return n
        }

        var t = s
        while let f = t.first, "([（【".contains(f) {
            t = String(t.dropFirst())
        }

        let letterMap: [Character: Int] = [
            "A": 1, "B": 2, "C": 3, "D": 4, "E": 5, "F": 6, "G": 7, "H": 8, "I": 9,
            "a": 1, "b": 2, "c": 3, "d": 4, "e": 5, "f": 6, "g": 7, "h": 8, "i": 9
        ]

        if let c = t.first, let n = letterMap[c] {
            let rest = t.dropFirst()
            if rest.isEmpty || ".)、．:：]）】 \t".contains(rest.first!) { return n }
            if rest.first == " " { return n }
        }

        if let c = t.first, c.isNumber, let n = Int(String(c)), (1...9).contains(n) {
            let rest = t.dropFirst()
            if rest.isEmpty || ".)、．:：]）】 \t-".contains(rest.first!) { return n }
            if rest.hasPrefix("번") || rest.hasPrefix(".") { return n }
        }

        if let n = Int(t), (1...9).contains(n) { return n }
        return nil
    }

    private static func cgImage(from image: NSImage) -> CGImage? {
        var rect = CGRect(origin: .zero, size: image.pixelSize)
        if rect.width < 1 || rect.height < 1 {
            rect = CGRect(origin: .zero, size: image.size)
        }
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }
}
