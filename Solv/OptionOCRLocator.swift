import AppKit
import Foundation
import Vision

/// 온디바이스 OCR로 5지선다 선택지 위치를 찾는다 (좌상단 원점 정규화 좌표).
enum OptionOCRLocator {
    struct Hit {
        let x: Double
        let y: Double
        let label: String
        let method: String
    }

    /// - Returns: 이미지 좌상단 원점, 0…1 중심점. 실패 시 nil.
    static func locate(answer: Int, in image: NSImage) async -> Hit? {
        let n = max(1, min(5, answer))
        guard let cg = cgImage(from: image) else { return nil }

        let boxes = await recognize(cgImage: cg)
        guard !boxes.isEmpty else { return nil }

        if let hit = matchByMarker(answer: n, boxes: boxes) {
            return hit
        }
        if let hit = matchByRowIndex(answer: n, boxes: boxes) {
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

    /// 선택지 번호/기호 마커(①, 3., A 등)를 찾아 답번에 해당하는 중심점.
    private static func matchByMarker(answer: Int, boxes: [Box]) -> Hit? {
        let markers = boxes.compactMap { box -> (Int, Box)? in
            guard let num = parseOptionMarker(box.text) else { return nil }
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

        // 1) 해당 번호 마커가 직접 보이면 최우선
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

        // 첫·마지막 인식 마커 사이 행 전부 포함 (④→"q" 같이 깨진 줄도 슬롯으로 유지)
        let markedIndices: [Int] = rows.indices.compactMap { idx in
            rowNumber(rows[idx]) != nil ? idx : nil
        }
        guard let firstM = markedIndices.first, let lastM = markedIndices.last else {
            return interpolateAnswer(answer, best: best)
        }

        var slice = Array(rows[firstM...lastM])

        // 마커만 필터하면 깨진 ④가 빠져 4칸이 됨 → 사이 비마커 행도 유지한 slice 사용
        // 다만 지문이 끼면 안 되므로, 연속 선택지 대역만: 번호가 증가하는 마커 구간에 가까운 행
        if slice.count > 5 {
            // 너무 많으면 마커 행 + 마커 사이 gap 행만 압축
            slice = compressToFiveSlots(slice)
        }

        if let hit = assignAndPick(answer: answer, rows: slice, method: "ocr-column") {
            return hit
        }

        // y 보간 (예: 3과 5만 있을 때 4)
        if let hit = interpolateAnswer(answer, best: best) {
            return hit
        }
        return nil
    }

    /// 행에서 선택지 번호 추출
    private static func rowNumber(_ row: [Box]) -> Int? {
        let left = row.min(by: { $0.rect.minX < $1.rect.minX })
        if let left, let n = parseOptionMarker(left.text) { return n }
        let joined = row.map(\.text).joined(separator: " ")
        if let n = parseOptionMarker(joined) { return n }
        // OCR이 ④를 q/@ 등으로 읽은 경우: 한 글자 잡음 + 본문
        return nil
    }

    /// 5개 슬롯으로 맞추며 번호 부여 후 answer 행 선택. count≠5여도 번호로 매칭.
    private static func assignAndPick(answer: Int, rows: [[Box]], method: String) -> Hit? {
        guard !rows.isEmpty else { return nil }

        var nums: [Int?] = rows.map { rowNumber($0) }

        // 이미 answer 번호가 배정된 행
        if let idx = nums.firstIndex(where: { $0 == answer }) {
            return hitFromRow(rows[idx], method: method)
        }

        // 빈 칸에 빠진 번호 채우기 (위에서 아래로, 미사용 번호 오름차순)
        var used = Set(nums.compactMap { $0 })
        var pool = (1...5).filter { !used.contains($0) }
        for i in nums.indices where nums[i] == nil {
            guard !pool.isEmpty else { break }
            // 이웃 번호 사이로 끼우기
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

        // 정확히 5행이면 순번
        if rows.count == 5 {
            return hitFromRow(rows[answer - 1], method: method)
        }
        return nil
    }

    /// 행이 6개 이상이면 마커 행과 그 사이 gap만 남겨 최대 5슬롯에 가깝게
    private static func compressToFiveSlots(_ rows: [[Box]]) -> [[Box]] {
        var out: [[Box]] = []
        for row in rows {
            if rowNumber(row) != nil {
                out.append(row)
            } else if let last = out.last, rowNumber(last) != nil {
                // 마커 직후 비마커 1개만 슬롯으로 허용
                out.append(row)
            } else if out.isEmpty {
                continue
            }
            // 연속 비마커는 스킵
        }
        if out.count > 5 {
            // 균등 샘플
            let step = Double(out.count) / 5.0
            return (0..<5).map { out[min(out.count - 1, Int(Double($0) * step))] }
        }
        return out
    }

    /// 인접 마커 y로 보간
    private static func interpolateAnswer(_ answer: Int, best: [Int: Box]) -> Hit? {
        let below = (1..<answer).reversed().compactMap { best[$0] }.first
        let above = ((answer + 1)...5).compactMap { best[$0] }.first
        if let below, let above {
            let loN = (1..<answer).reversed().first { best[$0] != nil }!
            let hiN = ((answer + 1)...5).first { best[$0] != nil }!
            let span = Double(hiN - loN)
            let frac = Double(answer - loN) / span
            let y = below.cy + (above.cy - below.cy) * frac
            let x = (below.cx + above.cx) / 2 + 0.06
            return Hit(x: min(0.98, x), y: y, label: "~\(answer)", method: "ocr-interp")
        }
        if let below {
            let gap = 0.08
            return Hit(x: min(0.98, below.cx + 0.06), y: below.cy + gap, label: "~\(answer)", method: "ocr-extrapolate")
        }
        if let above {
            let gap = 0.08
            return Hit(x: min(0.98, above.cx + 0.06), y: max(0.02, above.cy - gap), label: "~\(answer)", method: "ocr-extrapolate")
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

    /// 마커가 약할 때: 줄 단위로 묶어 위에서부터 N번째 선택지 후보.
    private static func matchByRowIndex(answer: Int, boxes: [Box]) -> Hit? {
        let lines = boxes.filter { $0.rect.height < 0.08 && !$0.text.isEmpty }
        guard lines.count >= answer else { return nil }

        // y로 클러스터링 (비슷한 높이 = 한 줄)
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

        // 선택지처럼 보이는 행: 왼쪽에 짧은 마커/번호 또는 "1." 패턴
        let optionRows = rows.filter { row in
            let left = row.min(by: { $0.rect.minX < $1.rect.minX })
            guard let left else { return false }
            if parseOptionMarker(left.text) != nil { return true }
            let joined = row.map(\.text).joined(separator: " ")
            return parseOptionMarker(joined) != nil || looksLikeOptionLine(joined)
        }

        let targetRows = optionRows.count >= 3 ? optionRows : rows
        guard targetRows.count >= answer else { return nil }
        let row = targetRows[answer - 1]
        let minX = row.map(\.rect.minX).min() ?? 0.1
        let maxX = row.map(\.rect.maxX).max() ?? 0.9
        let minY = row.map(\.rect.minY).min() ?? 0.5
        let maxY = row.map(\.rect.maxY).max() ?? 0.5
        let cx = (minX + maxX) / 2
        let cy = (minY + maxY) / 2
        return Hit(x: cx, y: cy, label: row.map(\.text).joined(separator: " "), method: "ocr-row")
    }

    private static func looksLikeOptionLine(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard t.count >= 2, t.count < 120 else { return false }
        // "1 " "2." 등으로 시작
        if parseOptionMarker(t) != nil { return true }
        return false
    }

    /// "3", "3.", "3)", "(3)", "③", "C", "C." 등 → 1…5
    static func parseOptionMarker(_ raw: String) -> Int? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }

        let circled: [Character: Int] = [
            "①": 1, "②": 2, "③": 3, "④": 4, "⑤": 5,
            "❶": 1, "❷": 2, "❸": 3, "❹": 4, "❺": 5
        ]
        if let c = s.first, let n = circled[c] { return n }

        let koLetters: [Character: Int] = [
            "ㄱ": 1, "ㄴ": 2, "ㄷ": 3, "ㄹ": 4, "ㅁ": 5
        ]
        if let c = s.first, let n = koLetters[c] {
            let rest = s.dropFirst()
            if rest.isEmpty || ".)、．:：]）】 \t".contains(rest.first!) { return n }
            if rest.first == " " || rest.first == "." { return n }
        }

        // 전각 숫자 １-５
        let fullwidth: [Character: Int] = [
            "１": 1, "２": 2, "３": 3, "４": 4, "５": 5
        ]
        if let c = s.first, let n = fullwidth[c] {
            let rest = s.dropFirst()
            if rest.isEmpty || ".)、．:：]）】 \t-번".contains(rest.first!) { return n }
            if rest.first == " " || rest.first == "." { return n }
            return n // "１. 서울" OCR이 붙는 경우
        }

        // 선행 기호 제거
        var t = s
        while let f = t.first, "([（【".contains(f) {
            t = String(t.dropFirst())
        }

        let letterMap: [Character: Int] = [
            "A": 1, "B": 2, "C": 3, "D": 4, "E": 5,
            "a": 1, "b": 2, "c": 3, "d": 4, "e": 5
        ]

        if let c = t.first, let n = letterMap[c] {
            let rest = t.dropFirst()
            if rest.isEmpty || ".)、．:：]）】 \t".contains(rest.first!) {
                return n
            }
            // "C option text" — 한 글자 라벨만
            if rest.first == " " { return n }
        }

        if let c = t.first, c.isNumber, let n = Int(String(c)), (1...5).contains(n) {
            let rest = t.dropFirst()
            if rest.isEmpty || ".)、．:：]）】 \t-".contains(rest.first!) {
                return n
            }
            // "3번", "3." 
            if rest.hasPrefix("번") || rest.hasPrefix(".") { return n }
        }

        // 전체가 한 자리
        if let n = Int(t), (1...5).contains(n) { return n }

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
