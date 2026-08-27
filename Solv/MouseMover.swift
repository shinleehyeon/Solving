import AppKit
import CoreGraphics
import Foundation

enum MouseMover {
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
