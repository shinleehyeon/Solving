import AppKit
import Foundation

enum HotkeyAction {
    case capsRegion          // ⌘⌥ (회색 테두리)
    case capsRegionHidden    // ⌘⌥⌃ (테두리 없음)
    case capsFullScreen      // ⌘⌥C
    case mouseRegion         // ⌘⌃
    case mouseRegionHidden   // ⌘⌥⌃Fn (테두리 없음 · 마우스)
    case mouseFullScreen     // ⌘⌃C
}

/// ⌘⌥ = Caps 영역 / ⌘⌥⌃ = Caps 영역(선 없음) / ⌘⌥⌃Fn = 마우스 영역(선 없음)
/// ⌘⌥C = Caps 전체 / ⌘⌃ = 마우스 영역 / ⌘⌃C = 마우스 전체
final class HotkeyMonitor {
    var onAction: ((HotkeyAction) -> Void)?

    private var flagMonitor: Any?
    private var keyMonitor: Any?
    private var localFlagMonitor: Any?
    private var localKeyMonitor: Any?
    private var enabled = true

    private enum Armed {
        case none
        case caps
        case capsHidden
        case mouseHidden
        case mouse
    }

    private var armed: Armed = .none
    private var consumedKey = false
    /// deviceIndependentFlagsMask에 Fn이 빠진 기기 대비
    private var fnHeld = false

    func setEnabled(_ value: Bool) {
        enabled = value
        if !value {
            armed = .none
            consumedKey = false
            fnHeld = false
        }
    }

    func start() {
        stop()

        flagMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] e in
            self?.handleFlags(e)
        }
        localFlagMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] e in
            self?.handleFlags(e)
            return e
        }

        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] e in
            self?.handleKeyDown(e)
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if self?.handleKeyDown(e) == true { return nil }
            return e
        }
    }

    func stop() {
        for m in [flagMonitor, keyMonitor, localFlagMonitor, localKeyMonitor] {
            if let m { NSEvent.removeMonitor(m) }
        }
        flagMonitor = nil
        keyMonitor = nil
        localFlagMonitor = nil
        localKeyMonitor = nil
    }

    @discardableResult
    private func handleKeyDown(_ event: NSEvent) -> Bool {
        guard enabled, !event.isARepeat else { return false }
        guard event.keyCode == 8 else { return false } // C

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let cmd = flags.contains(.command)
        let opt = flags.contains(.option)
        let ctrl = flags.contains(.control)
        let shift = flags.contains(.shift)

        if cmd && opt && !ctrl && !shift {
            consumedKey = true
            onAction?(.capsFullScreen)
            return true
        }
        if cmd && ctrl && !opt && !shift {
            consumedKey = true
            onAction?(.mouseFullScreen)
            return true
        }
        return false
    }

    private func updateFnHeld(from event: NSEvent) {
        // keyCode 63 = Fn (flagsChanged)
        if event.keyCode == 63 {
            fnHeld = event.modifierFlags.contains(.function)
        } else if event.modifierFlags.contains(.function) {
            fnHeld = true
        } else if !event.modifierFlags.contains(.function) {
            // 다른 수식어만 바뀌었는데 function 비트가 없으면 해제
            // (단, 일부 맥은 Fn을 이 비트로만 보고함)
            fnHeld = false
        }
    }

    private func handleFlags(_ event: NSEvent) {
        guard enabled else { return }

        updateFnHeld(from: event)

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let cmd = flags.contains(.command)
        let opt = flags.contains(.option)
        let ctrl = flags.contains(.control)
        let shift = flags.contains(.shift)
        let fn = fnHeld || event.modifierFlags.contains(.function)

        // 우선순위: ⌘⌥⌃Fn > ⌘⌥⌃ > ⌘⌥ > ⌘⌃
        let mouseHiddenCombo = cmd && opt && ctrl && fn && !shift
        let capsHiddenCombo = cmd && opt && ctrl && !fn && !shift
        let capsCombo = cmd && opt && !ctrl && !shift
        let mouseCombo = cmd && ctrl && !opt && !shift

        if mouseHiddenCombo {
            if armed != .mouseHidden {
                armed = .mouseHidden
                consumedKey = false
            }
            return
        }

        // Fn을 떼서 ⌘⌥⌃ 만 남김 → 마우스 숨김 발화 후 재무장하지 않음
        if armed == .mouseHidden {
            let shouldFire = !consumedKey
            armed = .none
            consumedKey = false
            if shouldFire { onAction?(.mouseRegionHidden) }
            return
        }

        if capsHiddenCombo {
            if armed != .capsHidden {
                armed = .capsHidden
                consumedKey = false
            }
            return
        }

        if armed == .capsHidden {
            let shouldFire = !consumedKey
            armed = .none
            consumedKey = false
            if shouldFire { onAction?(.capsRegionHidden) }
            return
        }

        if capsCombo {
            if armed != .caps {
                armed = .caps
                consumedKey = false
            }
            return
        }
        if mouseCombo {
            if armed != .mouse {
                armed = .mouse
                consumedKey = false
            }
            return
        }

        let previous = armed
        let shouldFire = !consumedKey
        armed = .none
        consumedKey = false

        guard shouldFire else { return }
        switch previous {
        case .caps:
            onAction?(.capsRegion)
        case .mouse:
            onAction?(.mouseRegion)
        case .capsHidden, .mouseHidden, .none:
            break
        }
    }

    deinit { stop() }
}
