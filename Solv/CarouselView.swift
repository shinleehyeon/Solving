import AppKit
import SwiftUI

/// 아이콘을 누르면 뜨는 팝오버. 좌우로 넘겨 Solv 화면 ↔ RunCat 화면을 본다.
struct CarouselView: View {
    static let size = CGSize(width: 340, height: 500)

    @ObservedObject var appState: AppState
    let close: () -> Void
    let openSettings: () -> Void

    @State private var page = 0
    @State private var drag: CGFloat = 0

    private let titles = ["Solv", "RunCat"]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                SolvPage(appState: appState, close: close, openSettings: openSettings)
                    .frame(width: Self.size.width)
                RunCatPage()
                    .frame(width: Self.size.width)
            }
            .frame(width: Self.size.width * 2, alignment: .leading)
            .offset(x: -CGFloat(page) * Self.size.width + drag)
            .frame(width: Self.size.width, alignment: .leading)
            .clipped()
            .animation(.easeInOut(duration: 0.25), value: page)
            .animation(.interactiveSpring(), value: drag)
            Divider()
            dots
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .simultaneousGesture(
            DragGesture(minimumDistance: 24)
                .onChanged { v in
                    guard abs(v.translation.width) > abs(v.translation.height) else { return }
                    drag = v.translation.width / 3
                }
                .onEnded { v in
                    drag = 0
                    if v.translation.width < -60 { go(1) } else if v.translation.width > 60 { go(-1) }
                }
        )
        .background(SwipeCatcher { go($0) })
    }

    private func go(_ delta: Int) {
        page = min(max(page + delta, 0), titles.count - 1)
    }

    private var header: some View {
        HStack {
            Button { go(-1) } label: { Image(systemName: "chevron.left") }
                .disabled(page == 0)
            Spacer()
            Text(titles[page]).font(.headline)
            Spacer()
            Button { go(1) } label: { Image(systemName: "chevron.right") }
                .disabled(page == titles.count - 1)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var dots: some View {
        HStack(spacing: 7) {
            ForEach(titles.indices, id: \.self) { i in
                Circle()
                    .fill(i == page ? Color.accentColor : Color.secondary.opacity(0.35))
                    .frame(width: 7, height: 7)
                    .onTapGesture { page = i }
            }
        }
        .padding(.vertical, 8)
    }
}

// MARK: - 트랙패드 두 손가락 좌우 스와이프

private struct SwipeCatcher: NSViewRepresentable {
    let onSwipe: (Int) -> Void

    func makeNSView(context: Context) -> NSView {
        let v = SwipeView()
        v.onSwipe = onSwipe
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? SwipeView)?.onSwipe = onSwipe
    }

    final class SwipeView: NSView {
        var onSwipe: ((Int) -> Void)?
        private var monitor: Any?
        private var acc: CGFloat = 0
        private var fired = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { remove(); return }
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] e in
                self?.handle(e)
                return e
            }
        }

        private func handle(_ e: NSEvent) {
            guard abs(e.scrollingDeltaX) > abs(e.scrollingDeltaY) else { return }
            if e.phase == .began { acc = 0; fired = false }
            acc += e.scrollingDeltaX
            if !fired, abs(acc) > 60 {
                fired = true
                onSwipe?(acc < 0 ? 1 : -1)  // 왼쪽으로 밀면 다음 화면
            }
            if e.phase == .ended || e.phase == .cancelled { acc = 0; fired = false }
        }

        private func remove() {
            if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        }

        deinit { if let m = monitor { NSEvent.removeMonitor(m) } }
    }
}

// MARK: - RunCat 스타일 부품 (둥근 카드 · 섹션 제목 · 가는 구분선 · 한 줄 행)

struct RCCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) { content() }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.14), lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

struct RCSectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 6)
    }
}

struct RCDivider: View {
    var body: some View {
        Rectangle().fill(Color.primary.opacity(0.14)).frame(height: 1).padding(.horizontal, 14)
    }
}

/// 한 줄 행: 왼쪽 제목, 오른쪽에 값/화살표. 눌리면 action.
struct RCRow<Trailing: View>: View {
    let title: String
    var action: (() -> Void)?
    @ViewBuilder let trailing: () -> Trailing
    @State private var hovering = false

