import AppKit

/// 전체 화면 오버레이에서 드래그로 캡처 영역을 고른다.
@MainActor
final class RegionSelector {
    private var overlayWindows: [SelectionOverlayWindow] = []
    private var continuation: CheckedContinuation<CGRect?, Never>?

    /// - Parameter showBorder: false면 회색 선택 테두리를 그리지 않음 (몰래 선택).
    func pick(showBorder: Bool = true) async -> CGRect? {
        cancel()

        return await withCheckedContinuation { cont in
            continuation = cont
            showOverlays(showBorder: showBorder)
        }
    }

    private func showOverlays(showBorder: Bool) {
        overlayWindows = NSScreen.screens.map { screen in
            let w = SelectionOverlayWindow(screen: screen, showBorder: showBorder)
            w.onComplete = { [weak self] rect in
                self?.finish(rect)
            }
            w.onCancel = { [weak self] in
                self?.finish(nil)
            }
            w.makeKeyAndOrderFront(nil)
            return w
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func finish(_ rect: CGRect?) {
        for w in overlayWindows { w.orderOut(nil) }
        overlayWindows.removeAll()
        continuation?.resume(returning: rect)
        continuation = nil
    }

    private func cancel() {
        if continuation != nil {
            finish(nil)
        }
    }
}

private final class SelectionOverlayWindow: NSWindow {
    var onComplete: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?

    private let selectionView: SelectionView

    init(screen: NSScreen, showBorder: Bool) {
        selectionView = SelectionView(showBorder: showBorder)
        super.init(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        ignoresMouseEvents = false
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        setFrame(screen.frame, display: true)
        contentView = selectionView
        selectionView.onDragEnded = { [weak self] rectInWindow in
            guard let self, rectInWindow.width >= 4, rectInWindow.height >= 4 else {
                self?.onCancel?()
                return
            }
            let screenRect = self.convertToScreen(rectInWindow)
            self.onComplete?(screenRect)
        }
        selectionView.onCancel = { [weak self] in
            self?.onCancel?()
        }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private final class SelectionView: NSView {
    var onDragEnded: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?

    private let showBorder: Bool
    private var startPoint: CGPoint?
    private var currentPoint: CGPoint?
    private var monitor: Any?

    init(showBorder: Bool) {
        self.showBorder = showBorder
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            window?.makeFirstResponder(self)
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                if event.keyCode == 53 { // Esc
                    self?.onCancel?()
                    return nil
                }
                return event
            }
        } else if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard showBorder, let start = startPoint, let current = currentPoint else { return }

        let rect = CGRect(
            x: min(start.x, current.x),
            y: min(start.y, current.y),
            width: abs(current.x - start.x),
            height: abs(current.y - start.y)
        )

        NSColor.systemGray.setStroke()
        let border = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 2
        border.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        startPoint = convert(event.locationInWindow, from: nil)
        currentPoint = startPoint
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        currentPoint = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        currentPoint = convert(event.locationInWindow, from: nil)
        needsDisplay = true
        guard let start = startPoint, let current = currentPoint else {
            onCancel?()
            return
        }
        let rect = CGRect(
            x: min(start.x, current.x),
            y: min(start.y, current.y),
            width: abs(current.x - start.x),
            height: abs(current.y - start.y)
        )
        onDragEnded?(rect)
        startPoint = nil
        currentPoint = nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
