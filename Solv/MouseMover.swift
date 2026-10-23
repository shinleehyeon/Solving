import AppKit
import CoreGraphics
import Foundation

/// 손바닥 깜빡 타이밍 — 단위 테스트와 앱이 같은 값을 씀.
enum HandBlinkTiming {
    static let maxTimes = QuestionSolver.maxOptions
    /// 창이 커서 소유권을 잡기 전 대기
    static let warmupMs: UInt64 = 140
    static let offMs: UInt64 = 180
    /// 마지막 펄스 후 창 닫기 전
    static let settleMs: UInt64 = 120
    /// 여러 번일 때 on
    static let multiOnMs: UInt64 = 400
    /// 1회만이면 놓치기 쉬워 더 길게
    static let singleOnMs: UInt64 = 600

    static func clampTimes(_ times: Int) -> Int {
        max(1, min(times, maxTimes))
    }

    static func onMs(forCount n: Int) -> UInt64 {
        clampTimes(n) == 1 ? singleOnMs : multiOnMs
    }

    /// hand=true 이벤트 개수 == clamp(times)
    static func handOnCount(times: Int) -> Int {
        clampTimes(times)
    }

    /// (손바닥?, 유지 ms) 시퀀스. 마지막은 항상 화살표 settle.
    static func pulsePlan(times: Int) -> [(hand: Bool, holdMs: UInt64)] {
        let n = clampTimes(times)
        let on = onMs(forCount: n)
        var plan: [(Bool, UInt64)] = []
        for i in 0..<n {
            plan.append((true, on))
            if i < n - 1 {
                plan.append((false, offMs))
            }
        }
        plan.append((false, settleMs))
        return plan
    }

    static func totalHoldMs(times: Int) -> UInt64 {
        pulsePlan(times: times).reduce(0) { $0 + $1.holdMs }
    }
}

enum MouseMover {
    /// 마지막 손바닥 펄스 로그 (진단/테스트용)
    private(set) static var lastBlinkLog: String = ""

    /// 시스템 커서를 손바닥(openHand)으로 N번 바꿈.
    @MainActor
    static func blinkIBeam(times: Int) async {
        let n = HandBlinkTiming.clampTimes(times)
        let owner = SystemCursorOwner()
        owner.begin()
        try? await Task.sleep(nanoseconds: HandBlinkTiming.warmupMs * 1_000_000)
        owner.forceApply()
        await pulseHand(owner: owner, times: n)
        owner.end()
        lastBlinkLog = "hand×\(n) onMs=\(HandBlinkTiming.onMs(forCount: n))"
    }

    /// 여러 문제: 딱딱딱 → pause → 딱딱딱
    @MainActor
    static func blinkIBeamSequence(_ answers: [Int], pauseSeconds: Double = 2.0) async {
        let gapNs = UInt64(max(0.5, pauseSeconds) * 1_000_000_000)
        let owner = SystemCursorOwner()
        owner.begin()
        try? await Task.sleep(nanoseconds: HandBlinkTiming.warmupMs * 1_000_000)
        owner.forceApply()
        var parts: [String] = []
        for (i, raw) in answers.enumerated() {
            let n = HandBlinkTiming.clampTimes(raw)
            await pulseHand(owner: owner, times: n)
            parts.append("\(n)")
            if i < answers.count - 1 {
                owner.setHand(false)
                try? await Task.sleep(nanoseconds: gapNs)
            }
        }
        owner.end()
        lastBlinkLog = "seq[\(parts.joined(separator: ","))]"
    }

    /// 메뉴 테스트: 1회 → 쉼 → 2회 (눈으로 확인하기 쉽게)
    @MainActor
    static func testBlinkVisible() async {
        await blinkIBeam(times: 1)
        try? await Task.sleep(nanoseconds: 900_000_000)
        await blinkIBeam(times: 2)
    }

    @MainActor
    private static func pulseHand(owner: SystemCursorOwner, times: Int) async {
        let plan = HandBlinkTiming.pulsePlan(times: times)
        for step in plan {
            owner.setHand(step.hand)
            try? await Task.sleep(nanoseconds: step.holdMs * 1_000_000)
        }
    }

    /// 이미지(좌상단 원점) 정규화 좌표 → 화면으로 **경로를 보이며** 이동.
    /// - Returns: 이동 후 커서와 목표 사이 거리(포인트). 크면 권한/차단 의심.
    @discardableResult
    static func glideToNormalized(
        x nx: Double,
        y ny: Double,
        imageRect: CGRect?,
        duration: TimeInterval = 1.0
    ) async -> CGFloat {
        let targetAppKit = appKitPoint(nx: min(1, max(0, nx)), ny: min(1, max(0, ny)), imageRect: imageRect)
        await glideAppKit(to: targetAppKit, duration: duration)
        let now = NSEvent.mouseLocation
        return hypot(now.x - targetAppKit.x, now.y - targetAppKit.y)
    }

    /// 권한/이동 진단용: 현재 위치에서 (dx,dy)만큼 이동.
    @discardableResult
    static func nudge(dx: CGFloat, dy: CGFloat) async -> CGFloat {
        let start = NSEvent.mouseLocation
        let target = CGPoint(x: start.x + dx, y: start.y + dy)
        await glideAppKit(to: target, duration: 0.45)
        let now = NSEvent.mouseLocation
        return hypot(now.x - target.x, now.y - target.y)
    }

    // MARK: - coordinate mapping (AppKit space)

