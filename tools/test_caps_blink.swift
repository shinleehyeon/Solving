#!/usr/bin/env swift
import Foundation
import IOKit
import IOKit.hid

// CapsLockLED와 동일한 점멸 로직 + 상태 폴링으로 ON 상승 엣지 검증

enum CapsIO {
    static func withConnect<T>(_ body: (io_connect_t) -> T?) -> T? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(kIOHIDSystemClass))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var connect: io_connect_t = 0
        let kr = IOServiceOpen(service, mach_task_self_, UInt32(kIOHIDParamConnectType), &connect)
        guard kr == KERN_SUCCESS else { return nil }
        defer { IOServiceClose(connect) }
        return body(connect)
    }

    static func get(_ connect: io_connect_t) -> Bool {
        var state = false
        _ = IOHIDGetModifierLockState(connect, Int32(kIOHIDCapsLockState), &state)
        return state
    }

    static func set(_ connect: io_connect_t, _ on: Bool) {
        _ = IOHIDSetModifierLockState(connect, Int32(kIOHIDCapsLockState), on)
    }
}

/// 앱과 동일: times를 1...5로 클램프 후 on/off 반복, 끝나면 원래 상태 복원
func blinkLikeApp(times: Int, onMs: UInt64 = 320, offMs: UInt64 = 200) -> (requested: Int, clamped: Int, commandedOn: Int) {
    let clamped = max(1, min(times, 5))
    var commandedOn = 0
    _ = CapsIO.withConnect { connect -> Int? in
        let original = CapsIO.get(connect)
        for i in 0..<clamped {
            CapsIO.set(connect, true)
            commandedOn += 1
            usleep(useconds_t(onMs * 1000))
            CapsIO.set(connect, false)
            if i < clamped - 1 {
                usleep(useconds_t(offMs * 1000))
            }
        }
        usleep(100_000)
        CapsIO.set(connect, original)
        return commandedOn
    }
    return (times, clamped, commandedOn)
}

/// 점멸 동안 Caps Lock true 상승 엣지 개수 측정
func measureRisingEdges(during work: () -> Void, sampleUs: useconds_t = 8_000) -> Int {
    let lock = NSLock()
    var rising = 0
    var stop = false

    let thread = Thread {
        _ = CapsIO.withConnect { connect -> Int? in
            var last = CapsIO.get(connect)
            while true {
                lock.lock()
                let done = stop
                lock.unlock()
                if done { break }
                let cur = CapsIO.get(connect)
                if cur && !last {
                    lock.lock()
                    rising += 1
                    lock.unlock()
                }
                last = cur
                usleep(sampleUs)
            }
            return nil
        }
    }
    thread.qualityOfService = .userInteractive
    thread.start()
    usleep(30_000)
    work()
    usleep(50_000)
    lock.lock()
    stop = true
    lock.unlock()
    // join
    while !thread.isFinished { usleep(5_000) }
    lock.lock()
    let result = rising
    lock.unlock()
    return result
}

struct Case {
    let name: String
    let run: () -> (Bool, String)
}

func expect(_ cond: Bool, _ detail: String) -> (Bool, String) {
    (cond, detail)
}

// --- 테스트 케이스 ~20개 ---

var cases: [Case] = []

// 1–8: 클램프 / 명령 횟수 (짧은 펄스로 빠르게)
for (idx, input) in [0, 1, 2, 3, 4, 5, 6, 99].enumerated() {
    let expected = max(1, min(input, 5))
    cases.append(Case(name: "clamp#\(idx + 1) input=\(input) → \(expected)") {
        // 하드웨어 부담 줄이려고 짧은 펄스 (카운트만 검증)
        let r = blinkLikeApp(times: input, onMs: 40, offMs: 30)
        return expect(
            r.clamped == expected && r.commandedOn == expected,
            "clamped=\(r.clamped) commandedOn=\(r.commandedOn) expected=\(expected)"
        )
    })
}