    var body: some View {
        let row = HStack(spacing: 8) {
            Text(title).font(.system(size: 15)).foregroundStyle(.primary)
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .background(hovering && action != nil ? Color.primary.opacity(0.07) : .clear)
        .onHover { hovering = $0 }

        if let action {
            Button(action: action) { row }.buttonStyle(.plain)
        } else {
            row
        }
    }
}

extension RCRow where Trailing == EmptyView {
    init(_ title: String, action: (() -> Void)? = nil) {
        self.init(title: title, action: action) { EmptyView() }
    }
}

struct RCToggleRow: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        HStack {
            Text(title).font(.system(size: 15))
            Spacer()
            Toggle("", isOn: $isOn).labelsHidden().toggleStyle(.switch).controlSize(.small)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 44)
    }
}

// MARK: - 1페이지: Solv

private struct SolvPage: View {
    @ObservedObject var appState: AppState
    let close: () -> Void
    let openSettings: () -> Void
    @ObservedObject private var catalog = SolvModelCatalog.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                RCCard {
                    RCSectionLabel("상태")
                    Text(appState.statusText)
                        .font(.system(size: 13))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 12)
                    RCDivider()
                    RCToggleRow(title: "단축키 사용", isOn: $appState.hotkeyEnabled)
                    RCDivider()
                    RCToggleRow(title: "정밀 모드 (느리지만 정확)", isOn: $appState.preciseMode)
                }

                runCard("Caps Lock", [
                    ("영역 · 선 없음", .region, .capsLock, false),
                    ("전체 화면", .fullScreen, .capsLock, true),
                ])
                runCard("마우스", [
                    ("영역 · 마우스 포인터 손바닥", .region, .handCursor, false),
                    ("영역 · 마네키네코 손짓", .region, .mouseCursor, false),
                    ("영역 · 회색선 (OCR 이동)", .region, .mouse, true),
                    ("영역 · 선 없음 (OCR 이동)", .region, .mouse, false),
                    ("전체 화면 (OCR 이동)", .fullScreen, .mouse, true),
                ])
                runCard("클립보드 (Raycast ⌘V)", [
                    ("영역 · 회색선", .region, .raycast, true),
                    ("영역 · 선 없음", .region, .raycast, false),
                    ("영역 · 선 없음 · 답+설명", .region, .raycastExplain, false),
                    ("전체 화면", .fullScreen, .raycast, true),
                ])

                RCCard {
                    Menu {
                        ForEach(catalog.favorites) { model in
                            Button((model.id == catalog.selectedId ? "✓ " : "") + model.shortTitle) {
                                appState.selectModel(model)
                            }
                        }
                        Divider()
                        Button("전체 모델 목록 새로고침") { Task { await catalog.refresh() } }
                    } label: {
                        RCRow(title: "모델") {
                            Text(appState.selectedModel.shortTitle).foregroundStyle(.secondary).font(.system(size: 14))
                            Image(systemName: "chevron.up.chevron.down").font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    RCDivider()
                    Menu {
                        Button("API 키 설정…") { close(); appState.promptForAPIKey() }
                        Button("API 키 연결 테스트") { Task { await appState.testAPIKey() } }
                        Button("화면 녹화 다시 연결…") { close(); appState.showPermissionRepairGuide() }
                        Button("캡처 진단…") { close(); Task { await appState.runCaptureDiagnose() } }
                        Divider()
                        Button("Caps Lock 테스트 (2회)") { Task { await appState.testCapsLock() } }
                        Button("마네키네코 테스트 (1→2)") { Task { await appState.testManeki() } }
                        Button("손바닥 커서 테스트 (1→2)") { Task { await appState.testHandCursor() } }
                        Button("마우스 이동 테스트") { Task { await appState.testMouseMove() } }
                        Button("클립보드 테스트") { Task { await appState.testRaycastType() } }
                        Button("마지막 전송 이미지 열기") { appState.openLastCaptureImage() }
                    } label: {
                        RCRow(title: "도구") {
                            Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    RCDivider()
                    RCRow(title: "설정") { Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(.secondary) }
                        .overlay(Color.clear.contentShape(Rectangle()).onTapGesture { close(); openSettings() })
                }

                RCCard {
                    RCRow("Solv 종료") { NSApplication.shared.terminate(nil) }
                }
            }
            .padding(14)
        }
    }

    private func runCard(
        _ title: String,
        _ items: [(String, AppState.CaptureMode, AppState.OutputMode, Bool)]
    ) -> some View {
        RCCard {
            RCSectionLabel(title)
            ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                if i > 0 { RCDivider() }
                RCRow(item.0) {
                    close()
                    Task { await appState.solve(capture: item.1, output: item.2, showBorder: item.3) }
                }
            }
        }
        .disabled(appState.isBusy)
    }
}

