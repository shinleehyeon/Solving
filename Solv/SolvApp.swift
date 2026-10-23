import AppKit
import Combine
import SwiftUI

@main
struct SolvApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Settings {
            SettingsView(appState: delegate.appState)
        }
    }
}

/// 메뉴바는 SwiftUI MenuBarExtra 대신 NSStatusItem + NSMenu.
/// (MenuBarExtra는 라벨이 바뀔 때마다 열린 메뉴까지 다시 그려서 고양이 애니메이션 중 깜빡임)
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()
    private var statusBar: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusBar = StatusBarController(appState: appState)
    }
}

@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private let appState: AppState
    private let cat = CatAnimator.shared
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var bag = Set<AnyCancellable>()
    private var mainPopover: NSPopover?

    init(appState: AppState) {
        self.appState = appState
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        // 왼쪽 클릭 = 캐러셀 팝오버, 오른쪽 클릭 = 기존 메뉴 (statusItem.menu 는 평소 nil)

        if let button = statusItem.button {
            button.imagePosition = .imageOnly
            button.image = cat.image
            button.target = self
            button.action = #selector(statusClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        // 프레임만 button.image 로 바꿔 끼운다. SwiftUI 뷰/메뉴는 건드리지 않음.
        cat.$image
            .sink { [weak self] img in self?.statusItem.button?.image = img }
            .store(in: &bag)
        appState.$isBusy
            .sink { [weak self] busy in self?.cat.setBusy(busy) }
            .store(in: &bag)

        // 시스템 수치: 메뉴바 글자 + CPU 연동 속도
        let monitor = SystemMonitor.shared
        let prefs = RunCatPrefs.shared
        monitor.start()
        monitor.$snapshot
            .combineLatest(prefs.$metric, prefs.$cpuLinkedSpeed)
            .sink { [weak self] snap, metric, linked in
                self?.updateTitle(snap, metric)
                self?.cat.setCPU(linked ? snap.cpu : nil)
            }
            .store(in: &bag)
    }

    private func updateTitle(_ snap: SystemSnapshot, _ metric: MenuBarMetric) {
        guard let button = statusItem.button else { return }
        if metric == .none {
            button.title = ""
            button.imagePosition = .imageOnly
            return
        }
        button.imagePosition = .imageLeft
        button.attributedTitle = NSAttributedString(
            string: " " + metric.text(snap),
            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)]
        )
    }

    @objc private func statusClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            statusItem.menu = menu
            sender.performClick(nil)
            statusItem.menu = nil
        } else {
            toggleCarousel()
        }
    }

    private func toggleCarousel() {
        if let p = mainPopover, p.isShown {
            p.performClose(nil)
            return
        }
        guard let button = statusItem.button else { return }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: CarouselView.size.width, height: CarouselView.size.height)
        popover.contentViewController = NSHostingController(rootView: CarouselView(
            appState: appState,
            close: { [weak popover] in popover?.performClose(nil) },
            openSettings: { [weak self] in self?.openSettings() }
        ))
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        mainPopover = popover
    }

    // MARK: - 메뉴 (열 때마다 새로 만들어 상태 반영)

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let state = appState

        let status = NSMenuItem(title: state.statusText, action: nil, keyEquivalent: "")
        status.isEnabled = false
        status.attributedTitle = NSAttributedString(
            string: state.statusText,
            attributes: [.font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
                         .foregroundColor: NSColor.secondaryLabelColor]
        )
        menu.addItem(status)
        menu.addItem(.separator())

        menu.addItem(action("설정…") { [weak self] in self?.openSettings() })
        menu.addItem(.separator())

        menu.addItem(submenu("실행", enabled: !state.isBusy) { m in
            m.addItem(.sectionHeader(title: "Caps Lock"))
            m.addItem(self.action("영역 · 선 없음") { Task { await state.solve(capture: .region, output: .capsLock, showBorder: false) } })
            m.addItem(self.action("전체 화면") { Task { await state.solve(capture: .fullScreen, output: .capsLock) } })

            m.addItem(.sectionHeader(title: "마우스"))
            m.addItem(self.action("영역 · 마우스 포인터 손바닥 횟수 (선 없음)") { Task { await state.solve(capture: .region, output: .handCursor, showBorder: false) } })
            m.addItem(self.action("영역 · 마네키네코 손짓 횟수 (선 없음)") { Task { await state.solve(capture: .region, output: .mouseCursor, showBorder: false) } })
            m.addItem(self.action("영역 · 회색선 (OCR 이동)") { Task { await state.solve(capture: .region, output: .mouse, showBorder: true) } })
            m.addItem(self.action("영역 · 선 없음 (OCR 이동)") { Task { await state.solve(capture: .region, output: .mouse, showBorder: false) } })
            m.addItem(self.action("전체 화면 (OCR 이동)") { Task { await state.solve(capture: .fullScreen, output: .mouse) } })

            m.addItem(.sectionHeader(title: "클립보드 (Raycast ⌘V)"))
            m.addItem(self.action("영역 · 회색선") { Task { await state.solve(capture: .region, output: .raycast, showBorder: true) } })
            m.addItem(self.action("영역 · 선 없음") { Task { await state.solve(capture: .region, output: .raycast, showBorder: false) } })
            m.addItem(self.action("영역 · 선 없음 · 답+설명") { Task { await state.solve(capture: .region, output: .raycastExplain, showBorder: false) } })
            m.addItem(self.action("전체 화면") { Task { await state.solve(capture: .fullScreen, output: .raycast) } })
        })

        menu.addItem(submenu("단축키") { m in
            func info(_ t: String) { let i = NSMenuItem(title: t, action: nil, keyEquivalent: ""); i.isEnabled = false; m.addItem(i) }
            m.addItem(.sectionHeader(title: "마네키네코 (여러 문제 → 흔들흔들 · 2초 쉼)"))
            info("⌘⌥ — 영역 · 선 없음 · 손 N번")
            m.addItem(.sectionHeader(title: "마우스 포인터 손바닥 (여러 문제 → 딱딱딱 · 2초 쉼)"))
            info("⌘⌥⌃ — 영역 · 선 없음 · 손바닥 N회")
            m.addItem(.sectionHeader(title: "Caps"))
            info("⌘⌥C — 전체")
            m.addItem(.sectionHeader(title: "마우스 OCR 이동"))
            info("⌘⌃ — 영역 · 회색선")
            info("⌘⌥⌃Fn — 영역 · 선 없음")
            info("⌘⌃C — 전체")
            m.addItem(.sectionHeader(title: "클립보드"))
            info("⌘⇧ — 영역 · 회색선")
            info("⌘⇧⌥ — 영역 · 선 없음")
            info("⌘⌥⌃Fn⇧ — 선 없음 · 답+선지+설명")
            info("⌘⇧C — 전체")
            info("복사만 · Raycast는 직접 연 뒤 ⌘V")
        })

        menu.addItem(.separator())

        menu.addItem(action("단축키 사용", checked: state.hotkeyEnabled) { state.hotkeyEnabled.toggle() })
        menu.addItem(action("정밀 모드 (느리지만 정확)", checked: state.preciseMode) { state.preciseMode.toggle() })

        menu.addItem(action("러너: \(cat.style.title)…") { [weak self] in self?.showRunnerPicker() })

        let catalog = SolvModelCatalog.shared
        menu.addItem(submenu("모델: \(state.selectedModel.shortTitle)") { m in
            m.addItem(.sectionHeader(title: "즐겨찾기"))
            for model in catalog.favorites {
                m.addItem(self.action(model.shortTitle, checked: model.id == catalog.selectedId) { state.selectModel(model) })
            }
            m.addItem(.separator())
            m.addItem(self.action("전체 모델 목록 새로고침") { Task { await catalog.refresh() } })
            let count = NSMenuItem(title: "전체 \(catalog.models.count)개 · 설정에서 검색", action: nil, keyEquivalent: "")
            count.isEnabled = false
            m.addItem(count)
        })

        menu.addItem(.separator())

        menu.addItem(submenu("도구") { m in
            m.addItem(self.action("API 키 설정…") { state.promptForAPIKey() })
            m.addItem(self.action("API 키 연결 테스트") { Task { await state.testAPIKey() } })
            m.addItem(self.action("화면 녹화 다시 연결…") { state.showPermissionRepairGuide() })
            m.addItem(self.action("캡처 진단…") { Task { await state.runCaptureDiagnose() } })
            m.addItem(.separator())
            m.addItem(self.action("Caps Lock 테스트 (2회)") { Task { await state.testCapsLock() } })
            m.addItem(self.action("마네키네코 테스트 (1→2)") { Task { await state.testManeki() } })
            m.addItem(self.action("손바닥 커서 테스트 (1→2)") { Task { await state.testHandCursor() } })
            m.addItem(self.action("마우스 이동 테스트") { Task { await state.testMouseMove() } })
            m.addItem(self.action("클립보드 테스트") { Task { await state.testRaycastType() } })
            m.addItem(self.action("마지막 전송 이미지 열기") { state.openLastCaptureImage() })
        })

        menu.addItem(.separator())
        menu.addItem(action("종료") { NSApplication.shared.terminate(nil) })
    }

    /// 메뉴가 닫힌 뒤 상태바 아이콘 아래에 선택 창을 띄운다.
    private func showRunnerPicker() {
        DispatchQueue.main.async { [self] in
            guard let button = statusItem.button else { return }
            let popover = NSPopover()
            popover.behavior = .transient
            popover.contentViewController = NSHostingController(rootView: RunnerPicker())
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    // MARK: - 메뉴 헬퍼

    private func action(_ title: String, checked: Bool = false, handler: @escaping () -> Void) -> NSMenuItem {
        let item = ClosureMenuItem(title: title, handler: handler)
        item.state = checked ? .on : .off
        return item
    }

    private func submenu(_ title: String, enabled: Bool = true, build: (NSMenu) -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let sub = NSMenu(title: title)
        sub.autoenablesItems = false
        build(sub)
        item.submenu = sub
        item.isEnabled = enabled
        return item
    }
}

private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() { handler() }
}