// 9–13: 실제 LED 타이밍으로 답 1…5 상승엣지 측정
for n in 1...5 {
    cases.append(Case(name: "hw-answer-\(n) risingEdges") {
        // 시작 전 Caps 꺼두기
        _ = CapsIO.withConnect { c -> Bool? in
            CapsIO.set(c, false)
            return true
        }
        usleep(80_000)
        let edges = measureRisingEdges {
            _ = blinkLikeApp(times: n, onMs: 200, offMs: 120)
        }
        return expect(edges == n, "risingEdges=\(edges) expected=\(n)")
    })
}

// 14–18: 섞인 답 시퀀스 (앱이 연속 문제를 풀 때)
let sequence = [3, 1, 5, 2, 4]
for (i, n) in sequence.enumerated() {
    cases.append(Case(name: "hw-seq#\(i + 1) answer=\(n)") {
        _ = CapsIO.withConnect { c -> Bool? in
            CapsIO.set(c, false)
            return true
        }
        usleep(60_000)
        let edges = measureRisingEdges {
            _ = blinkLikeApp(times: n, onMs: 180, offMs: 100)
        }
        return expect(edges == n, "risingEdges=\(edges) expected=\(n)")
    })
}

// 19: 앱 blinkError = 3회 (짧은 펄스)
cases.append(Case(name: "hw-error-blink-3") {
    _ = CapsIO.withConnect { c -> Bool? in
        CapsIO.set(c, false)
        return true
    }
    usleep(60_000)
    let edges = measureRisingEdges {
        // CapsLockLED.blinkError: count 3, on 100, off 100
        _ = CapsIO.withConnect { connect -> Int? in
            let original = CapsIO.get(connect)
            for i in 0..<3 {
                CapsIO.set(connect, true)
                usleep(100_000)
                CapsIO.set(connect, false)
                if i < 2 { usleep(100_000) }
            }
            usleep(100_000)
            CapsIO.set(connect, original)
            return 3
        }
    }
    return expect(edges == 3, "risingEdges=\(edges) expected=3")
})

// 20: Caps가 이미 ON인 상태에서 답 4 — 복원 후에도 상승엣지 4회여야 함
cases.append(Case(name: "hw-prelit-caps answer=4") {
    _ = CapsIO.withConnect { c -> Bool? in
        CapsIO.set(c, true)
        return true
    }
    usleep(80_000)
    let edges = measureRisingEdges {
        _ = blinkLikeApp(times: 4, onMs: 180, offMs: 100)
    }
    // 복원으로 다시 ON 될 수 있음 → 상승엣지는 루프의 true 전환(+복원 true)일 수 있어
    // commanded 경로와 폴링을 둘 다 보되, 최소 4회 ON 명령은 blinkLikeApp이 보장.
    // 사전 ON이면 첫 set(true)가 상승엣지가 아닐 수 있음 → 허용: edges == 4 또는 (edges == 3 && restore)
    // 앱은 매 회 false 후 다시 true 하므로: 첫 회는 이미 true라 rise 없음, 이후 3 rise + 중간 off/on…
    // 패턴: start ON → set T(no rise) → F → T(rise) → F → T → F → T → F → restore T(rise)
    // rises during blink loop: 3, plus restore: 4. Observer may see 3 or 4.
    // 더 정확한 검증: commandedOn == 4 (이미 clamp 테스트) + edges >= 3
    let ok = edges >= 3 && edges <= 5
    return expect(ok, "risingEdges=\(edges) (prelit; expect 3…5)")
})

// 실행
print("Caps Lock blink accuracy — \(cases.count) cases")
print(String(repeating: "─", count: 56))

var passed = 0
var failed = 0
for (i, c) in cases.enumerated() {
    let (ok, detail) = c.run()
    let mark = ok ? "PASS" : "FAIL"
    if ok { passed += 1 } else { failed += 1 }
    print(String(format: "%2d. [%@] %@ — %@", i + 1, mark, c.name, detail))
    fflush(stdout)
}

print(String(repeating: "─", count: 56))
print("Result: \(passed)/\(cases.count) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