// MARK: - 2페이지: RunCat

private struct RunCatPage: View {
    @ObservedObject private var monitor = SystemMonitor.shared
    @ObservedObject private var prefs = RunCatPrefs.shared
    @State private var showPicker = false

    var body: some View {
        if showPicker {
            VStack(spacing: 0) {
                HStack {
                    Button { showPicker = false } label: { Label("뒤로", systemImage: "chevron.left") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                RunnerPicker()
            }
        } else {
            dashboard
        }
    }

    private var dashboard: some View {
        let s = monitor.snapshot
        return ScrollView {
            VStack(spacing: 14) {
                RCCard {
                    RCSectionLabel("러너")
                    RunnerHeader { showPicker = true }
                }

                RCCard {
                    RCSectionLabel("시스템 정보")
                    valueRow("CPU 사용량", String(format: "%.0f%%", s.cpu))
                    Sparkline(values: monitor.cpuHistory).frame(height: 30).padding(.horizontal, 14).padding(.bottom, 10)
                    RCDivider()
                    valueRow("메모리 성능", "\(Fmt.bytes(Int64(s.memUsed))) / \(Fmt.bytes(Int64(s.memTotal)))")
                    Bar(percent: s.memPercent).padding(.horizontal, 14).padding(.bottom, 12)
                    RCDivider()
                    valueRow("저장 용량", "\(Fmt.bytes(s.diskAvailable)) 사용 가능")
                    Bar(percent: s.diskUsedPercent).padding(.horizontal, 14).padding(.bottom, 12)
                    RCDivider()
                    valueRow("네트워크 연결", "↓ \(Fmt.speed(s.netDown))  ↑ \(Fmt.speed(s.netUp))")
                    if let b = s.batteryPercent {
                        RCDivider()
                        valueRow("배터리 상태", "\(b)%" + (s.batteryCharging ? " · 충전 중" : ""))
                        Bar(percent: Double(b), invert: true).padding(.horizontal, 14).padding(.bottom, 12)
                    }
                }

                RCCard {
                    RCSectionLabel("설정")
                    RCToggleRow(title: "CPU 사용량에 따라 속도 변화", isOn: $prefs.cpuLinkedSpeed)
                    RCDivider()
                    RCRow(title: "메뉴바 수치") {
                        Picker("", selection: $prefs.metric) {
                            ForEach(MenuBarMetric.allCases) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 130)
                    }
                }

                RCCard {
                    RCRow("활성 상태 보기") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
                    }
                }
            }
            .padding(14)
        }
    }

    private func valueRow(_ title: String, _ value: String) -> some View {
        RCRow(title: title) {
            Text(value).font(.system(size: 13, design: .monospaced)).foregroundStyle(.secondary)
        }
    }
}

/// 현재 러너가 달리는 모습 + 이름. 프레임마다 다시 그려지는 건 이 뷰뿐.
private struct RunnerHeader: View {
    @ObservedObject private var cat = CatAnimator.shared
    let pick: () -> Void

    var body: some View {
        Button(action: pick) {
            HStack(spacing: 12) {
                Circle().fill(Color.accentColor).frame(width: 13, height: 13)
                Text(cat.style.title).font(.system(size: 15)).foregroundStyle(.primary)
                Spacer()
                Image(nsImage: cat.image)
                    .renderingMode(cat.style.template ? .template : .original)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.primary)
                    .frame(height: 28)
                Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .frame(height: 50)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct Bar: View {
    let percent: Double
    var invert = false  // 배터리는 높을수록 좋음

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                Capsule().fill(color).frame(width: g.size.width * min(max(percent, 0), 100) / 100)
            }
        }
        .frame(height: 6)
    }

    private var color: Color {
        let bad = invert ? percent < 20 : percent > 85
        let warn = invert ? percent < 40 : percent > 65
        return bad ? .red : (warn ? .orange : .accentColor)
    }
}

private struct Sparkline: View {
    let values: [Double]

    var body: some View {
        GeometryReader { g in
            let n = max(values.count, 2)
            Path { p in
                for (i, v) in values.enumerated() {
                    let x = g.size.width * CGFloat(i) / CGFloat(n - 1)
                    let y = g.size.height * (1 - CGFloat(min(max(v, 0), 100)) / 100)
                    i == 0 ? p.move(to: CGPoint(x: x, y: y)) : p.addLine(to: CGPoint(x: x, y: y))
                }
            }
            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
        }
    }
}
