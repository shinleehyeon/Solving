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
    @Published var apiKeyInput = ""
    @Published var selectedModel: SolvModel = SolvModel.current {
        didSet {
            SolvModel.current = selectedModel
            statusText = "모델: \(selectedModel.title)"
        }
    }

    private let hotkey = HotkeyMonitor()
    private let capture = ScreenCapture()
    private let solver = QuestionSolver()
    private let led = CapsLockLED()
    private let regionSelector = RegionSelector()

    init() {
        hotkeyEnabled = UserDefaults.standard.object(forKey: "hotkeyEnabled") as? Bool ?? true
        apiKeyInput = KeychainStore.loadAPIKey() ?? ""
        selectedModel = SolvModel.current
        Task { @MainActor in
            self.start()
        }
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
                    await self?.solve(capture: .region, output: .capsLock, showBorder: false)
                case .mouseFullScreen:
                    await self?.solve(capture: .fullScreen, output: .mouse)
                case .mouseRegion:
                    await self?.solve(capture: .region, output: .mouse, showBorder: true)
                case .mouseRegionHidden:
                    await self?.solve(capture: .region, output: .mouse, showBorder: false)
                case .raycastRegion:
                    await self?.solve(capture: .region, output: .raycast, showBorder: true)
                case .raycastRegionHidden:
                    await self?.solve(capture: .region, output: .raycast, showBorder: false)
                case .raycastFullScreen:
                    await self?.solve(capture: .fullScreen, output: .raycast)
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
        KeychainStore.saveAPIKey(apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines))
        statusText = "API 키 저장됨 · ⌘⌥ 영역 / ⌘⌥C 전체"
    }

    func promptForAPIKey() {
        let alert = NSAlert()
        alert.messageText = "API 키"
        alert.informativeText = "OpenAI(sk-...) 또는 OpenRouter(sk-or-v1-...) 키를 입력하세요."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = apiKeyInput
        alert.accessoryView = field
        alert.addButton(withTitle: "저장")
        alert.addButton(withTitle: "취소")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            apiKeyInput = field.stringValue
            saveAPIKey()
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
        case raycast
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
        if (output == .mouse || output == .raycast), !axOK {
            statusText = "손쉬운 사용 OFF · 이동/타이핑에 필요할 수 있음"
        }

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

        statusText = output == .mouse ? "문제 분석·위치 확인 중…" : "문제 분석 중…"
        do {
            let result = try await solver.solve(
                image: image,
                apiKey: apiKey,
                needLocation: output == .mouse
            )
            switch result {
            case .mcq(let n, let x, let y, let typeText):
                switch output {
                case .capsLock:
                    statusText = "답: \(n) · Caps Lock \(n)회"
                    await led.blink(times: n)
                    statusText = "답 \(n) Caps 완료"
                case .mouse:
                    statusText = String(format: "답 %d · OCR→마우스 (%.2f, %.2f)", n, x, y)
                    let miss = await MouseMover.glideToNormalized(x: x, y: y, imageRect: regionRect)
                    if miss > 40 {
                        statusText = "답 \(n) · 커서 이동 실패 (손쉬운 사용에서 Solv ON 후 재실행)"
                        NSSound.beep()
                    } else {
                        statusText = String(format: "답 %d 마우스 완료 · 오차 %.0fpt", n, miss)
                    }
                case .raycast:
                    let outcome = RaycastTyper.putAnswerReady(typeText)
                    switch outcome {
                    case .ok:
                        statusText = "답 \(typeText) 복사됨 · Raycast 연 뒤 ⌘V"
                    case .emptyText:
                        statusText = "타이핑할 답이 비어 있음"
                    }
                }
            case .open(let typeText):
                switch output {
                case .raycast:
                    let outcome = RaycastTyper.putAnswerReady(typeText)
                    switch outcome {
                    case .ok:
                        statusText = "주관식 복사됨 · Raycast 연 뒤 ⌘V"
                    case .emptyText:
                        statusText = "타이핑할 답이 비어 있음"
                    }
                case .capsLock, .mouse:
                    statusText = "주관식 답: \(typeText) · Raycast 모드(⌘⇧) 사용"
                    if output == .capsLock { await led.blinkError() }
                }
            case .notQuestion:
                statusText = "풀 수 있는 문제 아님 · 무시"
                if output == .capsLock { await led.blinkError() }
            case .unclear:
                statusText = "답을 확신할 수 없음"
                if output == .capsLock { await led.blinkError() }
            }
        } catch {
            statusText = "오류: \(error.localizedDescription)"
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
}
