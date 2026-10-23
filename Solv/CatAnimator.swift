import AppKit
import Combine
import Foundation

/// 메뉴바 고양이.
/// - 일반 러너(RunCat 러너 전부): 평소 계속 달림, 작업 중엔 더 빠르게(작업 중엔 더 빠르게)
/// - 마네키네코: 평소 느리게 계속 손을 흔듦.
///   답 표시 = [손 든 채 멈춤] → 평소 속도로 N번 → [멈춤] → 다시 평소 흔들기
@MainActor
final class CatAnimator: ObservableObject {
    static let shared = CatAnimator()

    /// 메뉴바에 그릴 고양이 높이(pt). 18이 RunCat 원본 에셋 크기(36px @2x). 실제 RunCat이 더 커 보여서 22.
    static let height: CGFloat = 22
    private static let styleKey = "catStyle"

    @Published private(set) var image: NSImage
    @Published var style: Runner {
        didSet {
            UserDefaults.standard.set(style.id, forKey: Self.styleKey)
            if !waving { restartIdle() }
        }
    }

    private var frame = 0
    private var timer: Timer?
    private var interval: TimeInterval = 0.1
    private var waving = false
    private var idleTask: Task<Void, Never>?
    private var idleStop = false
    private var generation = 0

    private static var cache: [String: [NSImage]] = [:]

    static func frames(of runner: Runner) -> [NSImage] {
        if let hit = cache[runner.id] { return hit }
        let imgs = (0..<runner.frames).map { i -> NSImage in
            let img = NSImage(named: "\(runner.id)-\(i)")?.copy() as? NSImage ?? NSImage()
            let ratio = img.size.height > 0 ? img.size.width / img.size.height : 1
            img.size = NSSize(width: height * ratio, height: height)
            img.isTemplate = runner.template  // 단색 실루엣은 메뉴바 색(라이트/다크)에 맞춰 칠해진다
            return img
        }
        cache[runner.id] = imgs
        return imgs
    }

    private static let maneki = frames(of: Runner.maneki)
    private var isManeki: Bool { style.id == Runner.maneki.id }

    init() {
        // 예전 저장값(golden/maneki) 호환
        let legacy = ["golden": "golden-cat", "maneki": "maneki-neko"]
        let raw = UserDefaults.standard.string(forKey: Self.styleKey) ?? ""
        let saved = Runner.named(legacy[raw] ?? raw) ?? Runner.named("golden-cat") ?? Runner.maneki
        style = saved
        image = Self.frames(of: saved)[0]
        restartIdle()
    }

    private var busy = false
    private var cpuInterval: TimeInterval = 0.1

    func setBusy(_ busy: Bool) {
        self.busy = busy
        applyInterval()
    }

    /// CPU 사용률(0~100)에 따라 러너 속도 조절. nil이면 고정 속도.
    /// (RunCat의 정확한 식은 정적 분석으로 확인 못 함 — 0%→프레임당 0.20초, 100%→0.03초로 선형)
    func setCPU(_ usage: Double?) {
        cpuInterval = usage.map { max(0.03, 0.2 - $0 / 100 * 0.17) } ?? 0.1
        applyInterval()
    }

    private func applyInterval() {
        let next = busy ? 0.04 : cpuInterval
        guard abs(next - interval) / interval > 0.15 else { return }
        interval = next
        // 프레임 위치는 유지한 채 타이머만 다시 건다 (깜빡임·끊김 방지)
        if !waving, !isManeki, timer != nil { scheduleRunnerTimer() }
    }

    // MARK: - 마네키네코 손짓

    /// 평소 흔들기(한 번 ≈ 2초)는 느리게, 답 흔들기(한 번 ≈ 1초)는 세기 쉽게 빠르게.
    private static let idleFrameNs: UInt64 = 130_000_000
    private static let answerFrameNs: UInt64 = 70_000_000
    /// 답 앞뒤로 손을 든 채 멈추는 시간
    private static let holdSeconds = 1.2

    /// 답 하나: [멈춤] n번 [멈춤]
    func wave(times: Int) async {
        await waveSequence([times], pauseSeconds: Self.holdSeconds)
    }

    /// 여러 답: [1,3] → 멈춤 · 1번 · 멈춤 · 3번 · 멈춤. (현재 스타일과 상관없이 마네키네코로 보여준다)
    func waveSequence(_ answers: [Int], pauseSeconds: Double = 2.0) async {
        guard !answers.isEmpty, !waving else { return }
        waving = true
        stopTimer()
        generation += 1
        // 진행 중인 평소 흔들기는 한 번이 끝나는 지점까지 기다린다 (뚝 끊기지 않게)
        let old = idleTask
        idleStop = true
        await old?.value
        idleTask = nil

        image = Self.maneki[0]
        await hold(Self.holdSeconds)
        for (i, raw) in answers.enumerated() {
            let n = max(1, min(raw, HandBlinkTiming.maxTimes))
            for _ in 0..<n { await oneWave(frameNs: Self.answerFrameNs) }
            await hold(i < answers.count - 1 ? max(Self.holdSeconds, pauseSeconds) : Self.holdSeconds)
        }
        waving = false
        restartIdle()
    }

    private func hold(_ seconds: Double) async {
        image = Self.maneki[0]
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// 15프레임이 한 번의 전체 동작: 손 든 자세(0) → 내려감(6~9) → 다시 든 자세(14)
    private func oneWave(frameNs: UInt64) async {
        for f in 0..<Runner.maneki.frames {
            image = Self.maneki[f]
            try? await Task.sleep(nanoseconds: frameNs)
        }
        image = Self.maneki[0]
    }

    // MARK: - 평소 모습

    private func restartIdle() {
        stopTimer()
        generation += 1
        let gen = generation
        let old = idleTask
        idleStop = true
        idleTask = nil
        Task { @MainActor in
            await old?.value
            guard gen == generation, !waving else { return }
            startIdle()
        }
    }

    private func startIdle() {
        idleStop = false
        if isManeki {
            idleTask = Task { @MainActor in
                while !idleStop { await oneWave(frameNs: Self.idleFrameNs) }
            }
            return
        }
        guard !Self.frames(of: style).isEmpty else { return }
        frame = 0
        image = Self.frames(of: style)[0]
        scheduleRunnerTimer()
    }

    private func scheduleRunnerTimer() {
        timer?.invalidate()
        let runner = style
        let frames = Self.frames(of: runner)
        let t = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.waving, self.style == runner else { return }
                self.frame = (self.frame + 1) % frames.count
                self.image = frames[self.frame]
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}
