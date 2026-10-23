import Foundation
import IOKit
import IOKit.hid

/// Caps Lock LED로 답을 알림.
final class CapsLockLED {
    func blink(times: Int) async {
        let n = max(1, min(times, QuestionSolver.maxOptions))
        await runBlink(count: n, onMs: 220, offMs: 160)
    }

    /// 여러 문제: 각 답을 깜빡인 뒤 `pauseSeconds`만큼 긴 쉼.
    func blinkSequence(_ answers: [Int], pauseSeconds: Double = 2.0) async {
        let gapNs = UInt64(max(0.5, pauseSeconds) * 1_000_000_000)
        for (i, raw) in answers.enumerated() {
            let n = max(1, min(raw, QuestionSolver.maxOptions))
            await blink(times: n)
            if i < answers.count - 1 {
                try? await Task.sleep(nanoseconds: gapNs)
            }
        }
    }

    func blinkError() async {
        await runBlink(count: 3, onMs: 100, offMs: 100)
    }

    func testBlink() async {
        await blink(times: 2)
    }

    private func runBlink(count: Int, onMs: UInt64, offMs: UInt64) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                self.withHIDConnect { connect in
                    var original = false
                    _ = IOHIDGetModifierLockState(connect, Int32(kIOHIDCapsLockState), &original)

                    for i in 0..<count {
                        _ = IOHIDSetModifierLockState(connect, Int32(kIOHIDCapsLockState), true)
                        usleep(useconds_t(onMs * 1000))
                        _ = IOHIDSetModifierLockState(connect, Int32(kIOHIDCapsLockState), false)
                        if i < count - 1 {
                            usleep(useconds_t(offMs * 1000))
                        }
                    }

                    usleep(100_000)
                    _ = IOHIDSetModifierLockState(connect, Int32(kIOHIDCapsLockState), original)
                }
                cont.resume()
            }
        }
    }

    private func withHIDConnect(_ body: (io_connect_t) -> Void) {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(kIOHIDSystemClass))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }
        var connect: io_connect_t = 0
        let kr = IOServiceOpen(service, mach_task_self_, UInt32(kIOHIDParamConnectType), &connect)
        guard kr == KERN_SUCCESS else { return }
        defer { IOServiceClose(connect) }
        body(connect)
    }
}
