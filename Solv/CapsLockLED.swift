import Foundation
import IOKit
import IOKit.hid

/// Caps Lock LED로 답을 알림.
final class CapsLockLED {
    func blink(times: Int) async {
        let n = max(1, min(times, QuestionSolver.maxOptions))
        await runBlink(count: n, onMs: 320, offMs: 200)
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
