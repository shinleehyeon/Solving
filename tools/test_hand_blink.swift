#!/usr/bin/env swift
import Foundation

// MouseMover.HandBlinkTiming 과 동일한 상수/로직을 복제해 스케줄을 검증.
// (앱 타깃과 분리된 스크립트 — 값이 바뀌면 여기도 맞춰야 함)

enum HandBlinkTiming {
    static let maxTimes = 9
    static let warmupMs: UInt64 = 140
    static let offMs: UInt64 = 180
    static let settleMs: UInt64 = 120
    static let multiOnMs: UInt64 = 400
    static let singleOnMs: UInt64 = 600

    static func clampTimes(_ times: Int) -> Int {
        max(1, min(times, maxTimes))
    }

    static func onMs(forCount n: Int) -> UInt64 {
        clampTimes(n) == 1 ? singleOnMs : multiOnMs
    }

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

    static func handOnCount(times: Int) -> Int {
        pulsePlan(times: times).filter(\.hand).count
    }
}

struct Case {
    let name: String
    let run: () -> (Bool, String)
}

func expect(_ cond: Bool, _ detail: String) -> (Bool, String) {
    (cond, detail)
}

var cases: [Case] = []

// 1–10: 클램프 + hand-on 횟수 == 답
for (idx, input) in [0, 1, 2, 3, 4, 5, 6, 7, 8, 99].enumerated() {
    let expected = max(1, min(input, 9))
    cases.append(Case(name: "clamp#\(idx + 1) input=\(input) → \(expected)") {
        let n = HandBlinkTiming.clampTimes(input)
        let ons = HandBlinkTiming.handOnCount(times: input)
        return expect(n == expected && ons == expected, "clamp=\(n) handOns=\(ons)")
    })
}

// 11: 답 1은 on이 600ms (짧은 220ms 회귀 방지)
cases.append(Case(name: "answer-1 onMs>=550") {
    let on = HandBlinkTiming.onMs(forCount: 1)
    let plan = HandBlinkTiming.pulsePlan(times: 1)
    let firstOn = plan.first { $0.hand }?.holdMs ?? 0
    return expect(on >= 550 && firstOn == on && firstOn >= 550, "onMs=\(on) firstOn=\(firstOn)")
})

// 12: 답 1 플랜 = [hand, arrow-settle] 만 (off 중간 없음)
cases.append(Case(name: "answer-1 plan shape") {
    let plan = HandBlinkTiming.pulsePlan(times: 1)
    let ok = plan.count == 2
        && plan[0].hand == true
        && plan[1].hand == false
        && plan[1].holdMs == HandBlinkTiming.settleMs
    let desc = plan.map { "\($0.hand ? "H" : "A")\($0.holdMs)" }.joined(separator: ",")
    return expect(ok, "plan=[\(desc)]")
})

// 13–17: 답 2…5 — hand on 개수, on 구간은 multiOn
for n in 2...5 {
    cases.append(Case(name: "answer-\(n) handOns+onMs") {
        let plan = HandBlinkTiming.pulsePlan(times: n)
        let ons = plan.filter(\.hand)
        let offsBetween = plan.filter { !$0.hand }.count - 1 // 마지막 settle 제외
        let onOk = ons.allSatisfy { $0.holdMs == HandBlinkTiming.multiOnMs }
        let countOk = ons.count == n && offsBetween == n - 1
        return expect(countOk && onOk, "ons=\(ons.count) betweenOffs=\(offsBetween)")
    })
}

// 18: 시퀀스 [1,2,1] — 각 덩어리 handOn 합
cases.append(Case(name: "sequence [1,2,1] total handOns=4") {
    let seq = [1, 2, 1]
    let total = seq.map { HandBlinkTiming.handOnCount(times: $0) }.reduce(0, +)
    return expect(total == 4, "total=\(total)")
})

// 19: 답 1 총 유지시간 (on+settle) ≥ 700ms — 눈에 보이기 최소치
cases.append(Case(name: "answer-1 totalHold>=700") {
    let total = HandBlinkTiming.pulsePlan(times: 1).reduce(UInt64(0)) { $0 + $1.holdMs }
    return expect(total >= 700, "totalHoldMs=\(total)")
})

// 20: warmup은 begin 후 적용 — 상수 회귀
cases.append(Case(name: "warmupMs>=100") {
    expect(HandBlinkTiming.warmupMs >= 100, "warmup=\(HandBlinkTiming.warmupMs)")
})

// 21: 답 9 클램프·펄스
cases.append(Case(name: "answer-9 handOns=9") {
    let ons = HandBlinkTiming.handOnCount(times: 9)
    return expect(ons == 9, "ons=\(ons)")
})

// 22: 플랜이 항상 화살표로 끝남
cases.append(Case(name: "plan always ends arrow") {
    var ok = true
    var detail = ""
    for n in 1...9 {
        let plan = HandBlinkTiming.pulsePlan(times: n)
        if plan.last?.hand != false {
            ok = false
            detail = "n=\(n) last hand"
            break
        }
    }
    return expect(ok, detail.isEmpty ? "ok" : detail)
})

// 23: 구버전(220ms)보다 답1이 확실히 김
cases.append(Case(name: "answer-1 longer than legacy 220") {
    let on = HandBlinkTiming.onMs(forCount: 1)
    return expect(on > 220 * 2, "onMs=\(on) (legacy was 220)")
})

print("Hand cursor blink schedule — \(cases.count) cases")
print(String(repeating: "─", count: 56))

var passed = 0
var failed = 0
for (i, c) in cases.enumerated() {
    let (ok, detail) = c.run()
    let mark = ok ? "PASS" : "FAIL"
    if ok { passed += 1 } else { failed += 1 }
    print(String(format: "%2d. [%@] %@ — %@", i + 1, mark, c.name, detail))
}

print(String(repeating: "─", count: 56))
print("Result: \(passed)/\(cases.count) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
