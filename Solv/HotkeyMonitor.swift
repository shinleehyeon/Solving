import AppKit
import Foundation

enum HotkeyAction {
    case capsRegion          // (메뉴용) 예전 ⌘⌥ — 단축키는 I‑beam으로 변경
    case capsRegionHidden    // ⌘⌥⌃
    case capsFullScreen      // ⌘⌥C
    case mouseRegion         // ⌘⌃ — OCR 이동
    case mouseRegionHidden   // ⌘⌥⌃Fn
    case mouseFullScreen     // ⌘⌃C
    case mouseCursorRegion   // ⌘⌥ — I‑beam 횟수 (선 없음) / ⌘⌃⇧ 동일
    case raycastRegion       // ⌘⇧
    case raycastRegionHidden // ⌘⇧⌥
    case raycastFullScreen   // ⌘⇧C
    case raycastExplainHidden // ⌘⌥⌃Fn⇧ — 선 없음 · 답+설명 클립보드
}

/// ⌘⌥ = I‑beam 횟수(선 없음) / ⌘⌥⌃Fn⇧ = 선 없음+설명
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
        case mouseCursor
        case raycast
        case raycastHidden
        case raycastExplain
    }

    private var armed: Armed = .none
    private var consumedKey = false
    private var fnHeld = false
    private var suppressChordRegionUntil: Date?

    func setEnabled(_ value: Bool) {
        enabled = value
        if !value {
            armed = .none
            consumedKey = false
            fnHeld = false
            suppressChordRegionUntil = nil
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

        if cmd && shift && !opt && !ctrl {
            markChordConsumed()
            onAction?(.raycastFullScreen)
            return true
        }
        if cmd && opt && !ctrl && !shift {
            markChordConsumed()
            onAction?(.capsFullScreen)
            return true
        }
        if cmd && ctrl && !opt && !shift {
            markChordConsumed()
            onAction?(.mouseFullScreen)
            return true
        }
        return false
    }

    private func markChordConsumed() {
        armed = .none
        consumedKey = true
        suppressChordRegionUntil = Date().addingTimeInterval(0.6)
    }

    private func updateFnHeld(from event: NSEvent) {
        if event.keyCode == 63 {
            fnHeld = event.modifierFlags.contains(.function)
        } else if event.modifierFlags.contains(.function) {
            fnHeld = true
        } else if !event.modifierFlags.contains(.function) {
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
        let fn = fnHeld || flags.contains(.function)

        // 가장 많은 modifier부터
        let explainCombo = cmd && opt && ctrl && fn && shift
        let mouseHiddenCombo = cmd && opt && ctrl && fn && !shift
        let capsHiddenCombo = cmd && opt && ctrl && !fn && !shift
        let mouseCursorCombo = cmd && ctrl && shift && !opt && !fn
        let raycastHiddenCombo = cmd && shift && opt && !ctrl
        let capsCombo = cmd && opt && !ctrl && !shift
        let mouseCombo = cmd && ctrl && !opt && !shift
        let raycastCombo = cmd && shift && !opt && !ctrl

        let suppressActive = suppressChordRegionUntil.map { Date() < $0 } ?? false

        if explainCombo {
            if suppressActive { return }
            if armed != .raycastExplain {
                armed = .raycastExplain
                consumedKey = false
            }
            return
        }

        if armed == .raycastExplain {
            let shouldFire = !consumedKey
            armed = .none
            consumedKey = false
            if shouldFire { onAction?(.raycastExplainHidden) }
            return
        }

        if mouseHiddenCombo {
            if armed != .mouseHidden {
                armed = .mouseHidden
                consumedKey = false
            }
            return
        }

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

        if mouseCursorCombo {
            if suppressActive { return }
            if armed != .mouseCursor {
                armed = .mouseCursor
                consumedKey = false
            }
            return
        }

        if armed == .mouseCursor {
            let shouldFire = !consumedKey
            armed = .none
            consumedKey = false
            if shouldFire { onAction?(.mouseCursorRegion) }
            return
        }

        if raycastHiddenCombo {
            if suppressActive { return }
            if armed != .raycastHidden {
                armed = .raycastHidden
                consumedKey = false
            }
            return
        }

        if armed == .raycastHidden {
            let shouldFire = !consumedKey
            armed = .none
            consumedKey = false
            if shouldFire { onAction?(.raycastRegionHidden) }
            return
        }

        if raycastCombo {
            if suppressActive { return }
            if armed != .raycast {
                armed = .raycast
                consumedKey = false
            }
            return
        }

        if capsCombo {
            if suppressActive { return }
            if armed != .caps {
                armed = .caps
                consumedKey = false
            }
            return
        }
        if mouseCombo {
            if suppressActive { return }
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
        if let until = suppressChordRegionUntil, Date() < until {
            return
        }
        switch previous {
        case .caps:
            // ⌘⌥ → I‑beam 횟수 (회색선 없음)
            onAction?(.mouseCursorRegion)
        case .mouse:
            onAction?(.mouseRegion)
        case .raycast:
            onAction?(.raycastRegion)
        case .capsHidden, .mouseHidden, .mouseCursor, .raycastHidden, .raycastExplain, .none:
            break
        }
    }

    deinit { stop() }
}
