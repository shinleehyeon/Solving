import Combine
import Darwin
import Foundation
import IOKit.ps

/// 1초마다 읽는 시스템 수치 (RunCat "시스템 정보"에 해당)
struct SystemSnapshot {
    var cpu: Double = 0  // 0...100
    var memUsed: UInt64 = 0
    var memTotal: UInt64 = 0
    var diskAvailable: Int64 = 0
    var diskTotal: Int64 = 0
    var netDown: Double = 0  // bytes/sec
    var netUp: Double = 0
    var batteryPercent: Int?
    var batteryCharging = false

    var memPercent: Double { memTotal > 0 ? Double(memUsed) / Double(memTotal) * 100 : 0 }
    var diskUsedPercent: Double {
        diskTotal > 0 ? Double(diskTotal - diskAvailable) / Double(diskTotal) * 100 : 0
    }
}

enum Fmt {
    static func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .memory)
    }

    static func speed(_ bps: Double, compact: Bool = false) -> String {
        let units = ["B", "K", "M", "G"]
        var v = bps
        var i = 0
        while v >= 1000, i < units.count - 1 { v /= 1024; i += 1 }
        let num = v >= 100 || i == 0 ? String(format: "%.0f", v) : String(format: "%.1f", v)
        return compact ? "\(num)\(units[i])" : "\(num) \(units[i])B/s".replacingOccurrences(of: "BB", with: "B")
    }
}

@MainActor
final class SystemMonitor: ObservableObject {
    static let shared = SystemMonitor()

    @Published private(set) var snapshot = SystemSnapshot()
    @Published private(set) var cpuHistory: [Double] = []

    private static let historyLength = 60
    private var timer: Timer?
    private var prevCPU: (busy: UInt64, total: UInt64)?
    private var prevNet: [String: (rx: UInt32, tx: UInt32)] = [:]
    private var prevNetTime: Date?

    func start() {
        guard timer == nil else { return }
        sample()
        let t = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func sample() {
        var s = snapshot
        s.cpu = readCPU()
        (s.memUsed, s.memTotal) = Self.readMemory()
        (s.diskAvailable, s.diskTotal) = Self.readDisk()
        (s.netDown, s.netUp) = readNetwork()
        (s.batteryPercent, s.batteryCharging) = Self.readBattery()
        snapshot = s
        cpuHistory.append(s.cpu)
        if cpuHistory.count > Self.historyLength { cpuHistory.removeFirst(cpuHistory.count - Self.historyLength) }
    }

    // MARK: CPU — 코어별 틱 증가량으로 사용률 계산

    private func readCPU() -> Double {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let r = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount)
        guard r == KERN_SUCCESS, let info else { return snapshot.cpu }
        defer {
            let size = vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)), size)
        }
        var busy: UInt64 = 0
        var total: UInt64 = 0
        for i in 0..<Int(cpuCount) {
            let base = Int(CPU_STATE_MAX) * i
            let user = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]))
            let sys = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]))
            let nice = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)]))
            let idle = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]))
            busy += user + sys + nice
            total += user + sys + nice + idle
        }
        defer { prevCPU = (busy, total) }
        guard let p = prevCPU, total > p.total else { return 0 }
        return min(100, max(0, Double(busy - p.busy) / Double(total - p.total) * 100))
    }

    // MARK: 메모리 — 활동 상태 보기의 "사용된 메모리"와 같은 식 (앱 + 유선 + 압축)

    private static func readMemory() -> (UInt64, UInt64) {
        let total = ProcessInfo.processInfo.physicalMemory
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return (0, total) }
        let page = UInt64(sysconf(_SC_PAGESIZE))
        let app = UInt64(stats.internal_page_count) &- UInt64(stats.purgeable_count)
        let used = (app + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * page
        return (min(used, total), total)
    }

    // MARK: 저장 용량

    private static func readDisk() -> (Int64, Int64) {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys) else { return (0, 0) }
        return (v.volumeAvailableCapacityForImportantUsage ?? 0, Int64(v.volumeTotalCapacity ?? 0))
    }

    // MARK: 네트워크 — 인터페이스별 누적 바이트 증가량 / 경과 시간 (32비트 카운터 감김 처리)

    private func readNetwork() -> (Double, Double) {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return (0, 0) }
        defer { freeifaddrs(head) }
        let now = Date()
        var cur: [String: (rx: UInt32, tx: UInt32)] = [:]
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = p {
            defer { p = ifa.pointee.ifa_next }
            guard let addr = ifa.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK),
                  let data = ifa.pointee.ifa_data else { continue }
            let name = String(cString: ifa.pointee.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("pdp_ip") else { continue }  // 루프백·터널 제외
            let d = data.assumingMemoryBound(to: if_data.self).pointee
            cur[name] = (d.ifi_ibytes, d.ifi_obytes)
        }
        defer { prevNet = cur; prevNetTime = now }
        guard let t0 = prevNetTime else { return (0, 0) }
        let dt = max(now.timeIntervalSince(t0), 0.001)
        var rx = 0.0
        var tx = 0.0
        for (name, c) in cur {
            guard let p = prevNet[name] else { continue }
            rx += Double(c.rx &- p.rx)  // 감김은 &- 로 자연 처리
            tx += Double(c.tx &- p.tx)
        }
        return (rx / dt, tx / dt)
    }

    // MARK: 배터리

    private static func readBattery() -> (Int?, Bool) {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return (nil, false) }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any],
                  let cap = d[kIOPSCurrentCapacityKey] as? Int,
                  let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            let charging = (d[kIOPSIsChargingKey] as? Bool) ?? false
            return (cap * 100 / max, charging)
        }
        return (nil, false)
    }
}

// MARK: - 설정

/// 메뉴바에 고양이 옆에 글자로 보여 줄 수치
enum MenuBarMetric: String, CaseIterable, Identifiable {
    case none, cpu, memory, network, battery

    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: "아이콘만"
        case .cpu: "CPU 사용량"
        case .memory: "메모리"
        case .network: "네트워크 속도"
        case .battery: "배터리"
        }
    }

    func text(_ s: SystemSnapshot) -> String {
        switch self {
        case .none: ""
        case .cpu: String(format: "%.0f%%", s.cpu)
        case .memory: String(format: "%.0f%%", s.memPercent)
        case .network: "↓\(Fmt.speed(s.netDown, compact: true)) ↑\(Fmt.speed(s.netUp, compact: true))"
        case .battery: s.batteryPercent.map { "\($0)%" } ?? "--"
        }
    }
}

@MainActor
final class RunCatPrefs: ObservableObject {
    static let shared = RunCatPrefs()

    /// CPU 사용량에 따라 러너 속도가 바뀜
    @Published var cpuLinkedSpeed: Bool {
        didSet { UserDefaults.standard.set(cpuLinkedSpeed, forKey: "cpuLinkedSpeed") }
    }
    @Published var metric: MenuBarMetric {
        didSet { UserDefaults.standard.set(metric.rawValue, forKey: "menuBarMetric") }
    }

    private init() {
        cpuLinkedSpeed = UserDefaults.standard.object(forKey: "cpuLinkedSpeed") as? Bool ?? true
        metric = UserDefaults.standard.string(forKey: "menuBarMetric").flatMap(MenuBarMetric.init(rawValue:)) ?? .none
    }
}