    /// Vision 좌표(이미지 상단 원점) → AppKit 스크린 좌표(하단 원점)
    static func appKitPoint(nx: Double, ny: Double, imageRect: CGRect?) -> CGPoint {
        if let rect = imageRect, rect.width > 1, rect.height > 1 {
            return CGPoint(
                x: rect.minX + nx * rect.width,
                y: rect.maxY - ny * rect.height
            )
        }

        let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == CGMainDisplayID()
        }) ?? NSScreen.main ?? NSScreen.screens[0]

        let frame = screen.frame
        return CGPoint(
            x: frame.minX + nx * frame.width,
            y: frame.maxY - ny * frame.height
        )
    }

    static func appKitToQuartz(_ p: CGPoint) -> CGPoint {
        let h = NSScreen.screens.map(\.frame.maxY).max() ?? 0
        return CGPoint(x: p.x, y: h - p.y)
    }

    // MARK: - visible path

    private static func glideAppKit(to target: CGPoint, duration: TimeInterval) async {
        // 오버레이/모달이 막 닫힌 뒤 이벤트 탭이 먹을 수 있어 짧게 양보
        try? await Task.sleep(nanoseconds: 80_000_000)

        let start = NSEvent.mouseLocation
        let dx = target.x - start.x
        let dy = target.y - start.y
        let dist = hypot(dx, dy)

        guard dist > 2 else {
            warpAppKit(target)
            return
        }

        let dur = max(0.7, duration)
        let steps = max(40, min(100, Int(dist / 5)))
        let frameNs = UInt64((dur / Double(steps)) * 1_000_000_000)

        let mid = CGPoint(x: (start.x + target.x) / 2, y: (start.y + target.y) / 2)
        let perpX = -dy / dist
        let perpY = dx / dist
        let bend = min(60, dist * 0.1)
        let control = CGPoint(x: mid.x + perpX * bend, y: mid.y + perpY * bend)

        for i in 1...steps {
            let t = easeInOut(Double(i) / Double(steps))
            let p = bezier(start, control, target, t: t)
            warpAppKit(p)
            if i < steps {
                try? await Task.sleep(nanoseconds: frameNs)
            }
        }
        warpAppKit(target)
        // 최종 위치 한 번 더 고정
        try? await Task.sleep(nanoseconds: 20_000_000)
        warpAppKit(target)
    }

    private static func warpAppKit(_ appKit: CGPoint) {
        let q = appKitToQuartz(appKit)
        CGWarpMouseCursorPosition(q)
        CGAssociateMouseAndMouseCursorPosition(boolean_t(1))

        let source = CGEventSource(stateID: .hidSystemState)
        if let move = CGEvent(
            mouseEventSource: source,
            mouseType: .mouseMoved,
            mouseCursorPosition: q,
            mouseButton: .left
        ) {
            move.post(tap: .cghidEventTap)
        }
        if let move = CGEvent(
            mouseEventSource: source,
            mouseType: .mouseMoved,
            mouseCursorPosition: q,
            mouseButton: .left
        ) {
            move.post(tap: .cgSessionEventTap)
        }
    }

    private static func easeInOut(_ t: Double) -> Double {
        t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    }

    private static func bezier(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, t: Double) -> CGPoint {
        let u = 1 - t
        return CGPoint(
            x: u * u * a.x + 2 * u * t * b.x + t * t * c.x,
            y: u * u * a.y + 2 * u * t * b.y + t * t * c.y
        )
    }
}

/// 투명 창으로 커서 소유권을 가져와 NSCursor.openHand(손바닥)를 적용.
@MainActor
private final class SystemCursorOwner {
    private var windows: [NSWindow] = []
    private(set) var wantHand = false

    func begin() {
        NSApp.activate(ignoringOtherApps: true)
        NSCursor.setHiddenUntilMouseMoves(false)
        NSCursor.unhide()
        windows = NSScreen.screens.map { screen in
            let w = NSPanel(
                contentRect: screen.frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.level = .screenSaver
            w.ignoresMouseEvents = false
            w.acceptsMouseMovedEvents = true
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            w.setFrame(screen.frame, display: true)
            let host = CursorOwnerView(frame: NSRect(origin: .zero, size: screen.frame.size))
            host.owner = self
            w.contentView = host
            w.orderFrontRegardless()
            return w
        }
        windows.first?.makeKey()
        setHand(false)
        forceApply()
    }

    func setHand(_ on: Bool) {
        wantHand = on
        forceApply()
    }

    /// 커서 rect 갱신 + 미세 워프로 AppKit이 커서를 다시 그리게 함.
    func forceApply() {
        let cursor = wantHand ? NSCursor.openHand : NSCursor.arrow
        for w in windows {
            if let v = w.contentView {
                w.invalidateCursorRects(for: v)
            }
        }
        cursor.set()
        // 위치는 유지한 채 워프만 — cursorUpdate 유도
        let p = NSEvent.mouseLocation
        let h = NSScreen.screens.map(\.frame.maxY).max() ?? 0
        let q = CGPoint(x: p.x, y: h - p.y)
        CGWarpMouseCursorPosition(q)
        cursor.set()
    }

    func end() {
        wantHand = false
        NSCursor.arrow.set()
        for w in windows {
            w.orderOut(nil)
        }
        windows.removeAll()
    }
}

private final class CursorOwnerView: NSView {
    weak var owner: SystemCursorOwner?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
        let tracking = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .cursorUpdate, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(tracking)
    }

    override func resetCursorRects() {
        let cursor = (owner?.wantHand == true) ? NSCursor.openHand : NSCursor.arrow
        addCursorRect(bounds, cursor: cursor)
    }

    override func cursorUpdate(with event: NSEvent) {
        if owner?.wantHand == true {
            NSCursor.openHand.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    override func mouseMoved(with event: NSEvent) {
        if owner?.wantHand == true {
            NSCursor.openHand.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
