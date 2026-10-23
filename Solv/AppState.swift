import AppKit
import ApplicationServices
import Combine
import Foundation

@MainActor
final class AppState: ObservableObject {
    @Published var isBusy = false
    @Published var statusText = "⌘⌥ 영역 · ⌘⌥C 전체 · Caps"
    @Published var hotkeyEnabled = true {
        didSet {
            UserDefaults.standard.set(hotkeyEnabled, forKey: "hotkeyEnabled")
            hotkey.setEnabled(hotkeyEnabled)
        }
    }
    /// 정밀 모드: 고해상도 이미지 + 생각(reasoning) 켜기 — 느리지만 어려운 문제에 강함
    @Published var preciseMode = true {
        didSet { UserDefaults.standard.set(preciseMode, forKey: "preciseMode") }
    }
    @Published var apiKeyInput = ""
    /// 설정·메뉴에서 쓰는 선택 모델 (catalog와 동기)
    var selectedModel: SolvRemoteModel { SolvModelCatalog.shared.selectedModel }

    private let hotkey = HotkeyMonitor()
    private let capture = ScreenCapture()
    private let solver = QuestionSolver()
    private let led = CapsLockLED()
    private let regionSelector = RegionSelector()

    init() {
        hotkeyEnabled = UserDefaults.standard.object(forKey: "hotkeyEnabled") as? Bool ?? true
        preciseMode = UserDefaults.standard.object(forKey: "preciseMode") as? Bool ?? true
        apiKeyInput = KeychainStore.loadAPIKey() ?? ""
        Task { @MainActor in
            self.start()
            await SolvModelCatalog.shared.refresh()
        }
    }

    func selectModel(_ model: SolvRemoteModel) {
        SolvModelCatalog.shared.selectedId = model.id
        statusText = "모델: \(model.shortTitle)"
        objectWillChange.send()
    }

    func start() {
        hotkey.onAction = { [weak self] action in
            Task { @MainActor in
                switch action {
                case .capsFullScreen:
                    await self?.solve(capture: .fullScreen, output: .capsLock)
                case .capsRegion:
                    await self?.solve(capture: .region, output: .capsLock, showBorder: true)
                case .capsRegionHidden:
                    await self?.solve(capture: .region, output: .handCursor, showBorder: false)
                case .mouseFullScreen:
                    await self?.solve(capture: .fullScreen, output: .mouse)
                case .mouseRegion:
                    await self?.solve(capture: .region, output: .mouse, showBorder: true)
                case .mouseRegionHidden:
                    await self?.solve(capture: .region, output: .mouse, showBorder: false)
                case .mouseCursorRegion:
                    await self?.solve(capture: .region, output: .mouseCursor, showBorder: false)
                case .raycastRegion:
                    await self?.solve(capture: .region, output: .raycast, showBorder: true)
                case .raycastRegionHidden:
                    await self?.solve(capture: .region, output: .raycast, showBorder: false)
                case .raycastFullScreen:
                    await self?.solve(capture: .fullScreen, output: .raycast)
                case .raycastExplainHidden:
                    await self?.solve(capture: .region, output: .raycastExplain, showBorder: false)
                }
            }
        }
        hotkey.setEnabled(hotkeyEnabled)
        hotkey.start()
        ensureAccessibility(prompt: false)

        if KeychainStore.loadAPIKey()?.isEmpty != false {
            statusText = "메뉴에서 API 키를 넣으세요"
        }
    }

    func saveAPIKey() {
        let normalized = KeychainStore.normalizeAPIKey(apiKeyInput)
        apiKeyInput = normalized
        KeychainStore.saveAPIKey(normalized)
        statusText = "API 키 저장됨 · 연결 확인 중…"
        Task { await testAPIKey() }
    }

    /// OpenRouter/OpenAI에 실제로 물어봐 키가 유효한지 확인
    func testAPIKey() async {
        guard let key = KeychainStore.loadAPIKey(), !key.isEmpty else {
            statusText = "API 키 없음 · 메뉴에서 키 입력"
            return
        }
        statusText = "API 키 확인 중… \(KeychainStore.maskedPreview(key))"
        let result = await QuestionSolver.probeAPIKey(key)
        if result.ok {
            statusText = "API OK · \(result.message)"
        } else {
            statusText = "API 실패 · \(result.message)"
            promptForAPIKey(preface: result.message)
        }
    }

    func openOpenRouterKeysPage() {
        if let url = URL(string: "https://openrouter.ai/keys") {
            NSWorkspace.shared.open(url)
        }
    }

