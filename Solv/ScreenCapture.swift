import AppKit
import CoreGraphics
import Foundation
import OSLog
import ScreenCaptureKit

enum ScreenCaptureError: LocalizedError {
    case noPermission
    case noDisplay
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .noPermission:
            return "화면 녹화가 이 Solv에 아직 연결되지 않음. 목록에서 Solv를 삭제(−) 후 다시 ON → Solv 재실행"
        case .noDisplay:
            return "디스플레이를 찾을 수 없습니다"
        case .failed(let m):
            return m
        }
    }
}

final class ScreenCapture {
    private let log = Logger(subsystem: "com.solv.app", category: "capture")

    /// 실제 TCC. 설정 UI의 토글과 다를 수 있음.
    var preflightOK: Bool { CGPreflightScreenCaptureAccess() }

    func captureMainDisplay() async throws -> NSImage {
        // preflight=false 인데 캡처 API를 부르면 시스템 권한 창이 반복해서 뜸
        guard preflightOK else {
            throw ScreenCaptureError.noPermission
        }

        if let img = cgCaptureMain() {
            return img
        }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() })
                    ?? content.displays.first else {
                throw ScreenCaptureError.noDisplay
            }
            return try await captureSCK(display: display, cropRect: nil)
        } catch let e as ScreenCaptureError {
            throw e
        } catch {
            throw ScreenCaptureError.failed(describe(error))
        }
    }

    func captureScreenRect(_ rect: CGRect) async throws -> NSImage {
        guard preflightOK else {
            throw ScreenCaptureError.noPermission
        }

        if let img = cgCaptureRect(rect) {
            return img
        }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = display(containing: rect, in: content.displays) else {
                throw ScreenCaptureError.noDisplay
            }
            let frame = displayFrame(for: display)
            let scaleX = CGFloat(display.width) / max(frame.width, 1)
            let scaleY = CGFloat(display.height) / max(frame.height, 1)
            let local = CGRect(
                x: (rect.minX - frame.minX) * scaleX,
                y: (frame.maxY - rect.maxY) * scaleY,
                width: rect.width * scaleX,
                height: rect.height * scaleY
            ).integral
            return try await captureSCK(display: display, cropRect: local)
        } catch let e as ScreenCaptureError {
            throw e
        } catch {
            throw ScreenCaptureError.failed(describe(error))
        }
    }

    func diagnose() -> String {
        [
            "preflight=\(preflightOK)",
            "bundle=\(Bundle.main.bundlePath)",
            preflightOK
                ? "권한 OK — 캡처 가능"
                : "권한 미연결 — 설정에서 Solv 삭제(−) 후 다시 켜고 Solv 재실행 필요"
        ].joined(separator: "\n")
    }

    // MARK: - private

    private func captureSCK(display: SCDisplay, cropRect: CGRect?) async throws -> NSImage {
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.showsCursor = false
        config.captureResolution = .best

        if let crop = cropRect, crop.width >= 2, crop.height >= 2 {
            config.sourceRect = crop
            config.width = max(2, Int(crop.width))
            config.height = max(2, Int(crop.height))
        } else {
            config.width = display.width
            config.height = display.height
        }

        let cgImage = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: config
        )
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    private func cgCaptureMain() -> NSImage? {
        guard let cgImage = CGDisplayCreateImage(CGMainDisplayID()) else { return nil }
        if isMostlyBlack(cgImage) { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    private func cgCaptureRect(_ rect: CGRect) -> NSImage? {
        guard rect.width >= 2, rect.height >= 2 else { return nil }
        let screenHeight = NSScreen.screens.map(\.frame.maxY).max() ?? 0
        let quartz = CGRect(
            x: rect.origin.x,
            y: screenHeight - rect.origin.y - rect.height,
            width: rect.width,
            height: rect.height
        )
        guard let cgImage = CGWindowListCreateImage(
            quartz,
            .optionOnScreenOnly,
            kCGNullWindowID,
            [.bestResolution]
        ) else { return nil }
        if isMostlyBlack(cgImage) { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    private func isMostlyBlack(_ image: CGImage) -> Bool {
        guard let cropped = image.cropping(to: CGRect(x: 0, y: 0, width: min(32, image.width), height: min(32, image.height))),
              let data = cropped.dataProvider?.data,
              let ptr = CFDataGetBytePtr(data) else { return false }
        let len = CFDataGetLength(data)
        guard len > 16 else { return false }
        var sum = 0
        let step = max(1, len / 64)
        var count = 0
        var i = 0
        while i < len {
            sum += Int(ptr[i])
            count += 1
            i += step
        }
        return count > 0 && (sum / count) < 3
    }

    private func describe(_ error: Error) -> String {
        let ns = error as NSError
        return "\(ns.domain) code=\(ns.code) \(ns.localizedDescription)"
    }

    private func display(containing rect: CGRect, in displays: [SCDisplay]) -> SCDisplay? {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        return displays.first { displayFrame(for: $0).contains(center) } ?? displays.first
    }

    private func displayFrame(for display: SCDisplay) -> CGRect {
        if let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == display.displayID
        }) {
            return screen.frame
        }
        return CGRect(x: 0, y: 0, width: display.width, height: display.height)
    }
}