    func promptForAPIKey(preface: String? = nil) {
        let alert = NSAlert()
        alert.messageText = "API 키"
        var info = "Gemini/Claude는 OpenRouter 키(sk-or-v1-…)가 필요합니다.\nopenrouter.ai/keys 에서 Create Key 후 붙여넣으세요."
        if let preface, !preface.isEmpty {
            info = "\(preface)\n\n" + info
        }
        alert.informativeText = info
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.stringValue = apiKeyInput
        alert.accessoryView = field
        alert.addButton(withTitle: "저장·연결확인")
        alert.addButton(withTitle: "OpenRouter 키 페이지")
        alert.addButton(withTitle: "취소")
        NSApp.activate(ignoringOtherApps: true)
        let result = alert.runModal()
        if result == .alertFirstButtonReturn {
            apiKeyInput = field.stringValue
            saveAPIKey()
        } else if result == .alertSecondButtonReturn {
            openOpenRouterKeysPage()
            // 페이지 연 뒤 다시 입력 받기
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.promptForAPIKey(preface: "새 키를 복사한 뒤 붙여넣으세요")
            }
        }
    }

    @discardableResult
    func ensureAccessibility(prompt: Bool) -> Bool {
        if AXIsProcessTrusted() { return true }
        if prompt {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
        }
        return AXIsProcessTrusted()
    }

    func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
        statusText = "화면 녹화에서 Solv ON → 앱 재실행"
    }

    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        statusText = "손쉬운 사용에서 Solv ON → 앱 재실행"
    }

    func testCapsLock() async {
        statusText = "Caps Lock 테스트 중…"
        await led.testBlink()
        statusText = "Caps Lock 2회 끝"
    }

    /// 손바닥 1회→2회. 커서가 확실히 바뀌는지 눈으로 확인.
    /// 마네키네코 1번 → 쉼 → 2번
    func testManeki() async {
        statusText = "마네키네코 테스트 · 1→2"
        await CatAnimator.shared.waveSequence([1, 2], pauseSeconds: 2.0)
        statusText = "마네키네코 테스트 완료"
    }

    func testHandCursor() async {
        statusText = "손바닥 테스트 · 답1 (길게)…"
        await MouseMover.blinkIBeam(times: 1)
        statusText = "손바닥 1회 끝 · 이어서 답2…"
        try? await Task.sleep(nanoseconds: 900_000_000)
        await MouseMover.blinkIBeam(times: 2)
        statusText = "손바닥 테스트 완료 · \(MouseMover.lastBlinkLog)"
    }

    func openLastCaptureImage() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Solv")
        let png = dir.appendingPathComponent("last-capture.png")
        let jpg = dir.appendingPathComponent("last-capture.jpg")
        if FileManager.default.fileExists(atPath: png.path) {
            NSWorkspace.shared.open(png)
        } else if FileManager.default.fileExists(atPath: jpg.path) {
            NSWorkspace.shared.open(jpg)
        } else {
            statusText = "아직 전송한 이미지가 없습니다"
        }
    }

    func runCaptureDiagnose() async {
        let report = capture.diagnose()
        statusText = report.replacingOccurrences(of: "\n", with: " · ")
        let alert = NSAlert()
        alert.messageText = "캡처 진단"
        alert.informativeText = report
        if !capture.preflightOK {
            alert.addButton(withTitle: "화면 녹화 열기")
            alert.addButton(withTitle: "닫기")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn {
                openScreenRecordingSettings()
            }
        } else {
            alert.addButton(withTitle: "확인")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    func showPermissionRepairGuide() {
        let alert = NSAlert()
        alert.messageText = "화면 녹화 다시 연결"
        alert.informativeText = """
        설정에 Solv가 켜져 보여도, 지금 실행 중인 앱에는 권한이 없습니다 (preflight=false).

        1. Solv 종료
        2. 화면 녹화 목록에서 Solv 선택 → 아래 − 로 삭제
        3. /Applications/Solv.app 다시 실행
        4. 뜨는 창에서 시스템 설정 열기 → Solv ON
        5. Solv 완전 종료 후 한 번 더 실행
        """
        alert.addButton(withTitle: "화면 녹화 열기")
        alert.addButton(withTitle: "닫기")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            openScreenRecordingSettings()
        }
    }

    enum CaptureMode {
        case fullScreen
        case region
    }

    enum OutputMode {
        case capsLock
        case mouse
        /// 손바닥 커서가 N번 바뀌며 답 표시
        case mouseCursor
        /// 마우스 포인터(손바닥 커서)가 N번 바뀌며 답 표시
        case handCursor
        case raycast
        /// 클립보드에 답 + 설명
        case raycastExplain
    }

    func solve(
        capture captureMode: CaptureMode = .fullScreen,
        output: OutputMode = .capsLock,
        showBorder: Bool = true
    ) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }

        guard let apiKey = KeychainStore.loadAPIKey(), !apiKey.isEmpty else {
            statusText = "API 키가 없습니다"
            promptForAPIKey()
            return
        }

        let axOK = AXIsProcessTrusted()
        if (output == .mouse || output == .mouseCursor || output == .handCursor || output == .raycast || output == .raycastExplain), !axOK {
            statusText = "손쉬운 사용 OFF · 이동/타이핑에 필요할 수 있음"
        }

        let includeWhy = (output == .raycastExplain)
        let needLocation = (output == .mouse)

        let image: NSImage
        var regionRect: CGRect?
        do {
            switch captureMode {
            case .fullScreen:
                statusText = "전체 화면 캡처 중…"
                try? await Task.sleep(nanoseconds: 80_000_000)
                image = try await capture.captureMainDisplay()
                regionRect = nil
            case .region:
                statusText = showBorder ? "영역을 드래그해서 선택하세요" : "영역 선택 중…"
                guard let rect = await regionSelector.pick(showBorder: showBorder) else {
                    statusText = "영역 선택 취소됨"
                    return
                }
                regionRect = rect
                try? await Task.sleep(nanoseconds: 60_000_000)
                image = try await capture.captureScreenRect(rect)
            }
        } catch ScreenCaptureError.noPermission {
            statusText = "화면 녹화 미연결 (설정 ON이어도 삭제 후 다시)"
            showPermissionRepairGuide()
            return
        } catch {
            statusText = "캡처 실패: \(error.localizedDescription)"
            NSSound.beep()
            return
        }

        statusText = needLocation ? "문제 분석·위치 확인 중…" : (includeWhy ? "문제·설명 분석 중…" : "문제 분석 중…")
        if preciseMode { statusText += " (정밀 · 오래 걸릴 수 있음)" }
        do {
            let result = try await solver.solve(
                image: image,
                apiKey: apiKey,
                needLocation: needLocation,
                needExplanation: includeWhy,
                precise: preciseMode
            )
            let ms = QuestionSolver.lastLatencyMs
            let msTag = ms > 0 ? " · \(ms)ms" : ""
            switch result {
            case .mcq(let answers, let x, let y, let typeText, let why, let choices):
                let label = answers.map(String.init).joined(separator: ",")
                switch output {
                case .capsLock:
                    await signalAnswerNumbers(answers, mode: .capsLock, msTag: msTag)
                case .mouseCursor, .handCursor:
                    await signalAnswerNumbers(answers, mode: output, msTag: msTag)
                case .mouse:
                    let n = answers.first ?? 0
                    let multiTag = answers.count > 1 ? " · 복수 \(label) (첫 선지)" : ""
                    statusText = String(format: "답 %d%@ · OCR→마우스 (%.2f, %.2f)%@", n, multiTag, x, y, msTag)
                    let miss = await MouseMover.glideToNormalized(x: x, y: y, imageRect: regionRect)
                    if miss > 40 {
                        statusText = "답 \(label) · 커서 이동 실패 (손쉬운 사용에서 Solv ON 후 재실행)"
                        NSSound.beep()
                    } else {
                        statusText = String(format: "답 %@ 마우스 완료 · 오차 %.0fpt%@", label, miss, msTag)
                    }
                case .raycast, .raycastExplain:
                    let text = SolveResult.clipboardAnswer(
                        typeText,
                        why: why,
                        choices: choices,
                        includeWhy: includeWhy
                    )
                    let outcome = RaycastTyper.putAnswerReady(text)
                    switch outcome {
                    case .ok:
                        statusText = includeWhy
                            ? "답+선지+설명 복사됨\(msTag) · ⌘V"
                            : "답 \(typeText) 복사됨\(msTag) · ⌘V"
                    case .emptyText:
                        statusText = "타이핑할 답이 비어 있음"
                    }
                }
            case .open(let typeText, let why):
                switch output {
                case .raycast, .raycastExplain:
                    let text = SolveResult.clipboardAnswer(typeText, why: why, includeWhy: includeWhy)
                    let outcome = RaycastTyper.putAnswerReady(text)
                    switch outcome {
                    case .ok:
                        statusText = includeWhy
                            ? "답+선지+설명 복사됨 · Raycast 연 뒤 ⌘V"
                            : "주관식 복사됨 · Raycast 연 뒤 ⌘V"
                    case .emptyText:
                        statusText = "타이핑할 답이 비어 있음"
                    }
                case .capsLock:
                    let nums = SolveResult.MultiItem.parseAnswerNumbers(typeText)
                    if nums.isEmpty {
                        statusText = "주관식: \(typeText) · Caps 불가 · ⌘⇧ 클립보드 사용"
                        await led.blinkError()
                    } else {
                        await signalAnswerNumbers(nums, mode: .capsLock, msTag: msTag)
                    }
                case .mouseCursor, .handCursor:
                    let nums = SolveResult.MultiItem.parseAnswerNumbers(typeText)
                    if nums.isEmpty {
                        statusText = "주관식: \(typeText) · 손바닥 불가 · ⌘⇧ 클립보드 사용"
                        NSSound.beep()
                    } else {
                        await signalAnswerNumbers(nums, mode: output, msTag: msTag)
                    }
                case .mouse:
                    let nums = SolveResult.MultiItem.parseAnswerNumbers(typeText)
                    if nums.isEmpty {
                        statusText = "주관식: \(typeText) · ⌘⇧ 클립보드 사용"
                        NSSound.beep()
                    } else {
                        statusText = "주관식처럼 왔지만 객관식 \(nums.map(String.init).joined(separator: ",")) · 마우스 좌표 없음 · Caps/영역 재시도"
                        NSSound.beep()
                    }
                }
            case .multi(let items):
                let text = SolveResult.clipboardText(from: items, includeWhy: includeWhy)
                switch output {
                case .raycast, .raycastExplain:
                    let outcome = RaycastTyper.putAnswerReady(text)
                    switch outcome {
                    case .ok:
                        statusText = includeWhy
                            ? "문제 \(items.count)개 답+선지+설명 복사됨 · ⌘V"
                            : "문제 \(items.count)개 복사됨 · Raycast 연 뒤 ⌘V"
                    case .emptyText:
                        statusText = "타이핑할 답이 비어 있음"
                    }
                case .capsLock:
                    // 문항별 번호 + 문항 안 복수선택까지 펼침 → 1깜빡→쉼→3깜빡
                    let nums = items.flatMap(\.answerNumbers)
                    if nums.isEmpty {
                        let preview = items.map(\.answer).joined(separator: ", ")
                        statusText = "여러 문제지만 번호 파싱 실패 · \(preview)"
                        await led.blinkError()
                    } else {
                        await signalAnswerNumbers(nums, mode: .capsLock, msTag: msTag, itemCount: items.count)
                    }
                case .mouseCursor, .handCursor:
                    let nums = items.flatMap(\.answerNumbers)
                    if nums.isEmpty {
                        let preview = items.map(\.answer).joined(separator: ", ")
                        statusText = "여러 문제지만 번호 파싱 실패 · \(preview)"
                        NSSound.beep()
                    } else {
                        await signalAnswerNumbers(nums, mode: output, msTag: msTag, itemCount: items.count)
                    }
                case .mouse:
                    let targets = items.enumerated().compactMap { idx, item -> (Int, Double, Double, String)? in
                        guard let x = item.x, let y = item.y else { return nil }
                        return (idx + 1, x, y, item.answer)
                    }
                    if targets.isEmpty {
                        let summary = items.compactMap(\.answerNumber).enumerated()
                            .map { "\($0.offset + 1)→\($0.element)" }.joined(separator: " ")
                        statusText = summary.isEmpty
                            ? "여러 문제 · OCR 위치 없음 · Caps로 재시도"
                            : "OCR 위치 없음 · 답 \(summary) · Caps로 재시도"
                        NSSound.beep()
                    } else {
                        var worst: CGFloat = 0
                        for (i, t) in targets.enumerated() {
                            statusText = String(
                                format: "마우스 %d/%d · 답 %@ (%.2f, %.2f)",
                                t.0, items.count, t.3, t.1, t.2
                            )
                            let miss = await MouseMover.glideToNormalized(
                                x: t.1,
                                y: t.2,
                                imageRect: regionRect,
                                duration: 0.7
                            )
                            worst = max(worst, miss)
                            if i < targets.count - 1 {
                                try? await Task.sleep(nanoseconds: 700_000_000)
                            }
                        }
                        if worst > 40 {
                            statusText = "마우스 \(targets.count)문제 · 일부 이동 실패 (손쉬운 사용 확인)"
                            NSSound.beep()
                        } else {
                            statusText = "마우스 \(targets.count)/\(items.count)문제 순회 완료\(msTag)"
                        }
                    }
                }
            case .notQuestion:
                statusText = "풀 수 있는 문제 아님 · 무시"
                if output == .capsLock { await led.blinkError() }
            case .unclear:
                statusText = "답을 확신할 수 없음"
                if output == .capsLock { await led.blinkError() }
            }
        } catch {
            let msg = error.localizedDescription
            statusText = "오류: \(msg)"
            let lower = msg.lowercased()
            if lower.contains("user not found") || lower.contains("api 키 무효") || lower.contains("키 무효") {
                promptForAPIKey(preface: msg)
            }
        }
    }

    func testMouseMove() async {
        let ax = AXIsProcessTrusted()
        statusText = ax ? "마우스 테스트 중…" : "AX OFF · 그래도 이동 시도…"
        let miss = await MouseMover.nudge(dx: 80, dy: -60)
        if miss > 40 {
            statusText = "마우스 실패 · 손쉬운 사용에서 Solv 삭제 후 다시 ON"
            openAccessibilitySettings()
        } else {
            statusText = String(format: "마우스 OK (오차 %.0fpt, AX=%@)", miss, ax ? "ON" : "OFF")
        }
    }

    func testRaycastType() async {
        let sample = "solv-test"
        let outcome = RaycastTyper.putAnswerReady(sample)
        switch outcome {
        case .ok:
            statusText = "테스트 복사됨(\(sample)) · Raycast 연 뒤 ⌘V"
        case .emptyText:
            statusText = "빈 텍스트"
        }
    }

    /// 단답·복수선택·여러 문제 공통: [1,3] → 1회 깜빡 → 2초 → 3회 깜빡
    private func signalAnswerNumbers(
        _ nums: [Int],
        mode: OutputMode,
        msTag: String,
        itemCount: Int? = nil
    ) async {
        guard !nums.isEmpty else { return }
        let summary = nums.enumerated().map { "\($0.offset + 1)→\($0.element)" }.joined(separator: " ")
        let label = nums.map(String.init).joined(separator: ",")
        if nums.count == 1 {
            let n = nums[0]
            switch mode {
            case .capsLock:
                statusText = "답: \(n) · Caps Lock \(n)회\(msTag)"
                await led.blink(times: n)
                statusText = "답 \(n) Caps 완료\(msTag)"
            case .mouseCursor:
                statusText = "답: \(n) · 마네키네코 \(n)번\(msTag)"
                // 손바닥 마우스 커서 방식 (잠시 주석)
                // await MouseMover.blinkIBeam(times: n)
                await CatAnimator.shared.wave(times: n)
                statusText = "답 \(n) 마네키네코 완료\(msTag)"
            case .handCursor:
                statusText = "답: \(n) · 손바닥 \(n)회\(msTag)"
                await MouseMover.blinkIBeam(times: n)
                statusText = "답 \(n) 손바닥 완료\(msTag)"
            default:
                break
            }
            return
        }
        let kind = itemCount.map { "\($0)문제·선택 \(nums.count)개" } ?? "복수선택 \(label)"
        switch mode {
        case .capsLock:
            statusText = "Caps \(kind) · \(summary) · 사이 2초\(msTag)"
            await led.blinkSequence(nums, pauseSeconds: 2.0)
            statusText = "Caps \(kind) 완료 · \(summary)\(msTag)"
        case .mouseCursor:
            statusText = "마네키네코 \(kind) · \(summary) · 사이 2초\(msTag)"
            // 손바닥 마우스 커서 방식 (잠시 주석)
            // await MouseMover.blinkIBeamSequence(nums, pauseSeconds: 2.0)
            await CatAnimator.shared.waveSequence(nums, pauseSeconds: 2.0)
            statusText = "마네키네코 \(kind) 완료 · \(summary)\(msTag)"
        case .handCursor:
            statusText = "손바닥 \(kind) · \(summary) · 사이 2초\(msTag)"
            await MouseMover.blinkIBeamSequence(nums, pauseSeconds: 2.0)
            statusText = "손바닥 \(kind) 완료 · \(summary)\(msTag)"
        default:
            break
        }
    }
}
